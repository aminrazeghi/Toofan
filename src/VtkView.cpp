#include "VtkView.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <QPointer>
#include <QThreadPool>

#ifdef WINDTUNNEL_HAS_VTK
#include <vtkActor.h>
#include <vtkAppendPolyData.h>
#include <vtkCamera.h>
#include <vtkColorTransferFunction.h>
#include <vtkCompositeDataSet.h>
#include <vtkCutter.h>
#include <vtkDataArray.h>
#include <vtkDataObjectTreeIterator.h>
#include <vtkDoubleArray.h>
#include <vtkDataArraySelection.h>
#include <vtkInformation.h>
#include <vtkMultiBlockDataSet.h>
#include <vtkNew.h>
#include <vtkObjectFactory.h>
#include <vtkOpenFOAMReader.h>
#include <vtkPlane.h>
#include <vtkPointData.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkProperty.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkSTLReader.h>
#include <vtkScalarBarActor.h>
#include <vtkTextProperty.h>
#include <vtkUnstructuredGrid.h>
#include <algorithm>

// Everything needed to draw one state of the case. Built on a worker thread, then only read.
struct CasePreview {
    vtkSmartPointer<vtkPolyData> slice; // mid-plane (normal +y) cut through the internal mesh
    vtkSmartPointer<vtkPolyData> model; // model wall patches (empty before snappyHexMesh)
    double focus[6] = {0, -1, 0, -1, 0, -1}; // region around the model to frame
    bool hasFlow = false;               // slice carries a solved U field
    double speedRange[2] = {0, 1};
    double time = 0;
    vtkIdType cells = 0;
};

namespace {
vtkSmartPointer<vtkPolyData> readStl(const QString &path)
{
    if (path.isEmpty() || !QFileInfo::exists(path))
        return nullptr;
    vtkNew<vtkSTLReader> reader;
    reader->SetFileName(QFile::encodeName(path).constData());
    reader->Update();
    if (!reader->GetOutput() || reader->GetOutput()->GetNumberOfPoints() == 0)
        return nullptr;
    auto surface = vtkSmartPointer<vtkPolyData>::New();
    surface->ShallowCopy(reader->GetOutput());
    return surface;
}

// Reads the case mesh and its latest time step. Thread-safe: touches no shared state.
std::shared_ptr<const CasePreview> loadCasePreview(const QString &casePath)
{
    const QDir caseDir(casePath);
    if (!QFileInfo::exists(caseDir.filePath(QStringLiteral("constant/polyMesh/faces"))))
        return nullptr;
    // The reader locates the case through a (possibly empty) .foam file.
    const QString foamFile = caseDir.filePath(QStringLiteral("case.foam"));
    if (QFile touch(foamFile); !touch.exists() && !touch.open(QIODevice::WriteOnly))
        return nullptr;

    vtkNew<vtkOpenFOAMReader> reader;
    reader->SetFileName(QFile::encodeName(foamFile).constData());
    reader->UpdateInformation();
    reader->DisableAllCellArrays();
    reader->DisableAllPointArrays();
    reader->DisableAllLagrangianArrays();
    if (reader->GetCellDataArraySelection()->ArrayExists("U"))
        reader->SetCellArrayStatus("U", 1);
    for (int i = 0; i < reader->GetNumberOfPatchArrays(); ++i) {
        const QString name = QString::fromUtf8(reader->GetPatchArrayName(i));
        const bool wanted = name == QStringLiteral("internalMesh") || name.startsWith(QStringLiteral("patch/model"));
        reader->SetPatchArrayStatus(reader->GetPatchArrayName(i), wanted ? 1 : 0);
    }
    auto preview = std::make_shared<CasePreview>();
    vtkDoubleArray *times = reader->GetTimeValues();
    if (times && times->GetNumberOfTuples() > 0) {
        preview->time = times->GetValue(times->GetNumberOfTuples() - 1);
        reader->UpdateTimeStep(preview->time);
    } else {
        reader->Update();
    }

    vtkUnstructuredGrid *mesh = nullptr;
    vtkNew<vtkAppendPolyData> model;
    vtkNew<vtkDataObjectTreeIterator> it;
    it->SetDataSet(reader->GetOutput());
    it->VisitOnlyLeavesOn();
    for (it->InitTraversal(); !it->IsDoneWithTraversal(); it->GoToNextItem()) {
        const char *name = it->GetCurrentMetaData()->Get(vtkCompositeDataSet::NAME());
        if (name && QByteArray(name) == "internalMesh")
            mesh = vtkUnstructuredGrid::SafeDownCast(it->GetCurrentDataObject());
        else if (auto patch = vtkPolyData::SafeDownCast(it->GetCurrentDataObject()))
            model->AddInputData(patch);
    }
    if (!mesh || mesh->GetNumberOfCells() == 0)
        return nullptr;
    preview->cells = mesh->GetNumberOfCells();
    preview->model = vtkSmartPointer<vtkPolyData>::New();
    if (model->GetNumberOfInputConnections(0) > 0) {
        model->Update();
        preview->model->ShallowCopy(model->GetOutput());
    }

    // Frame and cut through the model; it is in constant/triSurface even before snappyHexMesh.
    double bounds[6];
    if (auto stl = readStl(caseDir.filePath(QStringLiteral("constant/triSurface/model.stl"))))
        stl->GetBounds(bounds);
    else
        mesh->GetBounds(bounds);
    const double center[3] = {0.5 * (bounds[0] + bounds[1]), 0.5 * (bounds[2] + bounds[3]), 0.5 * (bounds[4] + bounds[5])};
    const double length = std::max({bounds[1] - bounds[0], bounds[3] - bounds[2], bounds[5] - bounds[4]});
    const double focus[6] = {bounds[0] - 0.8 * length, bounds[1] + 2.0 * length, bounds[2], bounds[3],
                             bounds[4] - 0.6 * length, bounds[5] + 0.6 * length};
    std::copy(focus, focus + 6, preview->focus);

    vtkNew<vtkPlane> plane;
    plane->SetOrigin(center[0], center[1], center[2]);
    plane->SetNormal(0, 1, 0);
    vtkNew<vtkCutter> cutter;
    cutter->SetCutFunction(plane);
    cutter->SetInputData(mesh);
    cutter->GenerateTrianglesOff(); // keep cut cells as polygons so the mesh edges are the real cell edges
    cutter->Update();
    preview->slice = vtkSmartPointer<vtkPolyData>::New();
    preview->slice->ShallowCopy(cutter->GetOutput());

    if (vtkDataArray *velocity = preview->slice->GetPointData()->GetArray("U"); velocity && preview->time > 0) {
        preview->hasFlow = true;
        velocity->GetRange(preview->speedRange, -1); // -1: vector magnitude
        if (preview->speedRange[1] <= preview->speedRange[0])
            preview->speedRange[1] = preview->speedRange[0] + 1e-6;
    }
    return preview;
}

// Render-thread side of the view: owns all VTK rendering objects.
class PreviewScene : public vtkObject
{
public:
    static PreviewScene *New();
    vtkTypeMacro(PreviewScene, vtkObject);

