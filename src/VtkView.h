#pragma once

#ifdef WINDTUNNEL_HAS_VTK
#include <QQuickVTKItem.h>
class vtkRenderWindow;
#else
#include <QQuickItem>
#endif

#include <QString>
#include <QtQml/qqmlregistration.h>
#include <memory>

struct CasePreview;

#ifdef WINDTUNNEL_HAS_VTK
class VtkView : public QQuickVTKItem
#else
class VtkView : public QQuickItem
#endif
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString stlFile READ stlFile WRITE setStlFile NOTIFY stlFileChanged)
    // OpenFOAM case to preview. Each increase of previewRevision reloads its mesh and latest
    // time step; 0 shows the STL only.
    Q_PROPERTY(QString casePath READ casePath WRITE setCasePath NOTIFY casePathChanged)
    Q_PROPERTY(int previewRevision READ previewRevision WRITE setPreviewRevision NOTIFY previewRevisionChanged)
    // One-line description of what is shown, e.g. "Mesh · 76,241 cells".
    Q_PROPERTY(QString previewInfo READ previewInfo NOTIFY previewInfoChanged)

public:
    explicit VtkView(QQuickItem *parent = nullptr);
    ~VtkView() override;
    QString stlFile() const { return m_stlFile; }
    void setStlFile(const QString &path);
    QString casePath() const { return m_casePath; }
    void setCasePath(const QString &path);
    int previewRevision() const { return m_previewRevision; }
    void setPreviewRevision(int revision);
    QString previewInfo() const { return m_previewInfo; }

#ifdef WINDTUNNEL_HAS_VTK
    static void setGraphicsApi();
    vtkUserData initializeVTK(vtkRenderWindow *renderWindow) override;
#else
    static void setGraphicsApi() {}
#endif

signals:
    void stlFileChanged();
    void casePathChanged();
    void previewRevisionChanged();
    void previewInfoChanged();

private:
    void requestCasePreview();
    void applyCasePreview(int generation, std::shared_ptr<const CasePreview> preview);
    void updateScene();
    void setPreviewInfo(const QString &info);

    QString m_stlFile;
    QString m_casePath;
    int m_previewRevision = 0;
    QString m_previewInfo;
    std::shared_ptr<const CasePreview> m_preview; // latest loaded case preview (GUI thread)
    int m_loadGeneration = 0;                     // bumped to discard loads for an outdated case
    bool m_loading = false;                       // a background load is running
    bool m_reloadPending = false;                 // another revision arrived meanwhile
};
