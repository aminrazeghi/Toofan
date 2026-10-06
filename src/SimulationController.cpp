#include "SimulationController.h"
#include "OpenFoamCase.h"
#include <QDir>
#include <QFileInfo>
#include <QRegularExpression>
#include <QUrl>

SimulationController::SimulationController(QObject *parent) : QObject(parent), m_caseRoot(OpenFoamCase::defaultCaseRoot())
{
    m_openFoamBashrc = qEnvironmentVariable("OPENFOAM_BASHRC");
    if (m_openFoamBashrc.isEmpty()) {
        QDir installs(QStringLiteral("/usr/lib/openfoam"));
        const QStringList versions = installs.entryList(QStringList{QStringLiteral("openfoam*")}, QDir::Dirs, QDir::Name | QDir::Reversed);
        for (const QString &version : versions) {
            const QString candidate = installs.filePath(version + QStringLiteral("/etc/bashrc"));
            if (QFileInfo::exists(candidate)) { m_openFoamBashrc = candidate; break; }
        }
    }
    // Merge stderr into stdout so each step's log file keeps the original interleaving.
    m_process.setProcessChannelMode(QProcess::MergedChannels);
    connect(&m_settings, &CaseSettings::changed, this, &SimulationController::updateSolver);
    m_monitorTimer.setSingleShot(true);
    m_monitorTimer.setInterval(250);
    connect(&m_monitorTimer, &QTimer::timeout, this, &SimulationController::monitorsChanged);
    m_timeStepSettle.setSingleShot(true);
    m_timeStepSettle.setInterval(1000);
    connect(&m_timeStepSettle, &QTimer::timeout, this, &SimulationController::publishLatestTime);
    connect(&m_caseWatcher, &QFileSystemWatcher::directoryChanged, this, &SimulationController::onCaseDirectoryChanged);
    connect(&m_process, &QProcess::readyReadStandardOutput, this, [this] {
        const QByteArray output = m_process.readAllStandardOutput();
        writeStepLog(output);
        parseOutput(output);
        appendLog(QString::fromLocal8Bit(output).trimmed());
    });
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart) return; // other errors are followed by finished()
        finishStep(QStringLiteral("Could not start %1: %2").arg(m_steps[m_step].name, m_process.errorString()));
        m_status = QStringLiteral("Failed"); emit statusChanged();
    });
    connect(&m_process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this, [this](int code, QProcess::ExitStatus exitStatus) {
        const QString &name = m_steps[m_step].name;
        if (m_stopRequested) {
            finishStep(QStringLiteral("%1 stopped by user.").arg(name));
            m_status = QStringLiteral("Stopped"); emit statusChanged(); return;
        }
        if (exitStatus != QProcess::NormalExit || code != 0) {
            finishStep(exitStatus == QProcess::CrashExit ? QStringLiteral("%1 crashed.").arg(name)
                                                         : QStringLiteral("%1 failed (exit %2).").arg(name).arg(code));
            appendLog(QStringLiteral("See %1 for details.").arg(m_stepLog.fileName()));
            m_status = QStringLiteral("Failed"); emit statusChanged(); return;
        }
        finishStep(QStringLiteral("%1 finished.").arg(name));
        if (name == QStringLiteral("blockMesh") || name == QStringLiteral("snappyHexMesh"))
            setPreviewRevision(m_previewRevision + 1);
        ++m_step;
        runNextStep();
    });
}

