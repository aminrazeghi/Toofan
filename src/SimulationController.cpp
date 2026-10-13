#include "SimulationController.h"
#include "OpenFoamCase.h"
#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSettings>
#include <QStandardPaths>
#include <QThread>
#include <QUrl>

namespace {
const QString kCaseRootKey = QStringLiteral("paths/projectsFolder");

// Copies directory source to target (which must not exist yet), recursively.
QString copyDirectory(const QString &source, const QString &target)
{
    const QDir from(source);
    if (!from.exists()) return QStringLiteral("%1 does not exist.").arg(source);
    if (!QDir().mkpath(target)) return QStringLiteral("Cannot create %1.").arg(target);
    for (const QFileInfo &entry : from.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot)) {
        const QString destination = QDir(target).filePath(entry.fileName());
        if (entry.isDir()) {
            if (QString error = copyDirectory(entry.filePath(), destination); !error.isEmpty()) return error;
        } else if (!QFile::copy(entry.filePath(), destination)) {
            return QStringLiteral("Cannot copy %1 to %2.").arg(entry.filePath(), destination);
        }
    }
    return {};
}
}

SimulationController::SimulationController(QObject *parent)
    : QObject(parent), m_caseRoot(QSettings().value(kCaseRootKey, OpenFoamCase::defaultCaseRoot()).toString())
{
    m_openFoam.probeParallel(this, [this](const QString &mpi) {
        if (mpi.isEmpty()) return;
        m_parallelAvailable = true; m_mpiName = mpi; emit parallelAvailableChanged();
    });
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
        if (m_steps[m_step].refreshPreview)
            setPreviewRevision(m_previewRevision + 1);
        ++m_step;
        runNextStep();
    });
}

SimulationController::~SimulationController()
{
    // The handlers use members that are being destroyed: a dying process must not start the next step.
    m_process.disconnect();
    if (m_process.state() == QProcess::NotRunning) return;
    // As Stop does first: a plain kill would leave mpirun's (Linux) or smpd's (Windows) solver
    // processes running; then kill whatever is left.
    OpenFoamEnvironment::stop(&m_process);
    if (!m_process.waitForFinished(5000)) {
        m_process.kill();
        m_process.waitForFinished(2000);
    }
}

int SimulationController::maxProcessors() { return std::max(QThread::idealThreadCount(), 1); }

QString SimulationController::pathProblem(const QString &path)
{
    if (path.contains(QRegularExpression(QStringLiteral("\\s"))))
        return QStringLiteral("contains spaces");
    for (const QChar c : path) {
        if (c.unicode() > 0x7e)
            return QStringLiteral("contains the non-ASCII character \u201c%1\u201d").arg(c);
    }
    return {};
}

QString SimulationController::caseRootProblem() const
{
    const QString problem = pathProblem(QDir::toNativeSeparators(m_caseRoot));
    return problem.isEmpty() ? QString() : QStringLiteral("The projects folder %1 %2, which OpenFOAM cannot handle.")
                                               .arg(QDir::toNativeSeparators(m_caseRoot), problem);
}

QString SimulationController::openFoamProblem() const
{
    const QString problem = pathProblem(QDir::toNativeSeparators(m_openFoam.root()));
    return problem.isEmpty() ? QString() : QStringLiteral("OpenFOAM is installed in %1, which %2. Install Toofan in a folder without spaces or non-ASCII characters.")
                                               .arg(QDir::toNativeSeparators(m_openFoam.root()), problem);
}

QString SimulationController::caseNameFor(const QString &stlPath)
{
    QString name = QFileInfo(stlPath).completeBaseName();
    name.replace(QRegularExpression(QStringLiteral("[^A-Za-z0-9._-]")), QStringLiteral("_"));
    return name.isEmpty() ? QStringLiteral("model") : name;
}

void SimulationController::setStlPath(const QString &path)
{
    // Accept file:// URLs (e.g. from QML FileDialog) as well as plain paths.
    const QUrl url(path);
    const QString localPath = url.isLocalFile() ? url.toLocalFile() : path;
    if (m_stlPath != localPath) { m_stlPath = localPath; emit stlPathChanged(); resetModelRotation(); }
}

