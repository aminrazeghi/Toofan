#pragma once
#include "CaseSettings.h"
#include <QFile>
#include <QFileSystemWatcher>
#include <QMap>
#include <QObject>
#include <QPointF>
#include <QProcess>
#include <QSet>
#include <QTimer>
#include <QVariantList>
#include <QVector3D>
#include <cmath>

class SimulationController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString stlPath READ stlPath WRITE setStlPath NOTIFY stlPathChanged)
    Q_PROPERTY(QString caseRoot READ caseRoot WRITE setCaseRoot NOTIFY caseRootChanged)
    Q_PROPERTY(CaseSettings *settings READ settings CONSTANT)
    // Model orientation in degrees about x, then y, then z; each in (-180, 180].
    Q_PROPERTY(QVector3D modelRotation READ modelRotation NOTIFY modelRotationChanged)
    Q_PROPERTY(double speed READ speed WRITE setSpeed NOTIFY speedChanged)
    Q_PROPERTY(QString meshQuality READ meshQuality WRITE setMeshQuality NOTIFY meshQualityChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    // A workflow is in progress (including while it is being stopped).
    Q_PROPERTY(bool running READ running NOTIFY statusChanged)
    Q_PROPERTY(QString solver READ solver NOTIFY solverChanged)
    Q_PROPERTY(QString log READ log NOTIFY logChanged)
    Q_PROPERTY(QString casePath READ casePath NOTIFY casePathChanged)
    // Bumped whenever the case has a new mesh or time step to show; 0 before meshing.
    Q_PROPERTY(int previewRevision READ previewRevision NOTIFY previewRevisionChanged)
    // Live solver monitors, parsed from the running step's output. NaN / 0 until known.
    Q_PROPERTY(double dragCoefficient READ dragCoefficient NOTIFY monitorsChanged)
    Q_PROPERTY(double liftCoefficient READ liftCoefficient NOTIFY monitorsChanged)
    Q_PROPERTY(int cellCount READ cellCount NOTIFY monitorsChanged)
    Q_PROPERTY(double simulatedTime READ simulatedTime NOTIFY monitorsChanged)
    // [{name, times: [...], values: [...]}] of initial residuals per field and time step.
    Q_PROPERTY(QVariantList residuals READ residuals NOTIFY monitorsChanged)
    // Same shape, one series each: force coefficient history per time step.
    Q_PROPERTY(QVariantList dragHistory READ dragHistory NOTIFY monitorsChanged)
    Q_PROPERTY(QVariantList liftHistory READ liftHistory NOTIFY monitorsChanged)
public:
    explicit SimulationController(QObject *parent = nullptr);
    QString stlPath() const { return m_stlPath; }
    QString caseRoot() const { return m_caseRoot; }
    CaseSettings *settings() { return &m_settings; }
    QVector3D modelRotation() const { return m_modelRotation; }
    // axis: 0 = x, 1 = y, 2 = z.
    Q_INVOKABLE void rotateModel(int axis, double degrees);
    Q_INVOKABLE void resetModelRotation();
    double speed() const { return m_speed; }
    QString meshQuality() const { return m_meshQuality; }
    QString status() const { return m_status; }
    bool running() const { return m_status.startsWith(QStringLiteral("Running ")) || m_status == QStringLiteral("Stopping"); }
    QString solver() const { return m_solver; }
    QString log() const { return m_log; }
    QString casePath() const { return m_casePath; }
    int previewRevision() const { return m_previewRevision; }
    double dragCoefficient() const { return m_dragCoefficient; }
    double liftCoefficient() const { return m_liftCoefficient; }
    int cellCount() const { return m_cellCount; }
    double simulatedTime() const { return m_time; }
    QVariantList residuals() const;
    QVariantList dragHistory() const;
    QVariantList liftHistory() const;
    void setStlPath(const QString &path);
    void setCaseRoot(const QString &path);
    void setSpeed(double value);
    void setMeshQuality(const QString &value);
    Q_INVOKABLE void startSimulation();
    // Clears the model, results and log and restores default settings. Cases on disk are kept.
    Q_INVOKABLE void newProject();
    // Opens the current case directory (or, before a run, the case root) in the file manager.
    Q_INVOKABLE void openCaseFolder();
    Q_INVOKABLE void stopSimulation();
signals:
    void stlPathChanged(); void modelRotationChanged(); void caseRootChanged(); void speedChanged(); void meshQualityChanged();
    void statusChanged(); void solverChanged(); void logChanged(); void monitorsChanged();
    void casePathChanged(); void previewRevisionChanged();
private:
    void appendLog(const QString &line);
    void updateSolver();
    void runNextStep();
    void finishStep(const QString &summary);
    void writeStepLog(const QByteArray &data);
    void parseOutput(const QByteArray &output);
    void parseLine(const QString &line);
    void resetMonitors();
    void scheduleMonitorUpdate();
    void setPreviewRevision(int revision);
    void watchTimeDirectories(bool enable);
    void onCaseDirectoryChanged();
    void publishLatestTime();
    QString m_stlPath;
    QString m_caseRoot;
    CaseSettings m_settings;
    QVector3D m_modelRotation;
    static constexpr double kDefaultSpeed = 20.0;
    static constexpr auto kDefaultMeshQuality = "Coarse";
    double m_speed = kDefaultSpeed;
    QString m_meshQuality = QString::fromLatin1(kDefaultMeshQuality);
    QString m_status = QStringLiteral("Ready");
    QString m_solver = QStringLiteral("pimpleFoam");
    QString m_log;
    QString m_casePath;
    QString m_openFoamBashrc;
    struct Step { QString name; QStringList command; }; // name.log is written in the case directory
    QList<Step> m_steps;
    QFile m_stepLog;
    bool m_stopRequested = false;
    int m_step = 0;
    QProcess m_process;
    QByteArray m_lineBuffer;
    double m_time = 0.0;
    QSet<QString> m_residualsThisStep;
    QMap<QString, QList<QPointF>> m_residualHistory;
    QList<QPointF> m_dragHistory, m_liftHistory;
    double m_dragCoefficient = std::nan("");
    double m_liftCoefficient = std::nan("");
    int m_cellCount = 0;
    int m_previewRevision = 0;
    double m_previewTime = 0.0;         // latest time step announced to the preview
    QFileSystemWatcher m_caseWatcher;   // watches the case and newest time directory while the solver runs
    QTimer m_timeStepSettle;            // waits for a time directory to be completely written
    QTimer m_monitorTimer; // batches monitor notifications so QML repaints at most a few times per second
};