    vtkNew<vtkRenderer> renderer;
    vtkNew<vtkPolyDataMapper> stlMapper, sliceMapper, modelMapper;
    vtkNew<vtkActor> stlActor, sliceActor, modelActor;
    vtkNew<vtkColorTransferFunction> speedColors;
    vtkNew<vtkScalarBarActor> scalarBar;
    QString stlPath;                             // STL currently in stlMapper
    bool hasStl = false;
    std::shared_ptr<const CasePreview> preview;  // preview currently shown
};
vtkStandardNewMacro(PreviewScene);

struct SceneState {
    QString stlPath;
    std::shared_ptr<const CasePreview> preview;
};

void setupScene(PreviewScene *scene)
{
    vtkRenderer *renderer = scene->renderer;
    renderer->SetBackground(0.055, 0.075, 0.10);
    renderer->SetBackground2(0.10, 0.15, 0.19);
    renderer->GradientBackgroundOn();

    auto styleModel = [](vtkActor *actor) {
        actor->GetProperty()->SetColor(0.32, 0.82, 0.72);
        actor->GetProperty()->SetMetallic(0.18);
        actor->GetProperty()->SetRoughness(0.35);
    };
    scene->stlActor->SetMapper(scene->stlMapper);
    styleModel(scene->stlActor);
    scene->modelActor->SetMapper(scene->modelMapper);
    scene->modelMapper->ScalarVisibilityOff();
    styleModel(scene->modelActor);

    scene->sliceActor->SetMapper(scene->sliceMapper);
    scene->sliceActor->GetProperty()->SetEdgeColor(0.36, 0.62, 0.57);
    scene->sliceActor->GetProperty()->SetLineWidth(1.0);

    scene->speedColors->SetColorSpaceToRGB();
    scene->speedColors->SetVectorModeToMagnitude();
    scene->sliceMapper->SetLookupTable(scene->speedColors);
    scene->sliceMapper->SetScalarModeToUsePointFieldData();
    scene->sliceMapper->SelectColorArray("U");
    scene->sliceMapper->UseLookupTableScalarRangeOn();

    scene->scalarBar->SetLookupTable(scene->speedColors);
    scene->scalarBar->SetTitle("|U| (m/s)");
    scene->scalarBar->SetNumberOfLabels(5);
    scene->scalarBar->SetMaximumWidthInPixels(64);
    scene->scalarBar->SetMaximumHeightInPixels(300);
    scene->scalarBar->SetPosition(0.89, 0.12);
    scene->scalarBar->SetPosition2(0.1, 0.6);
    scene->scalarBar->SetVerticalTitleSeparation(8);
    scene->scalarBar->UnconstrainedFontSizeOn();
    for (vtkTextProperty *text : {scene->scalarBar->GetTitleTextProperty(), scene->scalarBar->GetLabelTextProperty()}) {
        text->SetColor(0.85, 0.89, 0.92);
        text->ShadowOff();
        text->ItalicOff();
        text->BoldOff();
        text->SetFontSize(12);
    }

    for (vtkActor *actor : {scene->stlActor.Get(), scene->sliceActor.Get(), scene->modelActor.Get()}) {
        actor->VisibilityOff();
        renderer->AddActor(actor);
    }
    scene->scalarBar->VisibilityOff();
    renderer->AddViewProp(scene->scalarBar);
}

// Side view along +y with the flow (+x) running left to right.
void frameCamera(vtkRenderer *renderer, const double bounds[6])
{
    if (bounds[0] > bounds[1])
        return;
    vtkCamera *camera = renderer->GetActiveCamera();
    camera->SetFocalPoint(0.5 * (bounds[0] + bounds[1]), 0.5 * (bounds[2] + bounds[3]), 0.5 * (bounds[4] + bounds[5]));
    camera->SetPosition(0.5 * (bounds[0] + bounds[1]), bounds[2] - 1.0, 0.5 * (bounds[4] + bounds[5]));
    camera->SetViewUp(0, 0, 1);
    renderer->ResetCamera(bounds);
    camera->Azimuth(-12);
    camera->Elevation(10);
    camera->Zoom(1.5); // ResetCamera fits a bounding sphere, which leaves a wide margin
    renderer->ResetCameraClippingRange();
}

void syncScene(PreviewScene *scene, const SceneState &state)
{
    bool reframe = false;
    if (scene->stlPath != state.stlPath) {
        scene->stlPath = state.stlPath;
        auto surface = readStl(state.stlPath);
        scene->hasStl = surface != nullptr;
        scene->stlMapper->SetInputData(surface ? surface.Get() : vtkNew<vtkPolyData>().Get());
        reframe = true;
    }
    const CasePreview *preview = state.preview.get();
    if ((preview != nullptr) != (scene->preview != nullptr))
        reframe = true; // switching between STL and case preview; keep the camera otherwise
    if (state.preview != scene->preview) {
        scene->preview = state.preview;
        if (preview) {
            scene->sliceMapper->SetInputData(preview->slice);
            scene->modelMapper->SetInputData(preview->model);
            vtkProperty *slice = scene->sliceActor->GetProperty();
            if (preview->hasFlow) {
                // Viridis: perceptually uniform, so the free stream does not saturate the slice.
                static constexpr double viridis[5][3] = {{0.267, 0.005, 0.329}, {0.229, 0.322, 0.546}, {0.128, 0.567, 0.551},
                                                         {0.369, 0.789, 0.383}, {0.993, 0.906, 0.144}};
                scene->speedColors->RemoveAllPoints();
                const double low = preview->speedRange[0], high = preview->speedRange[1];
                for (int i = 0; i < 5; ++i)
                    scene->speedColors->AddRGBPoint(low + (high - low) * i / 4.0, viridis[i][0], viridis[i][1], viridis[i][2]);
                scene->sliceMapper->ScalarVisibilityOn();
                slice->EdgeVisibilityOff();
            } else {
                scene->sliceMapper->ScalarVisibilityOff();
                slice->SetColor(0.13, 0.17, 0.22);
                slice->EdgeVisibilityOn();
            }
        }
    }
    const bool hasModelPatch = preview && preview->model && preview->model->GetNumberOfCells() > 0;
    scene->stlActor->SetVisibility(scene->hasStl && !hasModelPatch);
    scene->modelActor->SetVisibility(hasModelPatch);
    scene->sliceActor->SetVisibility(preview != nullptr);
    scene->scalarBar->SetVisibility(preview && preview->hasFlow);

    if (reframe) {
        if (preview) {
            frameCamera(scene->renderer, preview->focus);
        } else if (scene->hasStl) {
            double bounds[6];
            scene->stlMapper->GetInput()->GetBounds(bounds);
            frameCamera(scene->renderer, bounds);
        }
    }
}
}

