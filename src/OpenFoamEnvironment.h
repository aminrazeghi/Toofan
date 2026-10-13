#pragma once
#include <QProcessEnvironment>
#include <QString>
#include <QStringList>
#include <functional>

class QObject;
class QProcess;

// Locates OpenFOAM and starts its programs directly, in OpenFOAM's environment.
// Linux: the environment is what OpenFOAM's etc/bashrc sets up, captured once from a bash that
// sources it; parallel runs use Open MPI's mpirun. Windows (OpenCFD's MinGW build): the few
// variables OpenFOAM reads (as its setEnvVariables .bat sets them); parallel runs use MS-MPI's
// mpiexec from OpenFOAM's bin directory.
class OpenFoamEnvironment {
public:
    struct Command {
        QString program;        // OpenFOAM program name, e.g. snappyHexMesh
        QStringList arguments;
        int processors = 1;     // > 1: run under MPI with -parallel already in arguments
    };

    OpenFoamEnvironment();
    bool found() const { return !m_root.isEmpty(); }
    // OpenFOAM's directory (WM_PROJECT_DIR), for messages and path checks; empty if not found.
    QString root() const { return m_root; }
    // How to point the app at an OpenFOAM installation, for the message when none is found.
    static QString setupHint();
    // Starts command in process (its working directory is set by the caller) and returns the
    // command line as shown in the log.
    QString start(QProcess *process, const Command &command) const;
    // Calls done with the MPI implementation's name, or an empty string when parallel runs are
    // not possible. May call back later (context guards the callback).
    void probeParallel(QObject *context, const std::function<void(const QString &)> &done) const;
    // Stops a running command together with the MPI processes it started.
    static void stop(QProcess *process);

private:
    QString m_root;
#ifdef Q_OS_WIN
    QString m_binDir;    // platforms/<arch>/bin: programs, their DLLs, MS-MPI
    QString m_version;   // WM_PROJECT_VERSION, e.g. v2606
#else
    QString m_bashrc;
    QProcessEnvironment m_environment;  // after sourcing m_bashrc
    QString executable(const QString &name) const;  // in m_environment's PATH, or ""
#endif
};
