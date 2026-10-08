# Toofan CFD

A desktop virtual wind tunnel built with Qt 6 / QML, VTK and OpenFOAM. Import an
STL model, choose the inlet speed and mesh resolution, and the app builds an
OpenFOAM case, meshes it, runs a transient solver and shows the flow while it
develops.

## Features

- **Model setup**: STL import (ASCII or binary), rotation about x, y and z in
  discrete steps, and a wireframe preview of the tunnel domain with the inlet
  marked.
- **Automatic case generation**: dictionaries are rendered from
  [inja](https://github.com/pantor/inja) templates. The solver is picked from
  the inlet Mach number: `pimpleFoam` below Mach 0.3, `rhoPimpleFoam` from
  Mach 0.3 to 1. Supersonic speeds are not supported yet.
- **Workflow**: `blockMesh` → `surfaceFeatureExtract` → `snappyHexMesh` →
  solver. Each step writes its own log (`blockMesh.log`, `pimpleFoam.log`, …)
  into the case directory, and the output streams into the built-in console.
- **Advanced settings**: turbulence model (k-ω SST, k-ε, realizable k-ε,
  Spalart-Allmaras, laminar), inlet turbulence, fluid properties, run length,
  Courant limit, write count and surface layers.
- **Live monitoring**: drag and lift coefficients and solver residuals are
  plotted while the solver runs.
- **3D results** (VTK): full domain, mid-plane slice or streamlines, colored by
  U, p, the turbulence fields of the chosen model (k, ω, ε or ν̃), and for
  compressible runs also T, ρ and Ma. The view
  updates as the mesh is generated and as time steps are written.
- **Playback**: after a run, play/pause through the saved time steps or scrub
  to any of them with a slider.
- **Interface**: frameless single-window layout with floating panels, dark and
  light themes, and a choice of contour palettes.

## Requirements

- CMake 3.21+ and a C++20 compiler
- Qt 6.4+ (Quick, Quick Controls 2)
- VTK 9 with the `GUISupportQtQuick` module (optional; without it the app
  builds without the 3D view)
- OpenFOAM (ESI-OpenCFD, v2412 or newer), needed only at run time

## Build

inja is included as a git submodule:

```sh
git submodule update --init --recursive
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
./build/digital-wind-tunnel
```

VTK is found through CMake's normal package search (e.g. under `/usr`). For a
VTK installed elsewhere, pass `-DVTK_DIR=<prefix>/lib/cmake/vtk-X.Y` or
`-DCMAKE_PREFIX_PATH=<prefix>`.

## OpenFOAM

The app does not need to be started from an OpenFOAM shell. Each step runs in a
fresh bash that sources OpenFOAM's own `etc/bashrc`, which is looked up in this
order:

1. the `OPENFOAM_BASHRC` environment variable
2. a copy bundled with the app (`<app>/../openfoam/etc/bashrc`)
3. the newest `/usr/lib/openfoam/openfoam*/etc/bashrc`

Cases are written to `~/wind-tunnel/<model name>`; the directory is created if
it is missing. Re-running a model regenerates its case and removes previous
meshes and results. The templates live in `templates/windTunnel`; see its
README.

## Packaging (Linux x86_64)

```sh
packaging/package-linux.sh            # Release build, AppImage and tar.gz in dist/
packaging/package-linux.sh --help     # options: --skip-build, --no-appimage, --no-tar, --output DIR
```

The packages bundle Qt, VTK and a serial (no MPI) copy of the OpenFOAM programs
the app uses, so they run without an OpenFOAM install. `OPENFOAM_DIR`,
`VTK_DIR`, `QTPATHS` and `APPIMAGETOOL` override what is bundled or used. The
packages require a glibc at least as new as the build machine's. The bundled
licenses and source links are in `usr/share/licenses`.

## Status

This is early software. The generated cases are starting points: domain sizing,
boundary conditions, thermophysical properties and mesh settings have not been
validated for engineering use, so check the results before relying on them.

## Trademark notice

This project is not approved or endorsed by OpenCFD Limited, producer and
distributor of the OpenFOAM software via www.openfoam.com, and owner of the
OPENFOAM® and OpenCFD® trademarks. It is not affiliated with OpenCFD Limited,
the OpenFOAM Foundation or ESI Group. OpenFOAM is used as an external program,
and when bundled it is distributed unmodified under the GNU GPL v3, apart from
a relocation patch to its `etc/bashrc`.