void SimulationController::rotateModel(int axis, double degrees)
{
    if (axis < 0 || axis > 2) return;
    double angle = std::fmod(m_modelRotation[axis] + degrees, 360.0);
    if (angle > 180.0) angle -= 360.0;
    if (angle <= -180.0) angle += 360.0;
    m_modelRotation[axis] = float(angle);
    emit modelRotationChanged();
}

void SimulationController::resetModelRotation()
{
    if (m_modelRotation.isNull()) return;
    m_modelRotation = QVector3D();
    emit modelRotationChanged();
}
void SimulationController::setCaseRoot(const QString &path)
{
    const QUrl url(path);
    const QString localPath = url.isLocalFile() ? url.toLocalFile() : path;
    if (localPath.isEmpty() || m_caseRoot == localPath) return;
    m_caseRoot = QDir::cleanPath(localPath);
    QSettings().setValue(kCaseRootKey, m_caseRoot);
    emit caseRootChanged();
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

void SimulationController::newProject()
{
    if (m_process.state() != QProcess::NotRunning) return;
    setStlPath({});
    resetModelRotation();
    setSpeed(kDefaultSpeed);
    setMeshQuality(QString::fromLatin1(kDefaultMeshQuality));
    m_settings.restoreDefaults();
    m_casePath.clear(); emit casePathChanged();
    m_runProcessors = 1;
    setPreviewRevision(0);
    m_previewTime = 0.0;
    resetMonitors();
    m_log.clear(); emit logChanged();
    m_status = QStringLiteral("Ready"); emit statusChanged();
}

namespace {
const QString kExampleRoot = QStringLiteral(":/examples");

QJsonObject readExample(const QString &id)
{
    QFile file(kExampleRoot + QLatin1Char('/') + id + QStringLiteral("/example.json"));
    if (!file.open(QIODevice::ReadOnly)) return {};
    return QJsonDocument::fromJson(file.readAll()).object();
}
}

QVariantList SimulationController::examples()
{
    QVariantList list;
    for (const QString &id : QDir(kExampleRoot).entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name)) {
        const QJsonObject example = readExample(id);
        if (example.isEmpty()) continue;
        list.append(QVariantMap{{QStringLiteral("id"), id},
                                {QStringLiteral("title"), example[QStringLiteral("title")].toString()},
                                {QStringLiteral("description"), example[QStringLiteral("description")].toString()}});
    }
    return list;
}

void SimulationController::openExample(const QString &id)
{
    if (m_process.state() != QProcess::NotRunning) return;
    const QJsonObject example = readExample(id);
    const QString model = example[QStringLiteral("model")].toString();
    if (model.isEmpty()) { appendLog(QStringLiteral("Example %1 not found.").arg(id)); return; }
    // The preview and the case setup read the model from a file: copy it out of the app.
    const QDir dir(QStandardPaths::writableLocation(QStandardPaths::AppLocalDataLocation) + QStringLiteral("/examples"));
    const QString stl = dir.filePath(model);
    QFile::remove(stl);
    if (!dir.mkpath(QStringLiteral(".")) || !QFile::copy(kExampleRoot + QLatin1Char('/') + id + QLatin1Char('/') + model, stl)) {
        appendLog(QStringLiteral("Cannot copy the example model to %1.").arg(stl)); return;
    }
    QFile::setPermissions(stl, QFile::ReadOwner | QFile::WriteOwner | QFile::ReadGroup | QFile::ReadOther);

    newProject();
    setStlPath(stl);
    setSpeed(example[QStringLiteral("speed")].toDouble(kDefaultSpeed));
    setMeshQuality(example[QStringLiteral("meshQuality")].toString(QString::fromLatin1(kDefaultMeshQuality)));
    const QJsonObject settings = example[QStringLiteral("settings")].toObject();
    for (auto it = settings.begin(); it != settings.end(); ++it) {
        if (!m_settings.setProperty(it.key().toUtf8().constData(), it.value().toVariant()))
            appendLog(QStringLiteral("Example %1: unknown setting %2.").arg(id, it.key()));
    }
    appendLog(QStringLiteral("Example: %1. %2").arg(example[QStringLiteral("title")].toString(), example[QStringLiteral("description")].toString()));
}

