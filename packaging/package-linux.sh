#!/usr/bin/env bash
# Builds Toofan and packages it for Linux x86_64 as an AppImage and a tar.gz, with
# Qt, VTK, the OpenFOAM tools it runs (blockMesh, snappyHexMesh, the solvers) and Open MPI for
# parallel runs bundled.
#
#   packaging/package-linux.sh [--skip-build] [--no-appimage] [--no-tar] [--output DIR]
#
# Environment:
#   OPENFOAM_DIR   OpenFOAM installation to bundle (default: newest /usr/lib/openfoam/openfoam*)
#   VTK_DIR        passed to CMake when configuring the release build
#   QTPATHS        qtpaths executable of the Qt to bundle (default: qtpaths6)
#   APPIMAGETOOL   appimagetool to use (default: downloaded once into dist/.cache)
#   OPENMPI_DIR    Open MPI prefix built by packaging/build-openmpi.sh (default: built once
#                  into dist/.cache; OPENMPI_VERSION picks the release)
#
# The result runs on distributions with glibc >= the build machine's (see the summary at the end).
set -euo pipefail

# ---------------------------------------------------------------------------------------------
# Settings
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Toofan"
PKG_NAME="toofan"
APP_BIN="toofan"
ARCH="x86_64"
BUILD_DIR="$ROOT/build-release"
OUT_DIR="$ROOT/dist"
SKIP_BUILD=0
MAKE_APPIMAGE=1
MAKE_TAR=1

# OpenFOAM programs the app runs; everything they load comes along.
OPENFOAM_PROGRAMS=(blockMesh surfaceFeatureExtract snappyHexMesh pimpleFoam rhoPimpleFoam checkMesh foamDictionary
                   decomposePar reconstructPar reconstructParMesh)
# Open MPI programs: mpirun starts prterun, which launches the processes on this machine.
OPENMPI_PROGRAMS=(mpirun mpiexec prterun prted prte ompi_info)

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

