#include "SimulationController.h"
#include "VtkView.h"
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>

int main(int argc, char *argv[])
{
    VtkView::setGraphicsApi();
    QGuiApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("Digital Wind Tunnel"));
    QQuickStyle::setStyle(QStringLiteral("Basic"));
    SimulationController controller;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty(QStringLiteral("simulation"), &controller);
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app,
                     [] { QCoreApplication::exit(EXIT_FAILURE); }, Qt::QueuedConnection);
    engine.loadFromModule(QStringLiteral("WindTunnel"), QStringLiteral("Main"));
    return app.exec();
}
