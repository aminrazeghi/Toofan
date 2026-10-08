#include "SimulationController.h"
#include "VtkView.h"
#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QSurfaceFormat>
#include <QVariantMap>
#ifdef TOOFAN_HAS_VTK
#include <vtkVersion.h>
#endif

int main(int argc, char *argv[])
{
    VtkView::setGraphicsApi();
    // The frameless window is transparent outside its rounded corners, which needs an alpha channel.
    QSurfaceFormat format = QSurfaceFormat::defaultFormat();
    format.setAlphaBufferSize(8);
    QSurfaceFormat::setDefaultFormat(format);
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Toofan"));
    app.setOrganizationName(QStringLiteral("Toofan")); // settings location
    app.setWindowIcon(QIcon(QStringLiteral(":/assets/toofan-icon.svg")));
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    SimulationController controller;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("simulation"), &controller);
    // Library versions for the About window.
    engine.rootContext()->setContextProperty(QStringLiteral("appInfo"), QVariantMap{
        {QStringLiteral("qtVersion"), QString::fromLatin1(qVersion())},
#ifdef TOOFAN_HAS_VTK
        {QStringLiteral("vtkVersion"), QString::fromLatin1(vtkVersion::GetVTKVersion())},
#endif
    });
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(EXIT_FAILURE); }, Qt::QueuedConnection);
    engine.loadFromModule(QStringLiteral("Toofan"), QStringLiteral("Main"));
    return app.exec();
}