void SimulationController::setStlPath(const QString &path)
{
    // Accept file:// URLs (e.g. from QML FileDialog) as well as plain paths.
    const QUrl url(path);
    const QString localPath = url.isLocalFile() ? url.toLocalFile() : path;
    if (m_stlPath != localPath) { m_stlPath = localPath; emit stlPathChanged(); }
}
void SimulationController::setCaseRoot(const QString &path)
{
    const QUrl url(path);
    const QString localPath = url.isLocalFile() ? url.toLocalFile() : path;
    if (m_caseRoot != localPath) { m_caseRoot = localPath; emit caseRootChanged(); }
}
void SimulationController::setSpeed(double value) { if (!qFuzzyCompare(m_speed, value)) { m_speed = value; emit speedChanged(); updateSolver(); } }
void SimulationController::updateSolver()
{
    const QString solver = OpenFoamCase::solverForSpeed(m_speed, m_settings.temperature);
    if (solver != m_solver) { m_solver = solver; emit solverChanged(); }
}
void SimulationController::setMeshQuality(const QString &value) { if (m_meshQuality != value) { m_meshQuality = value; emit meshQualityChanged(); } }

void SimulationController::appendLog(const QString &line)
{
    if (line.isEmpty()) return;
    m_log += line + QLatin1Char('\n');
    if (m_log.size() > 16000) m_log = m_log.right(12000);
    emit logChanged();
}

void SimulationController::startSimulation()
{
    if (m_process.state() != QProcess::NotRunning) return;
    updateSolver();
    m_casePath = QDir(m_caseRoot).filePath(QFileInfo(m_stlPath).completeBaseName());
    emit casePathChanged();
    setPreviewRevision(0);
    m_previewTime = 0.0;
    QString message;
    CaseOptions options{m_stlPath, m_casePath, m_meshQuality, m_speed};
    m_settings.apply(&options);
    if (!OpenFoamCase::prepare(options, &message)) {
        m_status = QStringLiteral("Needs attention"); emit statusChanged(); appendLog(message); return;
    }
    // Fields are generated in 0.orig and copied after meshing, as snappyHexMesh changes the patches.
    m_steps = {{QStringLiteral("blockMesh"), {QStringLiteral("blockMesh")}},
               {QStringLiteral("surfaceFeatureExtract"), {QStringLiteral("surfaceFeatureExtract")}},
               {QStringLiteral("snappyHexMesh"), {QStringLiteral("snappyHexMesh"), QStringLiteral("-overwrite")}},
               {QStringLiteral("copyInitialFields"), {QStringLiteral("cp"), QStringLiteral("-r"), QStringLiteral("0.orig"), QStringLiteral("0")}},
               {m_solver, {m_solver}}};
    m_step = 0; m_stopRequested = false; resetMonitors(); appendLog(message); runNextStep();
}

