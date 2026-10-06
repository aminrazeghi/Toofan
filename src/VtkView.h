#pragma once

#ifdef WINDTUNNEL_HAS_VTK
#include <QQuickVTKItem.h>
class vtkRenderWindow;
#else
#include <QQuickItem>
#endif

#include <QString>
#include <QtQml/qqmlregistration.h>

#ifdef WINDTUNNEL_HAS_VTK
class VtkView : public QQuickVTKItem
#else
class VtkView : public QQuickItem
#endif
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QString stlFile READ stlFile WRITE setStlFile NOTIFY stlFileChanged)

public:
    explicit VtkView(QQuickItem *parent = nullptr);
    QString stlFile() const { return m_stlFile; }
    void setStlFile(const QString &path);

#ifdef WINDTUNNEL_HAS_VTK
    static void setGraphicsApi();
    vtkUserData initializeVTK(vtkRenderWindow *renderWindow) override;
#else
    static void setGraphicsApi() {}
#endif

signals:
    void stlFileChanged();

private:
    QString m_stlFile;
};
