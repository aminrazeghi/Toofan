# Wind tunnel case template

Inja templates rendered by `OpenFoamCase::prepare()` into an OpenFOAM (ESI,
v2412+) case. Files under `common/` are rendered for every solver; files under
`<solver>/` (`pimpleFoam`, `rhoPimpleFoam`) are rendered on top and may
override a common file of the same path. A template that renders to nothing but
whitespace is not written; field files use this to exist only for the selected
turbulence model (e.g. `{% if turbulence.usesOmega %}` around `0.orig/omega`). `_partials/` holds templates that are
only used via `{% include "<name>" %}`.

Flow is along +x. Patches: `inlet` (x min), `outlet` (x max), `tunnelWalls`
(slip, the four sides) and the model surface, grouped as `{{ surface.group }}`.
Fields are written to `0.orig/`; the run copies them to `0/` after meshing.

## Template data

| Key | Meaning |
| --- | --- |
| `solver`, `compressible` | Selected solver and whether it is compressible |
| `turbulence.model`, `turbulence.laminar` | RAS model name (`kOmegaSST`, `kEpsilon`, `realizableKE`, `SpalartAllmaras`) or laminar |
| `turbulence.usesK`, `.usesOmega`, `.usesEpsilon`, `.usesNuTilda` | Which turbulence fields the model solves |
| `turbulence.nutWallFunction` | Wall function for `nut` on the model |
| `surface.file`, `surface.name`, `surface.group`, `surface.eMesh` | Model STL in `constant/triSurface`, snappy surface name, patch group, feature-edge file |
| `flow.U`, `flow.Umag`, `flow.mach` | Free-stream velocity vector, magnitude, Mach number |
| `flow.k`, `flow.omega`, `flow.epsilon`, `flow.nuTilda` | Inlet turbulence, from intensity and length scale |
| `flow.nu`, `flow.rhoInf` | Kinematic viscosity and reference density (derived from p, T, mu when compressible) |
| `flow.p`, `flow.T`, `flow.mu`, `flow.Cp`, `flow.Pr`, `flow.molWeight` | Compressible free-stream state and air properties |
| `domain.xMin` .. `domain.zMax`, `domain.nx/ny/nz` | Tunnel box and background cell counts |
| `mesh.*` | snappyHexMesh refinement levels, refinement box, `locationInMesh`, cell limits, layers |
| `time.endTime`, `time.deltaT`, `time.writeInterval`, `time.maxCo` | Run control |
| `forces.CofR`, `forces.lRef`, `forces.Aref` | Force-coefficient reference values |
| `parallel.enabled`, `parallel.processors`, `parallel.method` | MPI decomposition; `system/decomposeParDict` is only written when enabled |

The `vec(array)` callback formats a 3-element array as an OpenFOAM vector
`(x y z)`.