void SimulationController::runNextStep()
{
    if (m_step >= m_steps.size()) {
        m_status = QStringLiteral("Complete"); emit statusChanged(); appendLog(QStringLiteral("Workflow completed. OpenFOAM fields are in %1").arg(m_casePath)); return;
    }
    const Step &step = m_steps[m_step];
    if (m_openFoamBashrc.isEmpty()) {
        m_status = QStringLiteral("OpenFOAM unavailable"); emit statusChanged();
        appendLog(QStringLiteral("OpenFOAM environment not found. Set OPENFOAM_BASHRC to its etc/bashrc file.")); return;
    }
    const QString commandLine = step.command.join(QLatin1Char(' '));
    m_lineBuffer.clear();
    m_stepLog.setFileName(QDir(m_casePath).filePath(step.name + QStringLiteral(".log")));
    if (!m_stepLog.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        appendLog(QStringLiteral("Cannot write %1: %2").arg(m_stepLog.fileName(), m_stepLog.errorString()));
    writeStepLog(QStringLiteral("$ %1\n").arg(commandLine).toLocal8Bit());
    m_status = QStringLiteral("Running %1").arg(step.name); emit statusChanged();
    appendLog(QStringLiteral("$ %1").arg(commandLine));
    m_process.setWorkingDirectory(m_casePath);
    watchTimeDirectories(step.name == m_solver);
    // OpenFOAM's bashrc sets WM_PROJECT_DIR, FOAM_* paths, and library paths.
    // Run each utility in a fresh sourced shell so the GUI itself need not be launched from one.
    // The bashrc treats positional parameters as config settings, so clear them before sourcing.
    QStringList args{QStringLiteral("-c"),
                     QStringLiteral("rc=\"$1\"; shift; cmd=(\"$@\"); set --; source \"$rc\" >/dev/null && exec \"${cmd[@]}\""),
                     QStringLiteral("windtunnel"), m_openFoamBashrc};
    args += step.command;
    m_process.start(QStringLiteral("/bin/bash"), args);
}

void SimulationController::writeStepLog(const QByteArray &data)
{
    if (m_stepLog.isOpen()) { m_stepLog.write(data); m_stepLog.flush(); }
}

void SimulationController::finishStep(const QString &summary)
{
    if (m_steps[m_step].name == m_solver) {
        watchTimeDirectories(false);
        publishLatestTime(); // the process has exited, so the last write is complete
    }
    if (!m_lineBuffer.isEmpty()) { parseLine(QString::fromLocal8Bit(m_lineBuffer)); m_lineBuffer.clear(); }
    writeStepLog(QStringLiteral("\n# %1\n").arg(summary).toLocal8Bit());
    m_stepLog.close();
    appendLog(summary);
}

void SimulationController::stopSimulation()
{
    if (m_process.state() != QProcess::NotRunning) { m_stopRequested = true; m_process.terminate(); m_status = QStringLiteral("Stopping"); emit statusChanged(); }
}

void SimulationController::parseOutput(const QByteArray &output)
{
    // Process output arrives in arbitrary chunks; only parse complete lines.
    m_lineBuffer += output;
    qsizetype end;
    while ((end = m_lineBuffer.indexOf('\n')) >= 0) {
        parseLine(QString::fromLocal8Bit(m_lineBuffer.left(end)));
        m_lineBuffer.remove(0, end + 1);
    }
}

namespace {
// Keeps a whole run plottable: past maxPoints, halve the resolution instead of dropping the start.
void appendDecimated(QList<QPointF> &history, const QPointF &point)
{
    constexpr qsizetype maxPoints = 4000;
    history.append(point);
    if (history.size() <= maxPoints) return;
    QList<QPointF> decimated;
    decimated.reserve(history.size() / 2 + 1);
    for (qsizetype i = 0; i < history.size(); i += 2) decimated.append(history[i]);
    history = decimated;
}

// {name, times, values} as consumed by LinePlot.qml.
QVariantMap toSeries(const QString &name, const QList<QPointF> &history)
{
    QList<double> times, values;
    times.reserve(history.size()); values.reserve(history.size());
    for (const QPointF &point : history) { times.append(point.x()); values.append(point.y()); }
    return {{QStringLiteral("name"), name},
            {QStringLiteral("times"), QVariant::fromValue(times)},
            {QStringLiteral("values"), QVariant::fromValue(values)}};
}
}

void SimulationController::parseLine(const QString &line)
{
    static const QRegularExpression cellsRe(QStringLiteral("cells:(\\d+)"));
    static const QRegularExpression timeRe(QStringLiteral("^Time = (\\S+)\\s*$"));
    static const QRegularExpression residualRe(QStringLiteral("Solving for (\\w+), Initial residual = ([^,]+),"));
    static const QRegularExpression coefficientRe(QStringLiteral("^\\s*(Cd|Cl):\\s+(\\S+)"));

    const QString &step = m_steps[m_step].name;
    if (step == QStringLiteral("snappyHexMesh")) {
        // The last "cells:" report is the final (snapped / layered) mesh.
        if (const auto match = cellsRe.match(line); match.hasMatch()) { m_cellCount = match.captured(1).toInt(); scheduleMonitorUpdate(); }
        return;
    }
    if (step != m_solver) return;

    if (const auto match = timeRe.match(line); match.hasMatch()) {
        m_time = match.captured(1).toDouble();
        m_residualsThisStep.clear();
        scheduleMonitorUpdate();
        return;
    }
    if (const auto match = residualRe.match(line); match.hasMatch()) {
        // Plot the first solve of each field per time step (the usual convergence measure);
        // skip later PIMPLE correctors and trivially solved fields such as rho (residual 0).
        const QString field = match.captured(1);
        const double value = match.captured(2).toDouble();
        if (value <= 0.0 || m_residualsThisStep.contains(field)) return;
        m_residualsThisStep.insert(field);
        appendDecimated(m_residualHistory[field], {m_time, value});
        scheduleMonitorUpdate();
        return;
    }
    if (const auto match = coefficientRe.match(line); match.hasMatch()) {
        bool ok = false;
        const double value = match.captured(2).toDouble(&ok);
        if (!ok) return;
        const bool drag = match.captured(1) == QStringLiteral("Cd");
        (drag ? m_dragCoefficient : m_liftCoefficient) = value;
        appendDecimated(drag ? m_dragHistory : m_liftHistory, {m_time, value});
        scheduleMonitorUpdate();
    }
}

QVariantList SimulationController::residuals() const
{
    QVariantList series;
    for (auto it = m_residualHistory.cbegin(); it != m_residualHistory.cend(); ++it)
        series.append(toSeries(it.key(), it.value()));
    return series;
}

QVariantList SimulationController::dragHistory() const
{
    return m_dragHistory.isEmpty() ? QVariantList() : QVariantList{toSeries(QStringLiteral("Cd"), m_dragHistory)};
}

QVariantList SimulationController::liftHistory() const
{
    return m_liftHistory.isEmpty() ? QVariantList() : QVariantList{toSeries(QStringLiteral("Cl"), m_liftHistory)};
}

void SimulationController::resetMonitors()
{
    m_time = 0.0;
    m_residualsThisStep.clear();
    m_residualHistory.clear();
    m_dragHistory.clear();
    m_liftHistory.clear();
    m_dragCoefficient = m_liftCoefficient = std::nan("");
    m_cellCount = 0;
    m_monitorTimer.stop();
    emit monitorsChanged();
}

void SimulationController::scheduleMonitorUpdate()
{
    if (!m_monitorTimer.isActive()) m_monitorTimer.start();
}

void SimulationController::setPreviewRevision(int revision)
{
    if (m_previewRevision != revision) { m_previewRevision = revision; emit previewRevisionChanged(); }
}

void SimulationController::watchTimeDirectories(bool enable)
{
    m_timeStepSettle.stop();
    if (const QStringList watched = m_caseWatcher.directories(); !watched.isEmpty())
        m_caseWatcher.removePaths(watched);
    if (enable)
        m_caseWatcher.addPath(m_casePath);
}

namespace {
// Newest time directory after 0, or {} when the solver has not written one yet.
QString latestTimeDirectory(const QString &casePath, double *time)
{
    QString latest;
    *time = 0.0;
    for (const QString &name : QDir(casePath).entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        bool ok = false;
        const double value = name.toDouble(&ok);
        if (ok && value > *time) { *time = value; latest = name; }
    }
    return latest;
}
}

void SimulationController::onCaseDirectoryChanged()
{
    // A new time directory appears first and its field files follow; also watch it and wait
    // until both stay quiet before showing it.
    double time = 0.0;
    const QString latest = latestTimeDirectory(m_casePath, &time);
    if (latest.isEmpty() || time <= m_previewTime) return;
    const QString path = QDir(m_casePath).filePath(latest);
    if (!m_caseWatcher.directories().contains(path)) m_caseWatcher.addPath(path);
    m_timeStepSettle.start();
}

void SimulationController::publishLatestTime()
{
    double time = 0.0;
    if (latestTimeDirectory(m_casePath, &time).isEmpty() || time <= m_previewTime) return;
    m_previewTime = time;
    setPreviewRevision(m_previewRevision + 1);
}