void SimulationController::openCaseFolder()
{
    // Before a run, the model's previous case if there is one.
    QString path = m_casePath;
    if (path.isEmpty() && !m_stlPath.isEmpty())
        path = QDir(m_caseRoot).filePath(caseNameFor(m_stlPath));
    if (path.isEmpty() || !QFileInfo(path).isDir()) {
        path = m_caseRoot;
        QDir().mkpath(path);
    }
    if (!QDesktopServices::openUrl(QUrl::fromLocalFile(path)))
        appendLog(QStringLiteral("Could not open %1 in the file manager.").arg(path));
}

void SimulationController::startSimulation()
{
    if (m_process.state() != QProcess::NotRunning) return;
    updateSolver();
    for (const QString &problem : {openFoamProblem(), caseRootProblem()}) {
        if (problem.isEmpty()) continue;
        m_status = QStringLiteral("Needs attention"); emit statusChanged();
        appendLog(problem + QStringLiteral(" Choose another projects folder in Settings."));
        return;
    }
    m_casePath = QDir(m_caseRoot).filePath(caseNameFor(m_stlPath));
    emit casePathChanged();
    setPreviewRevision(0);
    m_previewTime = 0.0;
    QString message;
    CaseOptions options{m_stlPath, m_casePath, m_meshQuality, m_speed};
    m_settings.apply(&options);
    options.rotation = {m_modelRotation.x(), m_modelRotation.y(), m_modelRotation.z()};
    QString note;
    if (options.processors > 1 && !m_parallelAvailable) {
        note = QStringLiteral("This OpenFOAM environment has no MPI; running on 1 processor.");
        options.processors = 1;
    }
    if (!OpenFoamCase::prepare(options, &message)) {
        m_status = QStringLiteral("Needs attention"); emit statusChanged(); appendLog(message); return;
    }
    if (!note.isEmpty()) message += QLatin1Char('\n') + note;
    if (options.processors > 1) message += QStringLiteral("\nParallel run on %1 processors (%2).").arg(options.processors).arg(m_mpiName);
    // Fields are generated in 0.orig and copied after meshing, as snappyHexMesh changes the patches.
    const QString casePath = m_casePath;
    const Step copyFields{QStringLiteral("copyInitialFields"), {}, false, [casePath] {
        const QDir dir(casePath);
        return copyDirectory(dir.filePath(QStringLiteral("0.orig")), dir.filePath(QStringLiteral("0")));
    }};
    m_steps = {{QStringLiteral("blockMesh"), {QStringLiteral("blockMesh")}, true},
               {QStringLiteral("surfaceFeatureExtract"), {QStringLiteral("surfaceFeatureExtract")}}};
    // 2D: the slab snappyHexMesh meshed becomes one cell thick (a serial step, on the whole mesh).
    QList<Step> extrude;
    if (options.twoDimensional)
        extrude = {{QStringLiteral("extrudeMesh"), {QStringLiteral("extrudeMesh")}},
                   {QStringLiteral("finish2DMesh"), {}, true, [this, casePath] {
                        const QString error = OpenFoamCase::finishTwoDimensionalMesh(casePath);
                        // snappyHexMesh reported the slab's cells; show the 2D mesh's.
                        if (error.isEmpty()) { m_cellCount = OpenFoamCase::meshCellCount(casePath); scheduleMonitorUpdate(); }
                        return error;
                    }}};
    if (options.processors > 1) {
        // Mesh in parallel, then reassemble the mesh (for the preview, and so the fields are
        // decomposed together with it), decompose again with the fields and solve in parallel.
        const int n = options.processors;
        const QString parallel = QStringLiteral("-parallel");
        m_steps += {{QStringLiteral("decomposeMesh"), {QStringLiteral("decomposePar"), {QStringLiteral("-force")}}},
                    {QStringLiteral("snappyHexMesh"), {QStringLiteral("snappyHexMesh"), {QStringLiteral("-overwrite"), parallel}, n}},
                    {QStringLiteral("reconstructParMesh"), {QStringLiteral("reconstructParMesh"), {QStringLiteral("-constant")}}, true}};
        m_steps += extrude;
        m_steps += {copyFields,
                    {QStringLiteral("decomposePar"), {QStringLiteral("decomposePar"), {QStringLiteral("-force")}}},
                    {m_solver, {m_solver, {parallel}, n}},
                    {QStringLiteral("reconstructPar"), {QStringLiteral("reconstructPar")}, true}};
        m_resultsPath = QDir(m_casePath).filePath(QStringLiteral("processor0"));
        m_runProcessors = options.processors;
    } else {
        m_steps += {{QStringLiteral("snappyHexMesh"), {QStringLiteral("snappyHexMesh"), {QStringLiteral("-overwrite")}}, true}};
        m_steps += extrude;
        m_steps += {copyFields,
                    {m_solver, {m_solver}}};
        m_resultsPath = m_casePath;
        m_runProcessors = 1;
    }
    m_step = 0; m_stopRequested = false; resetMonitors(); appendLog(message); runNextStep();
}