usage() { sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

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
QT_LIB_DIR="$("$QTPATHS" --query QT_INSTALL_LIBS)"
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
MPI_DEST="$USR/openmpi"

log "$APP_NAME $VERSION for Linux $ARCH"
info "Qt:       $("$QTPATHS" --query QT_VERSION) ($QT_PLUGIN_DIR)"
info "OpenFOAM: $OPENFOAM_DIR"
if [ -z "${OPENMPI_DIR:-}" ]; then
    OPENMPI_DIR="$OUT_DIR/.cache/openmpi"
    "$ROOT/packaging/build-openmpi.sh" "$OPENMPI_DIR"
fi
[ -x "$OPENMPI_DIR/bin/mpirun" ] && [ -f "$OPENMPI_DIR/lib/libmpi.so.40" ] \
    || die "no Open MPI with libmpi.so.40 in $OPENMPI_DIR (build one with packaging/build-openmpi.sh)"
OPENMPI_VERSION="$(cat "$OPENMPI_DIR/.openmpi-version" 2>/dev/null || echo unknown)"
info "Open MPI: $OPENMPI_VERSION ($OPENMPI_DIR)"
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
# Both Pstream variants come along: dummy (serial) and sys-openmpi, which the bundled Open MPI serves.
cp -a "$OPENFOAM_DIR/$OF_PLATFORM/lib" "$OF_DEST/$OF_PLATFORM/"
OF_LIB="$OF_DEST/$OF_PLATFORM/lib"
[ -f "$OF_LIB/sys-openmpi/libPstream.so" ] || die "$OPENFOAM_DIR has no sys-openmpi Pstream (OpenFOAM built without Open MPI?)"
for d in "$OF_LIB"/*/; do
    case "$(basename "$d")" in dummy|sys-openmpi) ;; *) info "dropping MPI variant $(basename "$d")"; rm -rf "$d" ;; esac
done
# The VTK-HDF writer (a function object the app does not use) needs a parallel HDF5, which
# brings in curl, TLS and Kerberos libraries: leave it out.
find "$OF_LIB" -name 'libfoam-vtkhdf*.so' -print -delete | while read -r lib; do info "dropping $(basename "$lib")"; done

# The packaged bashrc hard-codes its install path: make it find its own directory. Select the
# system Open MPI mode, whose prefs file (normally the distribution's MPI location) points at
# the bundled Open MPI next to OpenFOAM.
bashrc="$OF_DEST/etc/bashrc"
grep -q '^export WM_PROJECT_DIR=' "$bashrc" || die "unexpected $bashrc: no WM_PROJECT_DIR line"
sed -i '/^export WM_PROJECT_DIR=/c\export WM_PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." \&\& pwd -P)"  # relocatable (bundled)' "$bashrc"
sed -i 's/^export WM_MPLIB=.*/export WM_MPLIB=SYSTEMOPENMPI  # bundled Open MPI, see etc\/config.sh\/prefs.sys-openmpi/' "$bashrc"
cat > "$OF_DEST/etc/config.sh/prefs.sys-openmpi" <<'EOF'
# Toofan: the Open MPI bundled next to this OpenFOAM (usr/openmpi). It is relocatable:
# the *_PREFIX variables tell Open MPI, PRRTE and PMIx where it is installed now.
export MPI_ARCH_PATH="$(cd "$WM_PROJECT_DIR/../openmpi" && pwd -P)"
export OPAL_PREFIX="$MPI_ARCH_PATH" PRTE_PREFIX="$MPI_ARCH_PATH" PMIX_PREFIX="$MPI_ARCH_PATH"
EOF

log "Copying Open MPI from $OPENMPI_DIR"
mkdir -p "$MPI_DEST/bin" "$MPI_DEST/lib"
for program in "${OPENMPI_PROGRAMS[@]}"; do
    [ -e "$OPENMPI_DIR/bin/$program" ] || die "Open MPI program not found: $program"
    cp -a "$OPENMPI_DIR/bin/$program" "$MPI_DEST/bin/"
done
cp -a "$OPENMPI_DIR"/lib/*.so* "$MPI_DEST/lib/"
# Help texts and default parameter files; licenses go to usr/share/licenses below.
cp -a "$OPENMPI_DIR/etc" "$MPI_DEST/"
mkdir -p "$MPI_DEST/share"
for d in openmpi prte pmix; do
    [ -d "$OPENMPI_DIR/share/$d" ] && cp -a "$OPENMPI_DIR/share/$d" "$MPI_DEST/share/"
done
rm -f "$MPI_DEST"/share/*/*-wrapper-data.txt "$MPI_DEST"/share/*/*.pc

# ---------------------------------------------------------------------------------------------
# 5. Shared libraries
log "Collecting libraries for the application"
mapfile -t app_elves < <(find "$USR/bin" "$USR/plugins" "$USR/qml" -type f \( -name '*.so*' -o -perm -u+x \) | while read -r f; do is_elf "$f" && echo "$f"; done)
# Copied libraries and plugins no longer find their siblings through their own RUNPATHs (Qt
# plugins: $ORIGIN/../../lib, now the bundle's still empty usr/lib; VTK installs may have none).
# Resolve them where the build found them: the executable's RUNPATH (Qt and VTK library
# directories, which need not be system ones, e.g. on CI), and Qt's library directory.
app_search="$(patchelf --print-rpath "$BUILD_DIR/$APP_BIN")"
LD_LIBRARY_PATH="${app_search:+$app_search:}$QT_LIB_DIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    bundle_deps "$LIBDIR" "$APPDIR" "${app_elves[@]}"
info "$(find "$LIBDIR" -maxdepth 1 -type f | wc -l) libraries in usr/lib"

log "Collecting host libraries Open MPI and OpenFOAM need"
mapfile -t mpi_own_libs < <(ls "$MPI_DEST/lib")
mapfile -t mpi_elves < <(find "$MPI_DEST" -type f | while read -r f; do is_elf "$f" && echo "$f"; done)
LD_LIBRARY_PATH="$MPI_DEST/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    bundle_deps "$MPI_DEST/lib" "$MPI_DEST" "${mpi_elves[@]}"
mapfile -t of_own_libs < <(ls "$OF_LIB")
mapfile -t of_elves < <(find "$OF_DEST/$OF_PLATFORM" -type f | while read -r f; do is_elf "$f" && echo "$f"; done)
# Resolve OpenFOAM's own libraries and Open MPI from the bundle, as its bashrc (sys-openmpi)
# will at run time.
LD_LIBRARY_PATH="$OF_LIB/sys-openmpi:$OF_LIB:$OF_LIB/dummy:$MPI_DEST/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    bundle_deps "$OF_LIB" "$USR" "${of_elves[@]}"

log "Stripping and setting RPATHs"
# Application side: everything (VTK may be a debug build). OpenFOAM side: only the host
# libraries copied in above; OpenFOAM's own files are left as distributed.
while read -r f; do
    is_elf "$f" || continue
    strip --strip-unneeded "$f"
    set_runpath "$f" "$LIBDIR"
done < <(find "$USR" \( -path "$OF_DEST" -o -path "$MPI_DEST" \) -prune -o -type f \( -name '*.so*' -o -perm -u+x \) -print)
# Open MPI: built for its original prefix, so all its files get bundle-relative RPATHs.
while read -r f; do
    is_elf "$f" || continue
    strip --strip-unneeded "$f"
    set_runpath "$f" "$MPI_DEST/lib"
done < <(find "$MPI_DEST" -type f)
declare -A mpi_own=()
for lib in "${mpi_own_libs[@]}"; do mpi_own[$lib]=1; done
for f in "$MPI_DEST"/lib/*; do
    [ -f "$f" ] && [ -z "${mpi_own[$(basename "$f")]:-}" ] && info "Open MPI needs host library: $(basename "$f")"
done
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
cp "$ROOT/assets/toofan-icon.svg" "$APPDIR/$PKG_NAME.svg"
cp "$ROOT/assets/toofan-icon.svg" "$USR/share/icons/hicolor/scalable/apps/$PKG_NAME.svg"
ln -sf "$PKG_NAME.svg" "$APPDIR/.DirIcon"

licenses="$USR/share/licenses"
mkdir -p "$licenses"/{OpenFOAM,OpenMPI,Qt,VTK,inja,nlohmann-json}
cp "$OPENMPI_DIR/share/licenses/openmpi/LICENSE" "$licenses/OpenMPI/"
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
  Open MPI $OPENMPI_VERSION (with PMIx, PRRTE, hwloc, libevent)  BSD-3-Clause   usr/openmpi
      Source: https://www.open-mpi.org/software/ompi/
  VTK                                    BSD-3-Clause
  inja, nlohmann/json                    MIT

Each directory here holds the license or copyright file of the corresponding component.
Other libraries in usr/lib, usr/openfoam and usr/openmpi come from the build system's distribution packages.
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

# A tiny case (a cube of 8 cells) meshed and decomposed in two, checked by 2 MPI processes.
testcase="$WORK/mpi-test"
mkdir -p "$testcase/system"
header() { printf 'FoamFile { version 2.0; format ascii; class dictionary; object %s; }\n' "$1"; }
{ header controlDict; echo 'application checkMesh; startFrom startTime; startTime 0; stopAt endTime; endTime 1; deltaT 1; writeControl timeStep; writeInterval 1;'; } >"$testcase/system/controlDict"
{ header fvSchemes; echo 'ddtSchemes {} gradSchemes {} divSchemes {} laplacianSchemes {} interpolationSchemes {} snGradSchemes {}'; } >"$testcase/system/fvSchemes"
{ header fvSolution; } >"$testcase/system/fvSolution"
{ header decomposeParDict; echo 'numberOfSubdomains 2; method scotch;'; } >"$testcase/system/decomposeParDict"
{ header blockMeshDict; echo 'vertices ((0 0 0) (1 0 0) (1 1 0) (0 1 0) (0 0 1) (1 0 1) (1 1 1) (0 1 1));
  blocks (hex (0 1 2 3 4 5 6 7) (2 2 2) simpleGrading (1 1 1));
  boundary (walls { type wall; faces ((0 3 2 1) (4 5 6 7) (0 4 7 3) (1 2 6 5) (0 1 5 4) (3 7 6 2)); });'; } >"$testcase/system/blockMeshDict"

of_check="$(env -i HOME="$HOME" PATH=/usr/bin:/bin HOST="$(sed 's/^\^//' <<<"$HOST_LIBS_RE")" bash -c '
    usr="$1" case="$2"; programs=("${@:3}"); set --   # bashrc must not see positional parameters
    of="$usr/openfoam"
    source "$of/etc/bashrc" >/dev/null 2>&1
    [ "$WM_PROJECT_DIR" = "$(cd "$of" && pwd -P)" ] || { echo "WM_PROJECT_DIR is $WM_PROJECT_DIR"; exit 1; }
    [ "$FOAM_MPI" = sys-openmpi ] || { echo "FOAM_MPI is $FOAM_MPI"; exit 1; }
    [ "$OPAL_PREFIX" = "$(cd "$usr/openmpi" && pwd -P)" ] || { echo "OPAL_PREFIX is $OPAL_PREFIX"; exit 1; }
    for program in "${programs[@]}" mpirun; do
        path="$(command -v "$program")" || { echo "$program not on PATH"; exit 1; }
        [[ "$path" == "$usr"/* ]] || { echo "$program resolves to $path"; exit 1; }
        [ "$program" = mpirun ] && continue
        out="$(ldd "$path")"
        if grep -q "not found" <<<"$out"; then echo "$program: $(grep "not found" <<<"$out" | head -3)"; exit 1; fi
        outside="$(awk -v usr="$usr" "\$2 == \"=>\" && index(\$3, usr \"/\") != 1 { print \$1 }" <<<"$out" | grep -vE "^($HOST)" || true)"
        [ -z "$outside" ] || { echo "$program loads from outside the bundle: $outside"; exit 1; }
    done
    cd "$case"
    blockMesh >log.blockMesh 2>&1 || { echo "blockMesh failed:"; tail -20 log.blockMesh; exit 1; }
    decomposePar >log.decomposePar 2>&1 || { echo "decomposePar failed:"; tail -20 log.decomposePar; exit 1; }
    # Build machines and containers may run this as root, which Open MPI refuses by default.
    export OMPI_ALLOW_RUN_AS_ROOT=1 OMPI_ALLOW_RUN_AS_ROOT_CONFIRM=1
    mpirun --oversubscribe -np 2 checkMesh -parallel >log.checkMesh 2>&1 || { echo "parallel checkMesh failed:"; tail -20 log.checkMesh; exit 1; }
    grep -q "^nProcs *: *2" log.checkMesh || { echo "checkMesh did not run on 2 processes"; exit 1; }
    echo ok' _ "$USR" "$testcase" "${OPENFOAM_PROGRAMS[@]}" 2>&1)"
[ "$of_check" = "ok" ] || die "bundled OpenFOAM check failed: $of_check"
info "OpenFOAM: relocatable environment, programs run from the bundle, parallel run with the bundled Open MPI"
rm -rf "$testcase"
info "bundle size: $(du -sh "$APPDIR" | cut -f1)"

# ---------------------------------------------------------------------------------------------
# 8. Archives
mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/$PKG_NAME-$VERSION-linux-$ARCH.tar.gz"
APPIMAGE="$OUT_DIR/$PKG_NAME-$VERSION-$ARCH.AppImage"

if [ "$MAKE_TAR" -eq 1 ]; then
    log "Creating $(basename "$TARBALL")"
    top="$PKG_NAME-$VERSION"
    ln -sf AppRun "$APPDIR/$PKG_NAME"       # ./toofan starts the unpacked app
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
