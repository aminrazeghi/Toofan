# Toofan

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
- **Parallel runs**: with more than one processor (Advanced settings, default
  half the hardware threads, at most 8), the case is decomposed with scotch,
  `snappyHexMesh` and the solver run under `mpirun`, and the mesh and results
  are reconstructed afterwards. The 3D view follows the solver while it writes
  into `processor*/`. Needs an OpenFOAM with Open MPI (the packages bundle one).
- **2D sections**: for a model extruded along y (a cylinder, an aerofoil) the
  tunnel spans the model and is sized from its x-z section (10 section lengths
  upstream, 25 downstream, 10 to each side). `snappyHexMesh` meshes a slab one
  background cell thick, `extrudeMesh` turns it into a one-cell-thick mesh, and
  front and back become `empty`.
- **Advanced settings**: turbulence model (k-ω SST, k-ε, realizable k-ε,
  Spalart-Allmaras, laminar), inlet turbulence, fluid properties, run length,
  Courant limit, write count, surface layers, 2D and processor count.
- **Examples**: ready-made cases (model and settings) in the Examples dialog;
  see [Examples](#examples).
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
./build/toofan
```

VTK is found through CMake's normal package search (e.g. under `/usr`). For a
VTK installed elsewhere, pass `-DVTK_DIR=<prefix>/lib/cmake/vtk-X.Y` or
`-DCMAKE_PREFIX_PATH=<prefix>`.

## OpenFOAM

The app does not need to be started from an OpenFOAM shell.

- **Linux**: each step runs in a fresh bash that sources OpenFOAM's own
  `etc/bashrc`, looked up in this order: the `OPENFOAM_BASHRC` environment
  variable, a copy bundled with the app (`<app>/../openfoam/etc/bashrc`), the
  newest `/usr/lib/openfoam/openfoam*/etc/bashrc`. Parallel steps run under
  Open MPI's `mpirun`.
- **Windows**: OpenCFD's MinGW build of OpenFOAM, from the `OPENFOAM_DIR`
  environment variable (an `OpenFOAM-v<version>` directory) or bundled next to
  `toofan.exe`. The programs run directly with `WM_PROJECT_DIR` and `PATH` set,
  as OpenFOAM's own `setEnvVariables` batch file does; parallel steps run under
  MS-MPI's `mpiexec`, which is bundled in OpenFOAM's `bin` directory.

Cases are written to `<projects folder>/<model name>`; the projects folder is
`~/Toofan-Projects` by default and can be changed in Settings. OpenFOAM cannot
handle paths with spaces or non-ASCII characters, so the app checks the projects
folder (and OpenFOAM's own location) at startup, offers to pick another folder,
and does not start a run until it is fixed. Model names become case names with
such characters replaced by `_`. Re-running a model regenerates its case and
removes previous meshes and results. The templates live in `templates/windTunnel`; see its
README.

## Packaging (Linux x86_64)

```sh
packaging/package-linux.sh            # Release build, AppImage and tar.gz in dist/
packaging/package-linux.sh --help     # options: --skip-build, --no-appimage, --no-tar, --output DIR
```

The packages bundle Qt, VTK, the OpenFOAM programs the app uses and Open MPI,
so they run, in parallel too, without an OpenFOAM or MPI install. Open MPI is
built from source once (`packaging/build-openmpi.sh`, cached in `dist/.cache`):
single-node, with PMIx, PRRTE and hwloc built in, relocated through
`OPAL_PREFIX` by the bundled OpenFOAM's `etc/config.sh/prefs.sys-openmpi`.
`OPENFOAM_DIR`, `OPENMPI_DIR`, `VTK_DIR`, `QTPATHS` and `APPIMAGETOOL` override
what is bundled or used; the OpenFOAM to bundle must have the `sys-openmpi`
Pstream (as OpenCFD's packages do). The
packages require a glibc at least as new as the build machine's. The bundled
licenses and source links are in `usr/share/licenses`.

## Packaging (Windows x64)

In PowerShell 7 on Windows, with Visual Studio 2022 (C++), CMake and 7-Zip:

```powershell
packaging/ci/install-deps-windows.ps1   # Qt, VTK, OpenFOAM for Windows, MS-MPI, Inno Setup (into C:\deps)
packaging/package-windows.ps1           # Release build and dist/toofan-<version>-windows-x86_64-setup.exe
```

OpenFOAM and MS-MPI are unpacked from OpenCFD's
`OpenFOAM-v<version>-windows-mingw.exe` installer without running it; MS-MPI
goes next to the OpenFOAM programs, so the app needs no MS-MPI install or
administrator rights. Before building the installer, the script meshes a small
case with the bundled OpenFOAM and checks it with 2 MPI processes. The
installer (Inno Setup) installs per user into a folder without spaces
(`%LOCALAPPDATA%\Programs\Toofan`, or `C:\Toofan` when the user name has a space
or non-ASCII character) and refuses folders OpenFOAM cannot run from; its license
page shows the MS-MPI redistributable terms. The executable icon is
`assets/toofan.ico`, rendered from `assets/toofan-icon.svg`.

## Examples

Ready-to-run examples: an STL with saved settings (speed, fluid, turbulence model,
mesh quality, run length), opened from **Examples** in the toolbar. Checked items
are in the app. Each lives in `examples/<id>/`: the STL and an `example.json`
whose `settings` are Advanced settings properties (see `src/CaseSettings.h`).

Low Reynolds number, laminar, unsteady wakes:

- [x] **Flow over a cylinder, Re = 300** (`examples/cylinder-re300`): a 2D case,
  D = 0.1 m at 3 m/s in a glycerine-like fluid (ν = 0.001 m²/s), laminar. Kármán
  vortex street and oscillating lift; 2D simulations give St ≈ 0.21 and
  Cd ≈ 1.35 at this Re (the real flow is already 3D there, with St ≈ 0.20).
- [ ] **Sphere, Re = 300**: periodic hairpin vortex shedding (Johnson & Patel 1999);
  expect Cd ≈ 0.66, St ≈ 0.135.
- [ ] **Square cylinder or flat plate normal to the flow, Re ≈ 200**: shedding from
  fixed separation points; expect St ≈ 0.15 (square), Cd ≈ 2 (plate).

High Reynolds number, turbulent (k-ω SST):

- [ ] **Ahmed body, 25° slant**: L = 1.044 m at 40 m/s, C-pillar vortices; expect
  Cd ≈ 0.28–0.30 (free air until the tunnel has a ground).
- [ ] **Finite wing, NACA 0012 at α = 8°, aspect ratio ~4**: tip vortices, lift and
  drag; expect CL ≈ 0.5–0.6.
- [ ] **Cube, Re ~ 10⁴**: a quick first run; horseshoe vortex and separated wake.

Compressible:

- [ ] **Sphere or slender body at Mach 0.5–0.8** (`rhoPimpleFoam`): density and
  temperature fields.
- [ ] **Supersonic flow over an F-18**: shock waves around the aircraft. Needs a
  supersonic solver template; the app stops at Mach 1 today.

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
a relocation patch to its `etc/bashrc` and its Open MPI location in
`etc/config.sh/prefs.sys-openmpi`.
