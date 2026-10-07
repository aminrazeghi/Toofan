#!/usr/bin/env bash
# Builds Toofan CFD and packages it for Linux x86_64 as an AppImage and a tar.gz, with
# Qt, VTK and the OpenFOAM tools it runs (blockMesh, snappyHexMesh, the solvers) bundled.
#
#   packaging/package-linux.sh [--skip-build] [--no-appimage] [--no-tar] [--output DIR]
#
# Environment:
#   OPENFOAM_DIR   OpenFOAM installation to bundle (default: newest /usr/lib/openfoam/openfoam*)
#   VTK_DIR        passed to CMake when configuring the release build
#   QTPATHS        qtpaths executable of the Qt to bundle (default: qtpaths6)
#   APPIMAGETOOL   appimagetool to use (default: downloaded once into dist/.cache)
#
# The result runs on distributions with glibc >= the build machine's (see the summary at the end).
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# Settings
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Toofan CFD"
PKG_NAME="toofan-cfd"
APP_BIN="digital-wind-tunnel"
ARCH="x86_64"
BUILD_DIR="$ROOT/build-release"
OUT_DIR="$ROOT/dist"
SKIP_BUILD=0
MAKE_APPIMAGE=1
MAKE_TAR=1

# OpenFOAM programs the app runs; everything they load comes along.
OPENFOAM_PROGRAMS=(blockMesh surfaceFeatureExtract snappyHexMesh pimpleFoam rhoPimpleFoam checkMesh foamDictionary)

# Qt plugins: windowing (Wayland, X11), SVG icons and images, input methods.
QT_PLUGINS=(
    platforms/libqwayland.so
    platforms/libqxcb.so
    wayland-shell-integration/libxdg-shell.so
    wayland-graphics-integration-client/libqt-plugin-wayland-egl.so
    wayland-decoration-client/libbradient.so
    xcbglintegrations/libqxcb-glx-integration.so
    xcbglintegrations/libqxcb-egl-integration.so
    imageformats/libqsvg.so
    iconengines/libqsvgicon.so
    platforminputcontexts/libcomposeplatforminputcontextplugin.so
    platforminputcontexts/libibusplatforminputcontextplugin.so
)
# QML modules never needed: the app forces the Basic style.
QML_SKIP_RE='/QtQuick/Controls/(Fusion|Imagine|Material|Universal)(/|$)'

# Libraries that must come from the target system: glibc, the C++ runtime, the graphics and
# windowing stack (drivers depend on the host's copies), fonts, D-Bus and GLib.
HOST_LIBS_RE='^(ld-linux-x86-64|libc|libm|libdl|libpthread|librt|libresolv|libutil|libanl|libnsl|libmvec|libBrokenLocale|libthread_db|libnss_[a-z]+|libgcc_s|libstdc\+\+|libGL|libGLX|libEGL|libGLdispatch|libOpenGL|libGLESv2|libgbm|libdrm|libglapi|libvulkan|libX11|libX11-xcb|libxcb|libxcb-(dri2|dri3|glx|present|sync|xfixes)|libXau|libXdmcp|libXext|libXrender|libXi|libXfixes|libSM|libICE|libwayland-(client|cursor|egl|server)|libxkbcommon|libfontconfig|libfreetype|libharfbuzz|libgraphite2|libz|libdbus-1|libsystemd|libudev|libglib-2\.0|libgobject-2\.0|libgio-2\.0|libgmodule-2\.0|libgthread-2\.0|libselinux|libmount|libblkid|libexpat|libffi|libuuid|libcap|libgpg-error|libgcrypt)\.so'

# ---------------------------------------------------------------------------------------------
# Helpers
log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

is_elf() { [ -f "$1" ] && [ "$(head -c 4 "$1" | od -An -c | tr -d ' ')" = "177ELF" ]; }

