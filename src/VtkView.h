#pragma once

#ifdef WINDTUNNEL_HAS_VTK
#include <QQuickVTKItem.h>
class vtkRenderWindow;
#else
#include <QQuickItem>
#endif

#include <QList>
#include <QString>
#include <QVariantList>
#include <QVector3D>
#include <QVector4D>
#include <QtQml/qqmlregistration.h>
#include <memory>

struct CaseData;
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
    // "domain" (tunnel walls, cut away towards the camera), "slice" (mid-plane) or "streamlines".
    Q_PROPERTY(QString renderMode READ renderMode WRITE setRenderMode NOTIFY renderModeChanged)
    // Field used for coloring: U, p, k, omega, and for compressible cases T, rho, Ma.
    Q_PROPERTY(QString field READ field WRITE setField NOTIFY fieldChanged)
    // Orientation of the imported STL, degrees about x, then y, then z (as the case will be meshed).
    Q_PROPERTY(QVector3D modelRotation READ modelRotation WRITE setModelRotation NOTIFY modelRotationChanged)
    // Window edges covered by floating panels, in item pixels (left, top, right, bottom). The model
    // is centred and framed in the uncovered area, and the color bar kept inside it.
    Q_PROPERTY(QVector4D viewInsets READ viewInsets WRITE setViewInsets NOTIFY viewInsetsChanged)
    // Contour palette, one of colorMaps()[i].value.
    Q_PROPERTY(QString colorMap READ colorMap WRITE setColorMap NOTIFY colorMapChanged)
    // Background and annotation colors follow the app theme.
    Q_PROPERTY(bool darkTheme READ darkTheme WRITE setDarkTheme NOTIFY darkThemeChanged)
    // One-line description of what is shown, e.g. "Mesh · 76,241 cells".
    Q_PROPERTY(QString previewInfo READ previewInfo NOTIFY previewInfoChanged)
    // Saved time steps of the case (seconds, ascending), for scrubbing through the results.
    Q_PROPERTY(QVariantList times READ times NOTIFY timesChanged)
    // Time step shown, an index into times; -1 follows the latest one.
    Q_PROPERTY(int timeIndex READ timeIndex WRITE setTimeIndex NOTIFY timeIndexChanged)
    // True while the case is being read or the view rebuilt in the background.
    Q_PROPERTY(bool loading READ loading NOTIFY loadingChanged)

public:
    explicit VtkView(QQuickItem *parent = nullptr);
    ~VtkView() override;
    QString stlFile() const { return m_stlFile; }
    void setStlFile(const QString &path);
    QString casePath() const { return m_casePath; }
    void setCasePath(const QString &path);
    int previewRevision() const { return m_previewRevision; }
    void setPreviewRevision(int revision);
    QString renderMode() const { return m_renderMode; }
    void setRenderMode(const QString &mode);
    QString field() const { return m_field; }
    void setField(const QString &field);
    QVector3D modelRotation() const { return m_modelRotation; }
    void setModelRotation(const QVector3D &rotation);
    QVector4D viewInsets() const { return m_viewInsets; }
    void setViewInsets(const QVector4D &insets);
    QString colorMap() const { return m_colorMap; }
    void setColorMap(const QString &colorMap);
    bool darkTheme() const { return m_darkTheme; }
    void setDarkTheme(bool dark);
    // [{value, label, colors: ["#rrggbb", ...]}] for palette pickers.
    Q_INVOKABLE QVariantList colorMaps() const;
    QVariantList times() const;
    int timeIndex() const { return m_timeIndex; }
    void setTimeIndex(int index);
    QString previewInfo() const { return m_previewInfo; }
    bool loading() const { return m_loading; }

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
    void renderModeChanged();
    void fieldChanged();
    void modelRotationChanged();
    void viewInsetsChanged();
    void colorMapChanged();
    void darkThemeChanged();
    void previewInfoChanged();
    void loadingChanged();
    void timesChanged();
    void timeIndexChanged();

private:
    void requestCasePreview(bool reread);
    void startJob();
    void applyJobResult(int generation, std::shared_ptr<const CaseData> data, std::shared_ptr<const CasePreview> preview);
    void resetCasePreview();
    void updateScene();
    void setPreviewInfo(const QString &info);
    void setLoading(bool loading);
    void setTimes(const QList<double> &times);

    QString m_stlFile;
    QString m_casePath;
    int m_previewRevision = 0;
    QString m_renderMode = QStringLiteral("slice");
    QString m_field = QStringLiteral("U");
    QVector3D m_modelRotation;
    QVector4D m_viewInsets;
    QString m_colorMap = QStringLiteral("viridis");
    bool m_darkTheme = true;
    QString m_previewInfo;
    QList<double> m_times;
    int m_timeIndex = -1;
    // GUI thread state. Background jobs read the case (when m_rereadPending) and build the
    // preview for the current mode and field from the cached data.
    std::shared_ptr<const CaseData> m_data;       // latest case read from disk
    std::shared_ptr<const CasePreview> m_preview; // what the scene shows
    int m_loadGeneration = 0;                     // bumped to discard jobs for an outdated case
    bool m_loading = false;                       // a background job is running
    bool m_jobPending = false;                    // another job was requested meanwhile
    bool m_rereadPending = false;                 // that job must re-read the case
};