void SimulationController::runNextStep()
{
    if (m_step >= m_steps.size()) {
        m_status = QStringLiteral("Complete"); emit statusChanged(); appendLog(QStringLiteral("Workflow completed. OpenFOAM fields are in %1").arg(m_casePath)); return;
    }
    const Step &step = m_steps[m_step];
    if (!m_openFoam.found()) {
        m_status = QStringLiteral("OpenFOAM unavailable"); emit statusChanged();
        appendLog(QStringLiteral("OpenFOAM not found. ") + OpenFoamEnvironment::setupHint()); return;
    }
    m_lineBuffer.clear();
    m_stepLog.setFileName(QDir(m_casePath).filePath(step.name + QStringLiteral(".log")));
    if (!m_stepLog.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        appendLog(QStringLiteral("Cannot write %1: %2").arg(m_stepLog.fileName(), m_stepLog.errorString()));
    m_status = QStringLiteral("Running %1").arg(step.name); emit statusChanged();
    if (step.action) {
        // Runs in the app; continue from the event loop, as after a program.
        const QString error = step.action();
        QMetaObject::invokeMethod(this, [this, error] {
            const QString &name = m_steps[m_step].name;
            if (!error.isEmpty()) {
                appendLog(error);
                finishStep(QStringLiteral("%1 failed.").arg(name));
                m_status = QStringLiteral("Failed"); emit statusChanged(); return;
            }
            finishStep(QStringLiteral("%1 finished.").arg(name));
            if (m_steps[m_step].refreshPreview)
                setPreviewRevision(m_previewRevision + 1);
            ++m_step;
            runNextStep();
        }, Qt::QueuedConnection);
        return;
    }
    m_process.setWorkingDirectory(m_casePath);
    watchTimeDirectories(step.name == m_solver);
    const QString commandLine = m_openFoam.start(&m_process, step.command);
    writeStepLog(QStringLiteral("$ %1\n").arg(commandLine).toLocal8Bit());
    appendLog(QStringLiteral("$ %1").arg(commandLine));
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
    if (m_process.state() == QProcess::NotRunning) return;
    m_stopRequested = true;
    m_status = QStringLiteral("Stopping"); emit statusChanged();
    OpenFoamEnvironment::stop(&m_process);
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
        m_caseWatcher.addPath(m_resultsPath);
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
    // A new time directory appears first and its field files follow: give them a moment before
    // showing it. Not restarted by later changes, so frequent writes still refresh the preview
    // about once a second instead of postponing it until the solver stops.
    double time = 0.0;
    const QString latest = latestTimeDirectory(m_resultsPath, &time);
    if (latest.isEmpty() || time <= m_previewTime) return;
    if (!m_timeStepSettle.isActive()) m_timeStepSettle.start();
}

void SimulationController::publishLatestTime()
{
    double time = 0.0;
    if (latestTimeDirectory(m_resultsPath, &time).isEmpty() || time <= m_previewTime) return;
    m_previewTime = time;
    setPreviewRevision(m_previewRevision + 1);
}