# Direct dependencies (DT_NEEDED) of an ELF that are not host libraries, as "name path" lines,
# resolved as the dynamic loader will (RUNPATH, LD_LIBRARY_PATH). Only direct dependencies:
# what host libraries load in turn is the host's business. Unresolvable ones: "UNRESOLVED name".
bundled_needs() {
    local file="$1" map name path
    map="$(ldd "$file" 2>/dev/null || true)"
    while read -r name; do
        [ -n "$name" ] || continue
        [[ "$name" =~ $HOST_LIBS_RE ]] && continue
        path="$(awk -v n="$name" '$1 == n && $2 == "=>" { print $3; exit }' <<<"$map")"
        if [[ "$path" != /* ]]; then echo "UNRESOLVED $name"; else echo "$name $path"; fi
    done < <(patchelf --print-needed "$file" 2>/dev/null)
}

# Copies the non-host dependencies of the given files, recursively, into DEST. Dependencies
# already inside SKIP_DIR (the bundle) stay where they are.
bundle_deps() {
    local dest="$1" skip_dir="$2"; shift 2
    local -a queue=("$@")
    local -A seen=()
    local file needs name path
    while [ "${#queue[@]}" -gt 0 ]; do
        file="${queue[0]}"; queue=("${queue[@]:1}")
        [ -n "${seen[$file]:-}" ] && continue
        seen[$file]=1
        needs="$(bundled_needs "$file")"
        if grep -q '^UNRESOLVED' <<<"$needs"; then
            die "unresolved dependencies of ${file#"$APPDIR"/}: $(grep '^UNRESOLVED' <<<"$needs" | cut -d' ' -f2 | tr '\n' ' ')"
        fi
        while read -r name path; do
            [ -n "$name" ] || continue
            [[ "$(readlink -f "$path")" == "$skip_dir"/* ]] && continue
            if [ ! -e "$dest/$name" ]; then
                cp -L "$path" "$dest/$name"
                chmod u+w "$dest/$name"
            fi
            queue+=("$dest/$name")
        done <<<"$needs"
    done
}

# Points an ELF at the bundle's library directory (relative to the file). Written as DT_RPATH,
# not RUNPATH: RPATH is searched before LD_LIBRARY_PATH, so a user's LD_LIBRARY_PATH (often set
# on CFD machines, e.g. to a local VTK) cannot swap in foreign copies of bundled libraries.
set_runpath() {
    local file="$1" libdir="$2" rel
    rel="$(realpath --relative-to="$(dirname "$file")" "$libdir")"
    [ "$rel" = "." ] && rel=""
    patchelf --force-rpath --set-rpath "\$ORIGIN${rel:+/$rel}" "$file"
}

# Copies a QML module directory without the nested modules it contains (those are copied
# only if the app imports them).
copy_qml_module() {
    local src="$1" dest="$2"
    mkdir -p "$dest"
    (cd "$src" && find . -mindepth 1 -maxdepth 1 -print0) | while IFS= read -r -d '' entry; do
        entry="${entry#./}"
        if [ -d "$src/$entry" ] && [ -f "$src/$entry/qmldir" ]; then
            continue
        fi
        cp -a "$src/$entry" "$dest/"
    done
}

# ---------------------------------------------------------------------------------------------
# Arguments and prerequisites
while [ $# -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1 ;;
        --no-appimage) MAKE_APPIMAGE=0 ;;
        --no-tar) MAKE_TAR=0 ;;
        --output) OUT_DIR="$(realpath -m "$2")"; shift ;;
        -h|--help) usage 0 ;;
        *) printf 'unknown option: %s\n\n' "$1" >&2; usage 1 ;;
    esac
    shift
done

[ "$(uname -m)" = "$ARCH" ] || die "this script packages for $ARCH and must run on an $ARCH machine"
for tool in cmake patchelf ldd strip tar realpath; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done

QTPATHS="${QTPATHS:-$(command -v qtpaths6 || command -v qtpaths || true)}"
[ -n "$QTPATHS" ] || die "qtpaths6 not found; set QTPATHS"
QT_PLUGIN_DIR="$("$QTPATHS" --query QT_INSTALL_PLUGINS)"
QT_QML_DIR="$("$QTPATHS" --query QT_INSTALL_QML)"
QMLIMPORTSCANNER="$("$QTPATHS" --query QT_INSTALL_LIBEXECS)/qmlimportscanner"
[ -x "$QMLIMPORTSCANNER" ] || die "qmlimportscanner not found at $QMLIMPORTSCANNER"

if [ -z "${OPENFOAM_DIR:-}" ]; then
    OPENFOAM_DIR="$(ls -d /usr/lib/openfoam/openfoam* 2>/dev/null | sort -V | tail -1 || true)"
fi
[ -f "${OPENFOAM_DIR:-}/etc/bashrc" ] || die "no OpenFOAM installation found; set OPENFOAM_DIR"

VERSION="$(sed -n 's/.*readonly property string version: "\([^"]*\)".*/\1/p' "$ROOT/qml/AboutDialog.qml")"
[ -n "$VERSION" ] || die "cannot read the version from qml/AboutDialog.qml"

WORK="$OUT_DIR/work"
APPDIR="$WORK/AppDir"
USR="$APPDIR/usr"
LIBDIR="$USR/lib"
OF_DEST="$USR/openfoam"

log "$APP_NAME $VERSION for Linux $ARCH"
info "Qt:       $("$QTPATHS" --query QT_VERSION) ($QT_PLUGIN_DIR)"
info "OpenFOAM: $OPENFOAM_DIR"
info "output:   $OUT_DIR"

# ---------------------------------------------------------------------------------------------
# 1. Release build
if [ "$SKIP_BUILD" -eq 0 ]; then
    log "Building (Release) in $BUILD_DIR"
    cmake -S "$ROOT" -B "$BUILD_DIR" -DCMAKE_BUILD_TYPE=Release ${VTK_DIR:+-DVTK_DIR="$VTK_DIR"} >/dev/null
    cmake --build "$BUILD_DIR" --parallel "$(nproc)"
fi
[ -x "$BUILD_DIR/$APP_BIN" ] || die "$BUILD_DIR/$APP_BIN not found (build first or drop --skip-build)"

# ---------------------------------------------------------------------------------------------
# 2. AppDir skeleton and the application
log "Assembling $APPDIR"
rm -rf "$WORK"
mkdir -p "$USR/bin" "$LIBDIR" "$USR/plugins" "$USR/qml" "$USR/share/licenses"
cp "$BUILD_DIR/$APP_BIN" "$USR/bin/"

# Qt finds its plugins and QML modules next to the executable.
cat > "$USR/bin/qt.conf" <<'EOF'
[Paths]
Prefix = ..
Libraries = lib
Plugins = plugins
QmlImports = qml
Qml2Imports = qml
EOF

# ---------------------------------------------------------------------------------------------
# 3. Qt plugins and QML modules
log "Copying Qt plugins"
for plugin in "${QT_PLUGINS[@]}"; do
    [ -f "$QT_PLUGIN_DIR/$plugin" ] || die "Qt plugin not found: $QT_PLUGIN_DIR/$plugin"
    mkdir -p "$USR/plugins/$(dirname "$plugin")"
    cp "$QT_PLUGIN_DIR/$plugin" "$USR/plugins/$plugin"
done

log "Copying QML modules imported by the app"
mapfile -t qml_modules < <("$QMLIMPORTSCANNER" -rootPath "$ROOT/qml" -importPath "$QT_QML_DIR" \
    | grep -o '"path": *"[^"]*"' | sed 's/^"path": *"//; s/"$//' | sort -u)
for module in "${qml_modules[@]}"; do
    [[ "$module" == "$QT_QML_DIR"/* ]] || continue        # the app's own module is built in
    [[ "$module" =~ $QML_SKIP_RE ]] && continue
    [ -d "$module" ] || continue
    rel="${module#"$QT_QML_DIR"/}"
    copy_qml_module "$module" "$USR/qml/$rel"
    info "$rel"
done

# ---------------------------------------------------------------------------------------------
# 4. OpenFOAM: environment scripts, the programs the app runs, all OpenFOAM libraries
log "Copying OpenFOAM from $OPENFOAM_DIR"
# OpenFOAM's bashrc reads the caller's positional parameters as settings: clear them before sourcing.
WM_OPTIONS="$(env -i HOME="$HOME" PATH=/usr/bin:/bin bash -c 'rc="$1"; set --; source "$rc" >/dev/null 2>&1; echo "$WM_OPTIONS"' _ "$OPENFOAM_DIR/etc/bashrc")"
[ -n "$WM_OPTIONS" ] || die "cannot determine WM_OPTIONS from $OPENFOAM_DIR/etc/bashrc"
OF_PLATFORM="platforms/$WM_OPTIONS"
mkdir -p "$OF_DEST/$OF_PLATFORM/bin"
cp -a "$OPENFOAM_DIR/etc" "$OPENFOAM_DIR/bin" "$OPENFOAM_DIR/META-INFO" "$OF_DEST/"
rm -f "$OF_DEST/etc/cshrc"
for program in "${OPENFOAM_PROGRAMS[@]}"; do
    [ -x "$OPENFOAM_DIR/$OF_PLATFORM/bin/$program" ] || die "OpenFOAM program not found: $program"
    cp -a "$OPENFOAM_DIR/$OF_PLATFORM/bin/$program" "$OF_DEST/$OF_PLATFORM/bin/"
done
# All libraries: solvers load function objects, models and boundary conditions at run time.
# Serial runs only, so no MPI: drop the MPI Pstream and the MPI-only decomposition library.
cp -a "$OPENFOAM_DIR/$OF_PLATFORM/lib" "$OF_DEST/$OF_PLATFORM/"
OF_LIB="$OF_DEST/$OF_PLATFORM/lib"
mpi_dirs=("$OF_LIB"/sys-* "$OF_LIB"/*mpi*)
mapfile -t mpi_only < <(for d in "${mpi_dirs[@]}"; do [ -d "$d" ] && ls "$d"; done | sort -u | while read -r n; do [ -e "$OF_LIB/dummy/$n" ] || echo "$n"; done)
rm -rf "${mpi_dirs[@]}"
# Optional libraries built on MPI-only ones (e.g. the VTK-HDF writer) cannot load without MPI.
while :; do
    dropped=0
    for lib in "$OF_LIB"/*.so "$OF_LIB"/dummy/*.so; do
        [ -f "$lib" ] || continue
        for need in $(patchelf --print-needed "$lib"); do
            if printf '%s\n' "${mpi_only[@]}" | grep -qxF "$need"; then
                info "dropping $(basename "$lib") (needs MPI-only $need)"
                mpi_only+=("$(basename "$lib")"); rm -f "$lib"; dropped=1; break
            fi
        done
    done
    [ "$dropped" -eq 1 ] || break
done

# The packaged bashrc hard-codes its install path and selects system Open MPI. Make it find
# its own directory, and select no MPI (OpenFOAM falls back to the bundled dummy Pstream).
bashrc="$OF_DEST/etc/bashrc"
grep -q '^export WM_PROJECT_DIR=' "$bashrc" || die "unexpected $bashrc: no WM_PROJECT_DIR line"
sed -i '/^export WM_PROJECT_DIR=/c\export WM_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." \&\& pwd -P)"  # relocatable (bundled)' "$bashrc"
sed -i 's/^export WM_MPLIB=.*/export WM_MPLIB=dummy  # bundled: serial only, no MPI/' "$bashrc"

# ---------------------------------------------------------------------------------------------
# 5. Shared libraries
log "Collecting libraries for the application"
mapfile -t app_elves < <(find "$USR/bin" "$USR/plugins" "$USR/qml" -type f \( -name '*.so*' -o -perm -u+x \) | while read -r f; do is_elf "$f" && echo "$f"; done)
bundle_deps "$LIBDIR" "$APPDIR" "${app_elves[@]}"
info "$(find "$LIBDIR" -maxdepth 1 -type f | wc -l) libraries in usr/lib"

log "Collecting host libraries OpenFOAM needs"
mapfile -t of_own_libs < <(ls "$OF_LIB")
mapfile -t of_elves < <(find "$OF_DEST/$OF_PLATFORM" -type f | while read -r f; do is_elf "$f" && echo "$f"; done)
# Resolve OpenFOAM's own libraries from the bundle, as its bashrc will at run time.
LD_LIBRARY_PATH="$OF_LIB/dummy:$OF_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    bundle_deps "$OF_LIB" "$OF_DEST" "${of_elves[@]}"

log "Stripping and setting RPATHs"
# Application side: everything (VTK may be a debug build). OpenFOAM side: only the host
# libraries copied in above; OpenFOAM's own files are left as distributed.
while read -r f; do
    is_elf "$f" || continue
    strip --strip-unneeded "$f"
    set_runpath "$f" "$LIBDIR"
done < <(find "$USR" -path "$OF_DEST" -prune -o -type f \( -name '*.so*' -o -perm -u+x \) -print)
declare -A of_own=()
for lib in "${of_own_libs[@]}"; do of_own[$lib]=1; done
for f in "$OF_LIB"/*; do
    [ -f "$f" ] && [ -z "${of_own[$(basename "$f")]:-}" ] || continue
    strip --strip-unneeded "$f"
    set_runpath "$f" "$OF_LIB"
    info "OpenFOAM needs host library: $(basename "$f")"
done

# ---------------------------------------------------------------------------------------------
# 6. Desktop integration, launcher, licenses
log "Writing launcher, desktop entry, icon and licenses"
cat > "$APPDIR/AppRun" <<EOF
#!/bin/sh
# Starts $APP_NAME from the AppImage or from the unpacked tar bundle.
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/usr/bin/$APP_BIN" "\$@"
EOF
chmod +x "$APPDIR/AppRun"

cat > "$APPDIR/$PKG_NAME.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
Comment=Wind tunnel simulation with OpenFOAM
Exec=$APP_BIN
Icon=$PKG_NAME
Categories=Science;Engineering;
Terminal=false
EOF
mkdir -p "$USR/share/applications" "$USR/share/icons/hicolor/scalable/apps"
cp "$APPDIR/$PKG_NAME.desktop" "$USR/share/applications/"
cp "$ROOT/assets/toofan-cfd-icon.svg" "$APPDIR/$PKG_NAME.svg"
cp "$ROOT/assets/toofan-cfd-icon.svg" "$USR/share/icons/hicolor/scalable/apps/$PKG_NAME.svg"
ln -sf "$PKG_NAME.svg" "$APPDIR/.DirIcon"

licenses="$USR/share/licenses"
mkdir -p "$licenses"/{OpenFOAM,Qt,VTK,inja,nlohmann-json}
of_package="$(dpkg -S "$OPENFOAM_DIR/etc/bashrc" 2>/dev/null | cut -d: -f1 || true)"
[ -n "$of_package" ] && cp "/usr/share/doc/$of_package/copyright" "$licenses/OpenFOAM/" 2>/dev/null || true
cp "$OPENFOAM_DIR/META-INFO/api-info" "$OPENFOAM_DIR/META-INFO/build-info" "$licenses/OpenFOAM/" 2>/dev/null || true
qt_package="$(dpkg -S "$(readlink -f "$("$QTPATHS" --query QT_INSTALL_LIBS)/libQt6Core.so.6")" 2>/dev/null | cut -d: -f1 || true)"
[ -n "$qt_package" ] && cp "/usr/share/doc/$qt_package/copyright" "$licenses/Qt/" 2>/dev/null || true
vtk_dir="$(sed -n 's/^VTK_DIR:PATH=//p' "$BUILD_DIR/CMakeCache.txt")"   # <prefix>/lib/cmake/vtk-X.Y
vtk_prefix="$( [ -n "$vtk_dir" ] && cd "$vtk_dir/../../.." 2>/dev/null && pwd || echo /usr)"
vtk_license="$(find "$vtk_prefix/share/licenses/VTK" /usr/share/doc -maxdepth 2 -iname 'Copyright.txt' -path '*VTK*' 2>/dev/null | head -1 || true)"
[ -n "$vtk_license" ] && cp "$vtk_license" "$licenses/VTK/"
cp "$ROOT/external/inja/LICENSE" "$licenses/inja/"
cp "$ROOT/external/inja/third_party/include/nlohmann/LICENSE.MIT" "$licenses/nlohmann-json/"
cat > "$licenses/README.txt" <<EOF
$APP_NAME $VERSION bundles third-party software under its own licenses:

  OpenFOAM ($(basename "$OPENFOAM_DIR"), ESI-OpenCFD)  GPL-3.0-or-later   usr/openfoam
      Source: https://develop.openfoam.com/Development/openfoam
  Qt $("$QTPATHS" --query QT_VERSION)                              LGPL-3.0 (Qt open source)
      Source: https://download.qt.io/official_releases/qt/
  VTK                                    BSD-3-Clause
  inja, nlohmann/json                    MIT

Each directory here holds the license or copyright file of the corresponding component.
Other libraries in usr/lib and usr/openfoam come from the build system's distribution packages.
EOF

# ---------------------------------------------------------------------------------------------
# 7. Checks: everything resolves inside the bundle or to a host library; bundled OpenFOAM works.
log "Checking the bundle"
problems=0
while read -r f; do
    is_elf "$f" || continue
    while read -r name path; do
        [ -n "$name" ] || continue
        if [ "$name" = UNRESOLVED ] || [[ "$(readlink -f "$path")" != "$APPDIR"/* ]]; then
            printf '    %s needs %s -> %s\n' "${f#"$APPDIR"/}" "${path:-$name}" "${path:+outside the bundle}"; problems=1
        fi
    done < <(bash -c "$(declare -f bundled_needs); HOST_LIBS_RE='$HOST_LIBS_RE'; bundled_needs \"\$1\"" _ "$f")  # caller's LD_LIBRARY_PATH on purpose
done < <(find "$USR" -path "$OF_DEST" -prune -o -type f \( -name '*.so*' -o -perm -u+x \) -print)
[ "$problems" -eq 0 ] || die "application libraries resolve outside the bundle"
info "application: all libraries resolve inside the bundle or to host system libraries${LD_LIBRARY_PATH:+ (also with LD_LIBRARY_PATH=$LD_LIBRARY_PATH)}"

of_check="$(env -i HOME="$HOME" PATH=/usr/bin:/bin HOST="$(sed 's/^\^//' <<<"$HOST_LIBS_RE")" bash -c '
    of="$1"; programs=("${@:2}"); set --   # bashrc must not see positional parameters
    source "$of/etc/bashrc" >/dev/null 2>&1
    [ "$WM_PROJECT_DIR" = "$(cd "$of" && pwd -P)" ] || { echo "WM_PROJECT_DIR is $WM_PROJECT_DIR"; exit 1; }
    [ "$FOAM_MPI" = dummy ] || { echo "FOAM_MPI is $FOAM_MPI"; exit 1; }
    for program in "${programs[@]}"; do
        path="$(command -v "$program")" || { echo "$program not on PATH"; exit 1; }
        [[ "$path" == "$of"/* ]] || { echo "$program resolves to $path"; exit 1; }
        out="$(ldd "$path")"
        if grep -q "not found" <<<"$out"; then echo "$program: $(grep "not found" <<<"$out" | head -3)"; exit 1; fi
        outside="$(awk -v of="$of" "\$2 == \"=>\" && index(\$3, of \"/\") != 1 { print \$1 }" <<<"$out" | grep -vE "^($HOST)" || true)"
        [ -z "$outside" ] || { echo "$program loads from outside the bundle: $outside"; exit 1; }
    done
    blockMesh -help >/dev/null || { echo "blockMesh -help failed"; exit 1; }
    echo ok' _ "$OF_DEST" "${OPENFOAM_PROGRAMS[@]}" 2>&1)"
[ "$of_check" = "ok" ] || die "bundled OpenFOAM check failed: $of_check"
info "OpenFOAM: relocatable environment, no MPI, programs run from the bundle"
info "bundle size: $(du -sh "$APPDIR" | cut -f1)"

# ---------------------------------------------------------------------------------------------
# 8. Archives
mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/$PKG_NAME-$VERSION-linux-$ARCH.tar.gz"
APPIMAGE="$OUT_DIR/$PKG_NAME-$VERSION-$ARCH.AppImage"

if [ "$MAKE_TAR" -eq 1 ]; then
    log "Creating $(basename "$TARBALL")"
    top="$PKG_NAME-$VERSION"
    ln -sf AppRun "$APPDIR/$PKG_NAME"       # ./toofan-cfd starts the unpacked app
    tar -C "$WORK" --owner=0 --group=0 --transform "s,^AppDir,$top," -czf "$TARBALL" AppDir
    rm -f "$APPDIR/$PKG_NAME"
    info "$(du -h "$TARBALL" | cut -f1)  $TARBALL"
fi

if [ "$MAKE_APPIMAGE" -eq 1 ]; then
    log "Creating $(basename "$APPIMAGE")"
    if [ -z "${APPIMAGETOOL:-}" ]; then
        APPIMAGETOOL="$OUT_DIR/.cache/appimagetool-$ARCH.AppImage"
        if [ ! -x "$APPIMAGETOOL" ]; then
            info "downloading appimagetool"
            mkdir -p "$(dirname "$APPIMAGETOOL")"
            url="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-$ARCH.AppImage"
            if command -v curl >/dev/null; then curl -fsSL -o "$APPIMAGETOOL.part" "$url"; else wget -q -O "$APPIMAGETOOL.part" "$url"; fi
            mv "$APPIMAGETOOL.part" "$APPIMAGETOOL"
            chmod +x "$APPIMAGETOOL"
        fi
    fi
    # --appimage-extract-and-run: works without FUSE on the build machine.
    ARCH="$ARCH" VERSION="$VERSION" "$APPIMAGETOOL" --appimage-extract-and-run --no-appstream "$APPDIR" "$APPIMAGE" >"$WORK/appimagetool.log" 2>&1 \
        || { cat "$WORK/appimagetool.log" >&2; die "appimagetool failed"; }
    info "$(du -h "$APPIMAGE" | cut -f1)  $APPIMAGE"
fi

glibc="$(find "$USR" -type f \( -name '*.so*' -o -perm -u+x \) -exec sh -c 'for f; do objdump -T "$f" 2>/dev/null; done' _ {} + \
    | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1 || true)"
log "Done"
info "requires on the target: ${glibc:-glibc (unknown version)}, OpenGL drivers, a Wayland or X11 desktop"
