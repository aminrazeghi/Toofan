#pragma once
#include <QString>
#include <array>

struct CaseOptions {
    QString stlPath;
    QString casePath;
    QString meshQuality;
    double inletSpeed = 20.0;
    // Advanced settings; defaults match CaseSettings.
    QString turbulenceModel = QStringLiteral("kOmegaSST"); // kOmegaSST, kEpsilon, realizableKE, SpalartAllmaras, laminar
    double turbulenceIntensity = 0.01;   // fraction
    double turbulenceLengthScale = 0.1;  // fraction of model length
    double density = 1.225;              // incompressible reference, kg/m³
    double kinematicViscosity = 1.5e-5;  // incompressible, m²/s
    double pressure = 101325.0;          // compressible, Pa
    double temperature = 293.15;         // compressible, K
    double dynamicViscosity = 1.81e-5;   // compressible, Pa·s
    double flowThroughs = 2.0;
    double maxCourant = 0.0;             // 0: 2 incompressible, 1 compressible
    int writeCount = 60;
    int surfaceLayers = 3;
    int processors = 1;                  // > 1: decomposed for a parallel (MPI) run
    // 2D: the model is a section extruded along y that spans the tunnel; meshed in a thin slab and
    // extruded to one cell (front and back empty).
    bool twoDimensional = false;
    // Model orientation, degrees: about x, then y, then z (fixed axes), around the model's centre.
    std::array<double, 3> rotation{0.0, 0.0, 0.0};
};

class OpenFoamCase {
public:
    // Air at `temperature` (K) sets the speed of sound for the Mach number.
    static QString solverForSpeed(double speed, double temperature = 293.15);
    static double speedOfSound(double temperature);
    static QString defaultCaseRoot();
    // Wind tunnel box {xMin, xMax, yMin, yMax, zMin, zMax} around a model's bounds (same layout).
    // Flow is along +x; the inlet is the xMin face. In 2D the tunnel spans the model along y and
    // is sized from its x-z section.
    static std::array<double, 6> tunnelBounds(const std::array<double, 6> &model, bool twoDimensional = false);
    // Renders the wind tunnel template for the selected solver into options.casePath.
    // On success *message describes the case; on failure it holds the error.
    static bool prepare(const CaseOptions &options, QString *message);
    // 2D, after extrudeMesh: makes the front and back patches empty and removes the refinement
    // data snappyHexMesh left for the slab. Returns an error, or "".
    static QString finishTwoDimensionalMesh(const QString &casePath);
    // Cells in the case's mesh, from the header OpenFOAM writes to polyMesh/owner; 0 if unknown.
    static int meshCellCount(const QString &casePath);
};
