#include "OpenFoamEnvironment.h"
#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>

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
    if (!m_bashrc.isEmpty())
        m_root = QFileInfo(m_bashrc).absoluteDir().absoluteFilePath(QStringLiteral(".."));
    m_root = QDir::cleanPath(m_root);
}

QString OpenFoamEnvironment::setupHint()
{
    return QStringLiteral("Set OPENFOAM_BASHRC to its etc/bashrc file.");
}

namespace {
// OpenFOAM's bashrc sets WM_PROJECT_DIR, FOAM_* paths, and library paths.
// Run each program in a fresh sourced shell so the GUI itself need not be launched from one.
// The bashrc treats positional parameters as config settings, so clear them before sourcing.
QStringList bashArguments(const QString &bashrc, const QStringList &command)
{
    return QStringList{QStringLiteral("-c"),
                       QStringLiteral("rc=\"$1\"; shift; cmd=(\"$@\"); set --; source \"$rc\" >/dev/null && exec \"${cmd[@]}\""),
                       QStringLiteral("toofan"), bashrc} + command;
}
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
    process->start(QStringLiteral("/bin/bash"), bashArguments(m_bashrc, line));
    return line.join(QLatin1Char(' '));
}

void OpenFoamEnvironment::probeParallel(QObject *context, const std::function<void(const QString &)> &done) const
{
    if (!found()) { done({}); return; }
    // Parallel runs need an MPI-enabled OpenFOAM (not the "dummy" Pstream) and its mpirun.
    auto *probe = new QProcess(context);
    QObject::connect(probe, &QProcess::finished, context, [probe, done](int code, QProcess::ExitStatus status) {
        const QString mpi = QString::fromLocal8Bit(probe->readAllStandardOutput()).trimmed();
        done(status == QProcess::NormalExit && code == 0 ? mpi : QString());
        probe->deleteLater();
    });
    probe->start(QStringLiteral("/bin/bash"),
                 bashArguments(m_bashrc, {QStringLiteral("bash"), QStringLiteral("-c"),
                                          QStringLiteral("[ -n \"$FOAM_MPI\" ] && [ \"$FOAM_MPI\" != dummy ] && command -v mpirun >/dev/null && echo \"$FOAM_MPI\"")}));
}

void OpenFoamEnvironment::stop(QProcess *process)
{
    // bash has exec'd the program (or mpirun, which passes SIGTERM on to its processes).
    process->terminate();
}

#endif
