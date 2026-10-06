#pragma once
#include <QFile>
#include <QObject>
#include <QProcess>

class SimulationController : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString stlPath READ stlPath WRITE setStlPath NOTIFY stlPathChanged)
    Q_PROPERTY(QString caseRoot READ caseRoot WRITE setCaseRoot NOTIFY caseRootChanged)
    Q_PROPERTY(double speed READ speed WRITE setSpeed NOTIFY speedChanged)
    Q_PROPERTY(QString meshQuality READ meshQuality WRITE setMeshQuality NOTIFY meshQualityChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString solver READ solver NOTIFY solverChanged)
    Q_PROPERTY(QString log READ log NOTIFY logChanged)
public:
    explicit SimulationController(QObject *parent = nullptr);
    QString stlPath() const { return m_stlPath; }
    QString caseRoot() const { return m_caseRoot; }
    double speed() const { return m_speed; }
    QString meshQuality() const { return m_meshQuality; }
    QString status() const { return m_status; }
    QString solver() const { return m_solver; }
    QString log() const { return m_log; }
    void setStlPath(const QString &path);
    void setCaseRoot(const QString &path);
    void setSpeed(double value);
    void setMeshQuality(const QString &value);
    Q_INVOKABLE void startSimulation();
    Q_INVOKABLE void stopSimulation();
signals:
    void stlPathChanged(); void caseRootChanged(); void speedChanged(); void meshQualityChanged();
    void statusChanged(); void solverChanged(); void logChanged();
private:
    void appendLog(const QString &line);
    void runNextStep();
    void finishStep(const QString &summary);
    void writeStepLog(const QByteArray &data);
    QString m_stlPath;
    QString m_caseRoot;
    double m_speed = 20.0;
    QString m_meshQuality = QStringLiteral("Coarse");
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
};
