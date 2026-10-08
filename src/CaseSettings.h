#pragma once
#include <QObject>
#include <QString>
#include <QtQml/qqmlregistration.h>

struct CaseOptions;

// Advanced physics and run settings edited in the UI; copied into CaseOptions when a case is prepared.
class CaseSettings : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_UNCREATABLE("Provided by the simulation controller")
    // kOmegaSST, kEpsilon, realizableKE, SpalartAllmaras or laminar
    Q_PROPERTY(QString turbulenceModel MEMBER turbulenceModel NOTIFY changed)
    Q_PROPERTY(double turbulenceIntensity MEMBER turbulenceIntensity NOTIFY changed)     // inlet, percent
    Q_PROPERTY(double turbulenceLengthScale MEMBER turbulenceLengthScale NOTIFY changed) // inlet, fraction of model length
    // Incompressible (pimpleFoam)
    Q_PROPERTY(double density MEMBER density NOTIFY changed)                       // kg/m³, force reference
    Q_PROPERTY(double kinematicViscosity MEMBER kinematicViscosity NOTIFY changed) // m²/s
    // Compressible (rhoPimpleFoam)
    Q_PROPERTY(double pressure MEMBER pressure NOTIFY changed)                 // Pa
    Q_PROPERTY(double temperature MEMBER temperature NOTIFY changed)           // K
    Q_PROPERTY(double dynamicViscosity MEMBER dynamicViscosity NOTIFY changed) // Pa·s
    // Run control and mesh
    Q_PROPERTY(double flowThroughs MEMBER flowThroughs NOTIFY changed) // run length in tunnel flow-through times
    Q_PROPERTY(double maxCourant MEMBER maxCourant NOTIFY changed)     // 0: automatic per solver
    Q_PROPERTY(int writeCount MEMBER writeCount NOTIFY changed)        // result time steps written per run
    Q_PROPERTY(int surfaceLayers MEMBER surfaceLayers NOTIFY changed)  // prism layers on the model, 0 = none
    // Parallel run: MPI processes for snappyHexMesh and the solver (1 = serial).
    Q_PROPERTY(int processors MEMBER processors NOTIFY changed)

public:
    using QObject::QObject;
    Q_INVOKABLE void restoreDefaults();
    // Half the hardware threads (about the physical cores), at most 8: past that a wind tunnel
    // mesh of this size gains little.
    static int defaultProcessors();
    void apply(CaseOptions *options) const;

    QString turbulenceModel = QStringLiteral("kOmegaSST");
    double turbulenceIntensity = 1.0;
    double turbulenceLengthScale = 0.1;
    double density = 1.225;
    double kinematicViscosity = 1.5e-5;
    double pressure = 101325.0;
    double temperature = 293.15;
    double dynamicViscosity = 1.81e-5;
    double flowThroughs = 2.0;
    double maxCourant = 0.0;
    int writeCount = 60;
    int surfaceLayers = 3;
    int processors = defaultProcessors();

signals:
    void changed();
};
