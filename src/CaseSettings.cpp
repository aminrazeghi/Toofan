#include "CaseSettings.h"
#include "OpenFoamCase.h"
#include <QThread>
#include <algorithm>

int CaseSettings::defaultProcessors()
{
    return std::clamp(QThread::idealThreadCount() / 2, 1, 8);
}

void CaseSettings::restoreDefaults()
{
    const CaseSettings defaults;
    turbulenceModel = defaults.turbulenceModel;
    turbulenceIntensity = defaults.turbulenceIntensity;
    turbulenceLengthScale = defaults.turbulenceLengthScale;
    density = defaults.density;
    kinematicViscosity = defaults.kinematicViscosity;
    pressure = defaults.pressure;
    temperature = defaults.temperature;
    dynamicViscosity = defaults.dynamicViscosity;
    flowThroughs = defaults.flowThroughs;
    maxCourant = defaults.maxCourant;
    writeCount = defaults.writeCount;
    surfaceLayers = defaults.surfaceLayers;
    processors = defaults.processors;
    emit changed();
}

void CaseSettings::apply(CaseOptions *options) const
{
    options->turbulenceModel = turbulenceModel;
    options->turbulenceIntensity = turbulenceIntensity / 100.0;
    options->turbulenceLengthScale = turbulenceLengthScale;
    options->density = density;
    options->kinematicViscosity = kinematicViscosity;
    options->pressure = pressure;
    options->temperature = temperature;
    options->dynamicViscosity = dynamicViscosity;
    options->flowThroughs = flowThroughs;
    options->maxCourant = maxCourant;
    options->writeCount = writeCount;
    options->surfaceLayers = surfaceLayers;
    options->processors = std::max(processors, 1);
}
