#include "SimulationController.h"
#include "OpenFoamCase.h"
#include <QDir>
#include <QFileInfo>
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
    connect(&m_process, &QProcess::readyReadStandardOutput, this, [this] {
        const QByteArray output = m_process.readAllStandardOutput();
        writeStepLog(output);
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
void SimulationController::setSpeed(double value) { if (!qFuzzyCompare(m_speed, value)) { m_speed = value; m_solver = OpenFoamCase::solverForSpeed(value); emit speedChanged(); emit solverChanged(); } }
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
    m_solver = OpenFoamCase::solverForSpeed(m_speed); emit solverChanged();
    m_casePath = QDir(m_caseRoot).filePath(QFileInfo(m_stlPath).completeBaseName());
    QString message;
    if (!OpenFoamCase::prepare({m_stlPath, m_casePath, m_meshQuality, m_speed}, &message)) {
        m_status = QStringLiteral("Needs attention"); emit statusChanged(); appendLog(message); return;
    }
    // Fields are generated in 0.orig and copied after meshing, as snappyHexMesh changes the patches.
    m_steps = {{QStringLiteral("blockMesh"), {QStringLiteral("blockMesh")}},
               {QStringLiteral("surfaceFeatureExtract"), {QStringLiteral("surfaceFeatureExtract")}},
               {QStringLiteral("snappyHexMesh"), {QStringLiteral("snappyHexMesh"), QStringLiteral("-overwrite")}},
               {QStringLiteral("copyInitialFields"), {QStringLiteral("cp"), QStringLiteral("-r"), QStringLiteral("0.orig"), QStringLiteral("0")}},
               {m_solver, {m_solver}}};
    m_step = 0; m_stopRequested = false; appendLog(message); runNextStep();
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
    m_stepLog.setFileName(QDir(m_casePath).filePath(step.name + QStringLiteral(".log")));
    if (!m_stepLog.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text))
        appendLog(QStringLiteral("Cannot write %1: %2").arg(m_stepLog.fileName(), m_stepLog.errorString()));
    writeStepLog(QStringLiteral("$ %1\n").arg(commandLine).toLocal8Bit());
    m_status = QStringLiteral("Running %1").arg(step.name); emit statusChanged();
    appendLog(QStringLiteral("$ %1").arg(commandLine));
    m_process.setWorkingDirectory(m_casePath);
    // OpenFOAM's bashrc sets WM_PROJECT_DIR, FOAM_* paths, and library paths.
    // Run each utility in a fresh sourced shell so the GUI itself need not be launched from one.
    QStringList args{QStringLiteral("-lc"),
                     QStringLiteral("source \"$1\" >/dev/null && shift && exec \"$@\""),
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
    writeStepLog(QStringLiteral("\n# %1\n").arg(summary).toLocal8Bit());
    m_stepLog.close();
    appendLog(summary);
}

void SimulationController::stopSimulation()
{
    if (m_process.state() != QProcess::NotRunning) { m_stopRequested = true; m_process.terminate(); m_status = QStringLiteral("Stopping"); emit statusChanged(); }
}