void VtkView::setGraphicsApi()
{
    QQuickVTKItem::setGraphicsApi();
}

QQuickVTKItem::vtkUserData VtkView::initializeVTK(vtkRenderWindow *renderWindow)
{
    auto scene = vtkSmartPointer<PreviewScene>::New();
    setupScene(scene);
    renderWindow->AddRenderer(scene->renderer);
    syncScene(scene, {m_stlFile, m_preview});
    return scene;
}
#else
struct CasePreview {};
#endif

VtkView::VtkView(QQuickItem *parent)
#ifdef WINDTUNNEL_HAS_VTK
    : QQuickVTKItem(parent)
#else
    : QQuickItem(parent)
#endif
{
}

VtkView::~VtkView() = default;

void VtkView::setStlFile(const QString &path)
{
    if (m_stlFile == path)
        return;
    m_stlFile = path;
    emit stlFileChanged();
    updateScene();
}

void VtkView::setCasePath(const QString &path)
{
    if (m_casePath == path)
        return;
    m_casePath = path;
    emit casePathChanged();
    ++m_loadGeneration;
    m_preview.reset();
    setPreviewInfo({});
    updateScene();
    requestCasePreview();
}

void VtkView::setPreviewRevision(int revision)
{
    if (m_previewRevision == revision)
        return;
    m_previewRevision = revision;
    emit previewRevisionChanged();
    if (revision <= 0) {
        ++m_loadGeneration; // drop any load still in flight
        m_reloadPending = false;
        m_preview.reset();
        setPreviewInfo({});
        updateScene();
        return;
    }
    requestCasePreview();
}

