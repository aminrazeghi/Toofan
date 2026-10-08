#!/usr/bin/env bash
# Builds a relocatable Open MPI for bundling with Toofan CFD (packaging/package-linux.sh).
#
#   packaging/build-openmpi.sh PREFIX
#
# Environment:
#   OPENMPI_VERSION   Open MPI release to build (default below)
#   JOBS              parallel make jobs (default: nproc)
#
# The build is single-node only (shared memory and TCP; no InfiniBand, UCX, OFI, CUDA or batch
# systems; hwloc without GPU, PCI or XML backends), with PMIx, PRRTE, hwloc and libevent built
# in and every MCA component linked into the libraries (--disable-dlopen), so there are no
# plugin directories to locate at run time.
# Moved elsewhere, it runs with OPAL_PREFIX, PRTE_PREFIX and PMIX_PREFIX set to its new location.
# libmpi.so.40 keeps the ABI of Open MPI 3.x/4.x/5.x, which OpenFOAM's sys-openmpi Pstream uses.
# An existing build of the same version in PREFIX is kept. Needs the zlib headers: without
# them PMIx warns about missing compression at every mpirun.
set -euo pipefail

OPENMPI_VERSION="${OPENMPI_VERSION:-5.0.10}"
JOBS="${JOBS:-$(nproc)}"
[ $# -eq 1 ] || { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1; }
PREFIX="$(realpath -m "$1")"

log() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }

stamp="$PREFIX/.openmpi-version"
if [ -x "$PREFIX/bin/mpirun" ] && [ "$(cat "$stamp" 2>/dev/null)" = "$OPENMPI_VERSION" ]; then
    log "Open MPI $OPENMPI_VERSION already built in $PREFIX"
    exit 0
fi

echo '#include <zlib.h>' | cc -E - >/dev/null 2>&1 || { echo "error: zlib headers missing (install zlib1g-dev / zlib-devel)" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
log "Downloading Open MPI $OPENMPI_VERSION"
url="https://download.open-mpi.org/release/open-mpi/v${OPENMPI_VERSION%.*}/openmpi-$OPENMPI_VERSION.tar.bz2"
mkdir "$work/src"
curl -fsSL "$url" | tar -xj -C "$work/src"

log "Configuring"
rm -rf "$PREFIX"
mkdir -p "$work/build"
cd "$work/build"
"$work/src/openmpi-$OPENMPI_VERSION/configure" \
    --prefix="$PREFIX" \
    --enable-shared --disable-static \
    --disable-dlopen \
    --with-pmix=internal --with-prrte=internal --with-hwloc=internal --with-libevent=internal \
    --disable-mpi-fortran --disable-oshmem --disable-mpi-java \
    --without-ucx --without-ucc --without-ofi --without-psm2 --without-verbs \
    --without-slurm --without-tm --without-lsf --without-sge --without-alps \
    --disable-io-romio \
    --disable-opencl --disable-cuda --disable-nvml --disable-rsmi --disable-levelzero --disable-gl \
    --disable-libxml2 --disable-pci --disable-libudev \
    --enable-mca-no-build=btl-usnic \
    >configure.log 2>&1 || { tail -40 configure.log >&2; exit 1; }

log "Building with $JOBS jobs"
make -j "$JOBS" >make.log 2>&1 || { tail -40 make.log >&2; exit 1; }
make install >install.log 2>&1 || { tail -40 install.log >&2; exit 1; }

# Licenses go with the binaries.
mkdir -p "$PREFIX/share/licenses/openmpi"
cp "$work/src/openmpi-$OPENMPI_VERSION/LICENSE" "$PREFIX/share/licenses/openmpi/"
echo "$OPENMPI_VERSION" >"$stamp"
log "Open MPI $OPENMPI_VERSION installed in $PREFIX"
