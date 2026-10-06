#pragma once
#include <QString>

struct CaseOptions {
    QString stlPath;
    QString casePath;
    QString meshQuality;
    double inletSpeed = 20.0;
};

class OpenFoamCase {
public:
    static QString solverForSpeed(double speed);
    static QString defaultCaseRoot();
    // Renders the wind tunnel template for the selected solver into options.casePath.
    // On success *message describes the case; on failure it holds the error.
    static bool prepare(const CaseOptions &options, QString *message);
};
