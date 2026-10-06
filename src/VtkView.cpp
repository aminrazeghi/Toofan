#include "VtkView.h"

#ifdef WINDTUNNEL_HAS_VTK
#include <vtkActor.h>
#include <vtkCamera.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkProperty.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkSTLReader.h>

namespace {
void loadModel(vtkRenderer *renderer, const QString &path)
{
    renderer->RemoveAllViewProps();
    if (path.isEmpty())
        return;
    auto reader = vtkSmartPointer<vtkSTLReader>::New();
    reader->SetFileName(path.toLocal8Bit().constData());
    reader->Update();
    if (!reader->GetOutput() || reader->GetOutput()->GetNumberOfPoints() == 0)
        return;
    auto mapper = vtkSmartPointer<vtkPolyDataMapper>::New();
    mapper->SetInputConnection(reader->GetOutputPort());
    auto actor = vtkSmartPointer<vtkActor>::New();
    actor->SetMapper(mapper);
    actor->GetProperty()->SetColor(0.32, 0.82, 0.72);
    actor->GetProperty()->SetMetallic(0.18);
    actor->GetProperty()->SetRoughness(0.35);
    renderer->AddActor(actor);
    renderer->ResetCamera();
    renderer->GetActiveCamera()->Azimuth(25);
    renderer->GetActiveCamera()->Elevation(18);
    renderer->ResetCameraClippingRange();
}
}

void VtkView::setGraphicsApi()
{
    QQuickVTKItem::setGraphicsApi();
}

QQuickVTKItem::vtkUserData VtkView::initializeVTK(vtkRenderWindow *renderWindow)
{
    auto renderer = vtkSmartPointer<vtkRenderer>::New();
    renderer->SetBackground(0.055, 0.075, 0.10);
    renderer->SetBackground2(0.10, 0.15, 0.19);
    renderer->GradientBackgroundOn();

    loadModel(renderer, m_stlFile);
    renderWindow->AddRenderer(renderer);
    return renderer;
}
#else
void VtkView::setGraphicsApi() {}
#endif

VtkView::VtkView(QQuickItem *parent)
#ifdef WINDTUNNEL_HAS_VTK
    : QQuickVTKItem(parent)
#else
    : QQuickItem(parent)
#endif
{
}

void VtkView::setStlFile(const QString &path)
{
    if (m_stlFile == path)
        return;
    m_stlFile = path;
    emit stlFileChanged();
#ifdef WINDTUNNEL_HAS_VTK
    const QString modelPath = m_stlFile;
    dispatch_async([modelPath](vtkRenderWindow *, vtkUserData userData) {
        auto renderer = vtkRenderer::SafeDownCast(userData);
        if (renderer)
            loadModel(renderer, modelPath);
    });
    scheduleRender();
#endif
}