void VtkView::requestCasePreview()
{
#ifdef WINDTUNNEL_HAS_VTK
    if (m_casePath.isEmpty() || m_previewRevision <= 0)
        return;
    if (m_loading) { m_reloadPending = true; return; }
    m_loading = true;
    // Reading a large mesh takes a while; do it off the GUI and render threads.
    QThreadPool::globalInstance()->start([guard = QPointer<VtkView>(this), casePath = m_casePath, generation = m_loadGeneration] {
        auto preview = loadCasePreview(casePath);
        QMetaObject::invokeMethod(QCoreApplication::instance(), [guard, generation, preview] {
            if (guard) guard->applyCasePreview(generation, preview);
        }, Qt::QueuedConnection);
    });
#endif
}

void VtkView::applyCasePreview(int generation, std::shared_ptr<const CasePreview> preview)
{
#ifdef WINDTUNNEL_HAS_VTK
    m_loading = false;
    if (generation == m_loadGeneration && preview) { // a failed read keeps the previous picture
        m_preview = preview;
        const QLocale locale;
        setPreviewInfo(preview->hasFlow
                           ? QStringLiteral("t = %1 s  ·  velocity on mid-plane").arg(preview->time, 0, 'g', 4)
                           : QStringLiteral("Mesh  ·  %1 cells").arg(locale.toString(qlonglong(preview->cells))));
        updateScene();
    }
    if (m_reloadPending) {
        m_reloadPending = false;
        requestCasePreview();
    }
#else
    Q_UNUSED(generation) Q_UNUSED(preview)
#endif
}

void VtkView::updateScene()
{
#ifdef WINDTUNNEL_HAS_VTK
    dispatch_async([state = SceneState{m_stlFile, m_preview}](vtkRenderWindow *, vtkUserData userData) {
        if (auto scene = PreviewScene::SafeDownCast(userData))
            syncScene(scene, state);
    });
    scheduleRender();
#endif
}

void VtkView::setPreviewInfo(const QString &info)
{
    if (m_previewInfo == info)
        return;
    m_previewInfo = info;
    emit previewInfoChanged();
}
