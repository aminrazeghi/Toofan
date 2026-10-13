#include "OpenFoamEnvironment.h"
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>
#include <QStandardPaths>

#ifdef Q_OS_WIN

namespace {
// OpenFOAM's version from its directory name (OpenFOAM-v2606), else from META-INFO/api-info.
QString projectVersion(const QDir &root)
{
    static const QRegularExpression nameRe(QStringLiteral("^OpenFOAM-(v\\d+)$"));
    if (const auto match = nameRe.match(root.dirName()); match.hasMatch()) return match.captured(1);
    QFile info(root.filePath(QStringLiteral("META-INFO/api-info")));
    if (info.open(QIODevice::ReadOnly | QIODevice::Text)) {
        static const QRegularExpression apiRe(QStringLiteral("^api=(\\d+)"), QRegularExpression::MultilineOption);
        if (const auto match = apiRe.match(QString::fromLatin1(info.readAll())); match.hasMatch())
            return QStringLiteral("v") + match.captured(1);
    }
    return {};
}
}

OpenFoamEnvironment::OpenFoamEnvironment()
{
    // OPENFOAM_DIR (an OpenFOAM-v<version> directory) overrides; then the copy bundled next to
    // the executable (packaging/package-windows.ps1).
    QStringList candidates;
    if (const QString dir = qEnvironmentVariable("OPENFOAM_DIR"); !dir.isEmpty()) candidates << dir;
    const QDir appDir(QCoreApplication::applicationDirPath());
    for (const QString &name : appDir.entryList({QStringLiteral("OpenFOAM-v*")}, QDir::Dirs, QDir::Name | QDir::Reversed))
        candidates << appDir.filePath(name);
    for (const QString &candidate : candidates) {
        const QDir root(candidate);
        const QDir platforms(root.filePath(QStringLiteral("platforms")));
        for (const QString &arch : platforms.entryList(QDir::Dirs | QDir::NoDotAndDotDot)) {
            const QString bin = platforms.filePath(arch + QStringLiteral("/bin"));
            if (QFileInfo::exists(bin + QStringLiteral("/blockMesh.exe"))) {
                m_root = root.absolutePath();
                m_binDir = QDir(bin).absolutePath();
                m_version = projectVersion(root);
                return;
            }
        }
    }
}

QString OpenFoamEnvironment::setupHint()
{
    return QStringLiteral("Reinstall Toofan, or set OPENFOAM_DIR to an OpenFOAM-v<version> directory of the OpenFOAM for Windows (MinGW) build.");
}

QString OpenFoamEnvironment::start(QProcess *process, const Command &command) const
{
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("WM_PROJECT_DIR"), QDir::toNativeSeparators(m_root));
    env.insert(QStringLiteral("WM_PROJECT"), QStringLiteral("OpenFOAM"));
    env.insert(QStringLiteral("WM_PROJECT_VERSION"), m_version);
    env.insert(QStringLiteral("FOAM_SIGFPE"), QStringLiteral("1"));
    // The programs' DLLs, and MS-MPI's msmpi.dll, are in bin; MPI processes inherit this too.
    env.insert(QStringLiteral("PATH"), QDir::toNativeSeparators(m_binDir) + QLatin1Char(';') + env.value(QStringLiteral("PATH")));
    process->setProcessEnvironment(env);

    const QString program = QDir::toNativeSeparators(QDir(m_binDir).filePath(command.program + QStringLiteral(".exe")));
    QString executable = program;
    QStringList arguments = command.arguments;
    if (command.processors > 1) {
        executable = QDir::toNativeSeparators(QDir(m_binDir).filePath(QStringLiteral("mpiexec.exe")));
        arguments = QStringList{QStringLiteral("-n"), QString::number(command.processors), program} + arguments;
    }
    process->start(executable, arguments);
    QStringList shown{command.processors > 1 ? QStringLiteral("mpiexec") : command.program};
    if (command.processors > 1) shown << QStringLiteral("-n") << QString::number(command.processors) << command.program;
    return (shown + command.arguments).join(QLatin1Char(' '));
}

void OpenFoamEnvironment::probeParallel(QObject *, const std::function<void(const QString &)> &done) const
{
    // MS-MPI is bundled in bin: msmpi.dll (which every OpenFOAM program loads), mpiexec and smpd.
    const QDir bin(m_binDir);
    const bool mpi = found() && QFileInfo::exists(bin.filePath(QStringLiteral("mpiexec.exe")))
                     && QFileInfo::exists(bin.filePath(QStringLiteral("smpd.exe")));
    done(mpi ? QStringLiteral("MS-MPI") : QString());
}

