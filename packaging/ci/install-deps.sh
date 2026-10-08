#!/usr/bin/env bash
# Installs what packaging/package-linux.sh needs on Ubuntu 24.04 (used by the GitHub workflow,
# and runnable in an ubuntu:24.04 container to reproduce it):
#
#   - build tools and the X11/Wayland/OpenGL runtime libraries Qt's plugins link against
#   - OpenFOAM from OpenCFD's apt repository (into /usr/lib/openfoam)
#   - Qt from the official binaries (aqtinstall), into $DEPS_DIR/Qt
#   - VTK built from source with only the modules the app uses, into $DEPS_DIR/vtk
#   - a relocatable Open MPI (packaging/build-openmpi.sh), into $DEPS_DIR/openmpi
#
# Qt, VTK and Open MPI are skipped when already present in $DEPS_DIR, so that directory can be cached.
# Environment: QT_VERSION, VTK_VERSION, OPENFOAM_VERSION, OPENMPI_VERSION, DEPS_DIR (defaults below).
# Prints the variables package-linux.sh needs and, on GitHub Actions, adds them to $GITHUB_ENV.
set -euo pipefail

QT_VERSION="${QT_VERSION:-6.10.2}"
VTK_VERSION="${VTK_VERSION:-9.6.2}"
OPENFOAM_VERSION="${OPENFOAM_VERSION:-2606}"
OPENMPI_VERSION="${OPENMPI_VERSION:-5.0.10}"
DEPS_DIR="${DEPS_DIR:-$HOME/deps}"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo"
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------------------------
log "Distribution packages"
$SUDO apt-get update -q
$SUDO apt-get install -y -q --no-install-recommends \
    build-essential cmake ninja-build git curl ca-certificates gnupg file patchelf binutils \
    python3 python3-venv \
    bzip2 \
    libgl-dev libegl-dev libglx-dev libopengl-dev libvulkan-dev \
    libfontconfig1 libfreetype6 libdbus-1-3 libglib2.0-0t64 \
    libx11-6 libx11-xcb1 libxext6 libxrender1 libxi6 libsm6 libice6 libxkbcommon0 libxkbcommon-x11-0 \
    libxcb1 libxcb-cursor0 libxcb-glx0 libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-randr0 \
    libxcb-render0 libxcb-render-util0 libxcb-shape0 libxcb-shm0 libxcb-sync1 libxcb-xfixes0 \
    libxcb-xinerama0 libxcb-xkb1 libxcb-util1 \
    libwayland-client0 libwayland-cursor0 libwayland-egl1

# ---------------------------------------------------------------------------------------------
log "OpenFOAM v$OPENFOAM_VERSION (OpenCFD repository)"
if [ ! -f "/usr/lib/openfoam/openfoam$OPENFOAM_VERSION/etc/bashrc" ]; then
    curl -fsSL https://dl.openfoam.com/add-debian-repo.sh | $SUDO bash
    $SUDO apt-get install -y -q "openfoam$OPENFOAM_VERSION"
fi

# ---------------------------------------------------------------------------------------------
QT_PREFIX="$DEPS_DIR/Qt/$QT_VERSION/gcc_64"
log "Qt $QT_VERSION"
if [ ! -x "$QT_PREFIX/bin/qtpaths" ]; then
    python3 -m venv "$DEPS_DIR/aqt"
    "$DEPS_DIR/aqt/bin/pip" install -q aqtinstall
    "$DEPS_DIR/aqt/bin/aqt" install-qt linux desktop "$QT_VERSION" linux_gcc_64 --outputdir "$DEPS_DIR/Qt"
fi
[ -x "$QT_PREFIX/bin/qtpaths" ] || { echo "Qt install failed: $QT_PREFIX/bin/qtpaths missing" >&2; exit 1; }

# ---------------------------------------------------------------------------------------------
VTK_PREFIX="$DEPS_DIR/vtk"
VTK_SERIES="${VTK_VERSION%.*}"
log "VTK $VTK_VERSION"
if [ ! -d "$VTK_PREFIX/lib/cmake/vtk-$VTK_SERIES" ]; then
    src="$DEPS_DIR/src"
    mkdir -p "$src"
    curl -fsSL "https://vtk.org/files/release/$VTK_SERIES/VTK-$VTK_VERSION.tar.gz" | tar -xz -C "$src"
    # Only the modules CMakeLists.txt asks for (their dependencies follow), plus OpenGL rendering.
    modules=(CommonCore CommonDataModel FiltersCore FiltersFlowPaths FiltersSources FiltersGeneral
             IOGeometry IOParallel IOXML RenderingAnnotation RenderingCore RenderingFreeType RenderingOpenGL2
             InteractionStyle GUISupportQtQuick)
    module_args=()
    for module in "${modules[@]}"; do module_args+=("-DVTK_MODULE_ENABLE_VTK_$module=YES"); done
    cmake -S "$src/VTK-$VTK_VERSION" -B "$src/vtk-build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$VTK_PREFIX" \
        -DCMAKE_PREFIX_PATH="$QT_PREFIX" \
        -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTING=OFF \
        -DVTK_BUILD_TESTING=OFF \
        -DVTK_BUILD_EXAMPLES=OFF \
        -DVTK_BUILD_DOCUMENTATION=OFF \
        -DVTK_WRAP_PYTHON=OFF \
        -DVTK_QT_VERSION=6 \
        -DVTK_GROUP_ENABLE_StandAlone=DONT_WANT \
        -DVTK_GROUP_ENABLE_Rendering=DONT_WANT \
        -DVTK_GROUP_ENABLE_Imaging=DONT_WANT \
        -DVTK_GROUP_ENABLE_Views=DONT_WANT \
        -DVTK_GROUP_ENABLE_Web=DONT_WANT \
        -DVTK_GROUP_ENABLE_MPI=DONT_WANT \
        "${module_args[@]}"
    cmake --build "$src/vtk-build" --parallel "$(nproc)"
    cmake --install "$src/vtk-build" >/dev/null
    rm -rf "$src"
fi

# ---------------------------------------------------------------------------------------------
log "Open MPI $OPENMPI_VERSION"
OPENMPI_VERSION="$OPENMPI_VERSION" "$(dirname "${BASH_SOURCE[0]}")/../build-openmpi.sh" "$DEPS_DIR/openmpi"

# ---------------------------------------------------------------------------------------------
VTK_DIR="$VTK_PREFIX/lib/cmake/vtk-$VTK_SERIES"
log "Environment for package-linux.sh"
{
    echo "QTPATHS=$QT_PREFIX/bin/qtpaths"
    echo "VTK_DIR=$VTK_DIR"
    echo "CMAKE_PREFIX_PATH=$QT_PREFIX"
    echo "OPENFOAM_DIR=/usr/lib/openfoam/openfoam$OPENFOAM_VERSION"
    echo "OPENMPI_DIR=$DEPS_DIR/openmpi"
} | tee -a "${GITHUB_ENV:-/dev/null}"
