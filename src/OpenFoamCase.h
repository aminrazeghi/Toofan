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
};

class OpenFoamCase {
public:
    // Air at `temperature` (K) sets the speed of sound for the Mach number.
    static QString solverForSpeed(double speed, double temperature = 293.15);
    static double speedOfSound(double temperature);
    static QString defaultCaseRoot();
    // Wind tunnel box {xMin, xMax, yMin, yMax, zMin, zMax} around a model's bounds (same layout).
    // Flow is along +x; the inlet is the xMin face.
    static std::array<double, 6> tunnelBounds(const std::array<double, 6> &model);
    // Renders the wind tunnel template for the selected solver into options.casePath.
    // On success *message describes the case; on failure it holds the error.
    static bool prepare(const CaseOptions &options, QString *message);
};