void OpenFoamEnvironment::stop(QProcess *process)
{
    // Console programs ignore QProcess::terminate() on Windows, and mpiexec's ranks run under
    // its smpd: end the whole process tree.
    QProcess::execute(QStringLiteral("taskkill"), {QStringLiteral("/PID"), QString::number(process->processId()),
                                                   QStringLiteral("/T"), QStringLiteral("/F")});
}

#else

OpenFoamEnvironment::OpenFoamEnvironment()
{
    // OPENFOAM_BASHRC overrides; then a copy bundled with the app (packaging/package-linux.sh);
    // then the newest system install.
    m_bashrc = qEnvironmentVariable("OPENFOAM_BASHRC");
    if (m_bashrc.isEmpty()) {
        const QString bundled = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("../openfoam/etc/bashrc"));
        if (QFileInfo::exists(bundled))
            m_bashrc = QFileInfo(bundled).canonicalFilePath();
    }
    if (m_bashrc.isEmpty()) {
        QDir installs(QStringLiteral("/usr/lib/openfoam"));
        const QStringList versions = installs.entryList(QStringList{QStringLiteral("openfoam*")}, QDir::Dirs, QDir::Name | QDir::Reversed);
        for (const QString &version : versions) {
            const QString candidate = installs.filePath(version + QStringLiteral("/etc/bashrc"));
            if (QFileInfo::exists(candidate)) { m_bashrc = candidate; break; }
        }
    }
    if (m_bashrc.isEmpty()) return;

    // Source the bashrc once and keep the environment it leaves (NUL-separated, as values may
    // contain newlines); every program then starts directly in it. The bashrc treats positional
    // parameters as config settings, so clear them before sourcing.
    QProcess shell;
    shell.start(QStringLiteral("/bin/bash"), {QStringLiteral("-c"),
                QStringLiteral("rc=\"$1\"; set --; source \"$rc\" >/dev/null 2>&1; exec env -0"),
                QStringLiteral("toofan"), m_bashrc});
    if (!shell.waitForFinished(30000) || shell.exitStatus() != QProcess::NormalExit || shell.exitCode() != 0) {
        shell.kill();
        return;
    }
    QProcessEnvironment environment;
    for (const QByteArray &entry : shell.readAllStandardOutput().split('\0')) {
        const qsizetype equals = entry.indexOf('=');
        if (equals > 0)
            environment.insert(QString::fromLocal8Bit(entry.left(equals)), QString::fromLocal8Bit(entry.mid(equals + 1)));
    }
    // Without WM_PROJECT_DIR the bashrc did not set OpenFOAM up: treat it as not found.
    if (!environment.contains(QStringLiteral("WM_PROJECT_DIR"))) return;
    m_environment = environment;
    m_root = QDir::cleanPath(QFileInfo(m_bashrc).absoluteDir().absoluteFilePath(QStringLiteral("..")));
}

QString OpenFoamEnvironment::setupHint()
{
    return QStringLiteral("Set OPENFOAM_BASHRC to its etc/bashrc file.");
}

QString OpenFoamEnvironment::executable(const QString &name) const
{
    return QStandardPaths::findExecutable(name, m_environment.value(QStringLiteral("PATH")).split(QLatin1Char(':'), Qt::SkipEmptyParts));
}

QString OpenFoamEnvironment::start(QProcess *process, const Command &command) const
{
    QStringList line{command.program};
    if (command.processors > 1) {
        // --oversubscribe: allow more processes than physical cores (Open MPI counts cores, not threads).
        line = QStringList{QStringLiteral("mpirun"), QStringLiteral("--oversubscribe"), QStringLiteral("-np"),
                           QString::number(command.processors), command.program};
    }
    line += command.arguments;
    process->setProcessEnvironment(m_environment);
    // An unknown program is started by name, so the step fails with "could not start".
    QString program = executable(command.program);
    if (program.isEmpty()) program = command.program;
    if (command.processors > 1) {
        // mpirun passes its environment on to the processes it starts on this machine.
        const QString mpirun = executable(QStringLiteral("mpirun"));
        process->start(mpirun.isEmpty() ? QStringLiteral("mpirun") : mpirun, line.mid(1, 3) + QStringList{program} + command.arguments);
    } else {
        process->start(program, command.arguments);
    }
    return line.join(QLatin1Char(' '));
}

void OpenFoamEnvironment::probeParallel(QObject *, const std::function<void(const QString &)> &done) const
{
    // Parallel runs need an MPI-enabled OpenFOAM (not the "dummy" Pstream) and its mpirun.
    const QString mpi = m_environment.value(QStringLiteral("FOAM_MPI"));
    done(found() && !mpi.isEmpty() && mpi != QStringLiteral("dummy") && !executable(QStringLiteral("mpirun")).isEmpty() ? mpi : QString());
}

void OpenFoamEnvironment::stop(QProcess *process)
{
    // The program itself, or mpirun, which passes SIGTERM on to its processes.
    process->terminate();
}

#endif
