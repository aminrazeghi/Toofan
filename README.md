# Digital Wind Tunnel

A Qt 6 / QML desktop workflow for preparing an STL model, creating an OpenFOAM
case, running a suitable solver, and inspecting flow results.

## Build

Requirements: CMake 3.21+, C++20, Qt 6.4+ Quick and Quick Controls 2. VTK with
`GUISupportQtQuick` is detected optionally, including installs under
`~/.local/lib/cmake/vtk-*`; the app previews the selected STL through VTK.
OpenFOAM installs under `/usr/lib/openfoam/openfoam*/etc/bashrc` are detected at
run time. Set `OPENFOAM_BASHRC` to select a specific install. The UI builds
without either dependency.

OpenFOAM dictionaries are generated with [inja](https://github.com/pantor/inja),
included as a git submodule:

```sh
git submodule update --init --recursive
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

The app sources OpenFOAM's bashrc before invoking its utilities so the GUI does
not need to be launched from an initialized shell.

Cases are written to `~/wind-tunnel/<model name>` (created if missing). They are
rendered from the inja templates in `templates/windTunnel` (see its README) for
the `pimpleFoam` and `rhoPimpleFoam` scenarios. Re-running a model regenerates
its case and removes previous meshes and results.

This is an early application scaffold. It selects `pimpleFoam` below Mach 0.3,
`rhoPimpleFoam` from Mach 0.3 to 1, and `sonicFoam` at/above Mach 1 using a
provisional standard-air sound speed. The generated case dictionaries are
starter files; tunnel domain sizing, boundary conditions, thermodynamics, and
solver fields require validation against the target OpenFOAM distribution.
