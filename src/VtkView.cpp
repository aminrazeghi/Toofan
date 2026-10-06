#include "VtkView.h"
#include "OpenFoamCase.h"

#include <QColor>
#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QLocale>
#include <QPointer>
#include <QThreadPool>

namespace {
// Contour palettes, low to high. Shared by the VTK lookup table and the QML swatches.
struct ColorMap { const char *value, *label; double stops[5][3]; };
constexpr ColorMap kColorMaps[] = {
    {"viridis", "Viridis", {{0.267, 0.005, 0.329}, {0.229, 0.322, 0.546}, {0.128, 0.567, 0.551}, {0.369, 0.789, 0.383}, {0.993, 0.906, 0.144}}},
    {"plasma", "Plasma", {{0.050, 0.030, 0.528}, {0.494, 0.012, 0.658}, {0.798, 0.280, 0.470}, {0.973, 0.585, 0.252}, {0.940, 0.975, 0.131}}},
    {"coolwarm", "Cool to warm", {{0.230, 0.299, 0.754}, {0.552, 0.690, 0.996}, {0.865, 0.865, 0.865}, {0.958, 0.603, 0.482}, {0.706, 0.016, 0.150}}},
    {"rainbow", "Rainbow", {{0.0, 0.0, 0.85}, {0.0, 0.75, 1.0}, {0.2, 0.9, 0.2}, {1.0, 0.8, 0.0}, {0.85, 0.05, 0.05}}},
    {"grayscale", "Grayscale", {{0.08, 0.08, 0.08}, {0.30, 0.30, 0.30}, {0.52, 0.52, 0.52}, {0.75, 0.75, 0.75}, {0.97, 0.97, 0.97}}},
};

const ColorMap &colorMapNamed(const QString &name)
{
    for (const ColorMap &map : kColorMaps)
        if (name == QLatin1String(map.value)) return map;
    return kColorMaps[0];
}
}

#ifdef WINDTUNNEL_HAS_VTK
#include <vtkActor.h>
#include <vtkArrowSource.h>
#include <vtkBillboardTextActor3D.h>
#include <vtkAppendPolyData.h>
#include <vtkCamera.h>
#include <vtkColorTransferFunction.h>
#include <vtkCompositeDataSet.h>
#include <vtkCutter.h>
#include <vtkDataArray.h>
#include <vtkDataArraySelection.h>
#include <vtkDataObjectTreeIterator.h>
#include <vtkDoubleArray.h>
#include <vtkInformation.h>
#include <vtkMultiBlockDataSet.h>
#include <vtkNew.h>
#include <vtkObjectFactory.h>
#include <vtkOutlineSource.h>
#include <vtkOpenFOAMReader.h>
#include <vtkPlane.h>
#include <vtkPlaneSource.h>
#include <vtkPointData.h>
#include <vtkPolyData.h>
#include <vtkPolyDataMapper.h>
#include <vtkProperty.h>
#include <vtkRenderWindow.h>
#include <vtkRenderer.h>
#include <vtkSTLReader.h>
#include <vtkScalarBarActor.h>
#include <vtkStreamTracer.h>
#include <vtkTextProperty.h>
#include <vtkTransform.h>
#include <vtkTransformPolyDataFilter.h>
#include <vtkTubeFilter.h>
#include <vtkUnstructuredGrid.h>
#include <algorithm>
#include <limits>

// One time step of the case as read from disk. Only worker jobs touch it (one at a time): VTK
// objects cache state even on reads, so the render thread only ever sees CasePreview copies.
struct CaseData {
    vtkSmartPointer<vtkUnstructuredGrid> mesh;  // internal mesh with point fields
    vtkSmartPointer<vtkPolyData> model;         // model wall patches (empty before snappyHexMesh)
    vtkSmartPointer<vtkPolyData> tunnel;        // inlet, outlet and tunnel wall patches
    double modelBounds[6] = {0, -1, 0, -1, 0, -1};
    double domainBounds[6] = {0, -1, 0, -1, 0, -1};
    double time = 0;
    bool hasFlow = false; // a solved time step (t > 0) with U
    bool compressible = false;
    vtkIdType cells = 0;
};

// Everything needed to draw one mode/field of a CaseData. Built on a worker thread, then handed to
// the render thread; it owns its VTK objects (no sharing with CaseData).
struct CasePreview {
    QString mode, field;                   // as requested
    vtkSmartPointer<vtkPolyData> geometry; // slice, tunnel walls or streamlines
    vtkSmartPointer<vtkPolyData> model;    // model wall patches
    bool lines = false;                    // geometry is streamline tubes
    bool cullFrontFaces = false;           // cut away the walls facing the camera
    bool colored = false;                  // geometry colored by field
    bool colorModel = false;               // model surface colored by field too
    double range[2] = {0, 1};
    QString colorTitle;
    double focus[6] = {0, -1, 0, -1, 0, -1}; // region to frame
    QString info;
};

namespace {
struct FieldInfo { const char *name, *label, *title; };
// Point-data array, label for the info line and scalar bar title.
constexpr FieldInfo kFields[] = {
    {"U", "velocity", "|U| (m/s)"},
    {"p", "pressure", "p"},
    {"k", "turbulent kinetic energy", "k (m²/s²)"},
    {"omega", "specific dissipation rate", "omega (1/s)"},
    {"epsilon", "turbulent dissipation rate", "epsilon (m²/s³)"},
    {"nuTilda", "Spalart-Allmaras viscosity", "nuTilda (m²/s)"},
    {"T", "temperature", "T (K)"},
    {"rho", "density", "rho (kg/m³)"},
    {"Ma", "Mach number", "Ma"},
};

const FieldInfo *fieldInfo(const QString &name)
{
    for (const FieldInfo &field : kFields)
        if (name == QLatin1String(field.name)) return &field;
    return nullptr;
}

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

vtkSmartPointer<vtkPolyData> appendOutput(vtkAppendPolyData *append)
{
    auto output = vtkSmartPointer<vtkPolyData>::New();
    if (append->GetNumberOfInputConnections(0) > 0) {
        append->Update();
        output->ShallowCopy(append->GetOutput());
    }
    return output;
}

// Reads the case mesh and its latest time step. Thread-safe: touches no shared state.
std::shared_ptr<const CaseData> loadCaseData(const QString &casePath)
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
    for (const FieldInfo &field : kFields)
        if (reader->GetCellDataArraySelection()->ArrayExists(field.name))
            reader->SetCellArrayStatus(field.name, 1);
    for (int i = 0; i < reader->GetNumberOfPatchArrays(); ++i) {
        const QString name = QString::fromUtf8(reader->GetPatchArrayName(i));
        const bool wanted = name == QStringLiteral("internalMesh") || name.startsWith(QStringLiteral("patch/"));
        reader->SetPatchArrayStatus(reader->GetPatchArrayName(i), wanted ? 1 : 0);
    }
    auto data = std::make_shared<CaseData>();
    vtkDoubleArray *times = reader->GetTimeValues();
    if (times && times->GetNumberOfTuples() > 0) {
        data->time = times->GetValue(times->GetNumberOfTuples() - 1);
        reader->UpdateTimeStep(data->time);
    } else {
        reader->Update();
    }

    vtkNew<vtkAppendPolyData> model, tunnel;
    vtkNew<vtkDataObjectTreeIterator> it;
    it->SetDataSet(reader->GetOutput());
    it->VisitOnlyLeavesOn();
    for (it->InitTraversal(); !it->IsDoneWithTraversal(); it->GoToNextItem()) {
        const QString name = QString::fromUtf8(it->GetCurrentMetaData()->Get(vtkCompositeDataSet::NAME()));
        if (name == QStringLiteral("internalMesh"))
            data->mesh = vtkUnstructuredGrid::SafeDownCast(it->GetCurrentDataObject());
        else if (auto patch = vtkPolyData::SafeDownCast(it->GetCurrentDataObject()))
            (name.startsWith(QStringLiteral("model")) ? model : tunnel)->AddInputData(patch);
    }
    if (!data->mesh || data->mesh->GetNumberOfCells() == 0)
        return nullptr;
    data->cells = data->mesh->GetNumberOfCells();
    data->model = appendOutput(model);
    data->tunnel = appendOutput(tunnel);
    data->mesh->GetBounds(data->domainBounds);
    // The model is in constant/triSurface even before snappyHexMesh.
    if (auto stl = readStl(caseDir.filePath(QStringLiteral("constant/triSurface/model.stl"))))
        stl->GetBounds(data->modelBounds);
    else
        std::copy(data->domainBounds, data->domainBounds + 6, data->modelBounds);
    vtkPointData *fields = data->mesh->GetPointData();
    data->hasFlow = data->time > 0 && fields->GetArray("U");
    data->compressible = fields->GetArray("T") != nullptr;
    return data;
}

double modelLength(const double b[6]) { return std::max({b[1] - b[0], b[3] - b[2], b[5] - b[4]}); }

vtkSmartPointer<vtkPolyData> midPlaneSlice(const CaseData &data)
{
    const double *b = data.modelBounds;
    vtkNew<vtkPlane> plane;
    plane->SetOrigin(0.5 * (b[0] + b[1]), 0.5 * (b[2] + b[3]), 0.5 * (b[4] + b[5]));
    plane->SetNormal(0, 1, 0);
    vtkNew<vtkCutter> cutter;
    cutter->SetCutFunction(plane);
    cutter->SetInputData(data.mesh);
    cutter->GenerateTrianglesOff(); // keep cut cells as polygons so the mesh edges are the real cell edges
    cutter->Update();
    auto slice = vtkSmartPointer<vtkPolyData>::New();
    slice->ShallowCopy(cutter->GetOutput());
    return slice;
}

vtkSmartPointer<vtkPolyData> streamlines(const CaseData &data)
{
    // A rake of seeds just upstream of the model, covering its frontal area.
    const double *b = data.modelBounds;
    const double length = modelLength(b);
    const double x = b[0] - 0.25 * length, margin = 0.25 * length;
    vtkNew<vtkPlaneSource> seeds;
    seeds->SetOrigin(x, b[2] - margin, b[4] - margin);
    seeds->SetPoint1(x, b[3] + margin, b[4] - margin);
    seeds->SetPoint2(x, b[2] - margin, b[5] + margin);
    seeds->SetXResolution(6);  // across the span: few, so the side view does not stack them into bands
    seeds->SetYResolution(11); // over the height

    vtkNew<vtkStreamTracer> tracer;
    tracer->SetInputData(data.mesh);
    tracer->SetSourceConnection(seeds->GetOutputPort());
    tracer->SetInputArrayToProcess(0, 0, 0, vtkDataObject::FIELD_ASSOCIATION_POINTS, "U");
    tracer->SetInterpolatorTypeToCellLocator(); // robust on snappyHexMesh polyhedra
    tracer->SetIntegratorTypeToRungeKutta45();
    tracer->SetIntegrationDirectionToForward();
    tracer->SetMaximumPropagation(data.domainBounds[1] - data.domainBounds[0]);
    tracer->SetMaximumNumberOfSteps(4000);
    // Lit tubes read as 3D curves; plain lines blur together from most viewpoints.
    vtkNew<vtkTubeFilter> tubes;
    tubes->SetInputConnection(tracer->GetOutputPort());
    tubes->SetRadius(0.005 * length);
    tubes->SetNumberOfSides(8);
    tubes->CappingOn();
    tubes->Update();
    auto lines = vtkSmartPointer<vtkPolyData>::New();
    lines->ShallowCopy(tubes->GetOutput());
    return lines;
}

bool includeRange(vtkPolyData *geometry, const char *name, double range[2])
{
    vtkDataArray *array = geometry ? geometry->GetPointData()->GetArray(name) : nullptr;
    if (!array || array->GetNumberOfTuples() == 0)
        return false;
    double r[2];
    array->GetRange(r, array->GetNumberOfComponents() > 1 ? -1 : 0); // -1: vector magnitude
    range[0] = std::min(range[0], r[0]);
    range[1] = std::max(range[1], r[1]);
    return true;
}

vtkSmartPointer<vtkPolyData> copyOf(vtkPolyData *source)
{
    auto copy = vtkSmartPointer<vtkPolyData>::New();
    copy->DeepCopy(source);
    return copy;
}

// Builds the drawable geometry for one mode and field. Must run in a worker job (see CaseData).
std::shared_ptr<const CasePreview> buildPreview(std::shared_ptr<const CaseData> data, const QString &mode, const QString &field)
{
    auto preview = std::make_shared<CasePreview>();
    preview->model = copyOf(data->model);
    preview->mode = mode;
    preview->field = field;
    const QLocale locale;
    const QString meshInfo = QStringLiteral("Mesh  ·  %1 cells").arg(locale.toString(qlonglong(data->cells)));

    const double *mb = data->modelBounds;
    const double length = modelLength(mb);
    const double nearModel[6] = {mb[0] - 0.8 * length, mb[1] + 2.0 * length, mb[2], mb[3], mb[4] - 0.6 * length, mb[5] + 0.6 * length};
    std::copy(nearModel, nearModel + 6, preview->focus);

    QString where;
    if (mode == QStringLiteral("domain")) {
        preview->geometry = copyOf(data->tunnel);
        preview->cullFrontFaces = true;
        std::copy(data->domainBounds, data->domainBounds + 6, preview->focus);
        where = QStringLiteral("on tunnel walls");
    } else if (mode == QStringLiteral("streamlines") && data->hasFlow) {
        preview->geometry = streamlines(*data);
        preview->lines = true;
        where = QStringLiteral("along streamlines");
    } else {
        preview->geometry = midPlaneSlice(*data);
        where = QStringLiteral("on mid-plane");
    }

    if (!data->hasFlow) {
        preview->info = mode == QStringLiteral("streamlines") ? meshInfo + QStringLiteral("  ·  streamlines follow the first solved time step")
                                                              : meshInfo;
        return preview;
    }

    const FieldInfo *info = fieldInfo(field);
    double range[2] = {std::numeric_limits<double>::max(), std::numeric_limits<double>::lowest()};
    preview->colored = info && includeRange(preview->geometry, info->name, range);
    // Pressure on the body is worth seeing; for other fields the model stays a plain shape reference.
    preview->colorModel = preview->colored && field == QStringLiteral("p") && includeRange(preview->model, info->name, range);
    const QString time = QStringLiteral("t = %1 s").arg(data->time, 0, 'g', 4);
    if (!preview->colored) {
        preview->info = QStringLiteral("%1  ·  %2 not available").arg(time, field);
        return preview;
    }
    if (range[1] <= range[0])
        range[1] = range[0] + 1e-9;
    std::copy(range, range + 2, preview->range);
    preview->colorTitle = QString::fromUtf8(info->title);
    if (field == QStringLiteral("p"))
        preview->colorTitle = data->compressible ? QStringLiteral("p (Pa)") : QStringLiteral("p/rho (m²/s²)");
    preview->info = QStringLiteral("%1  ·  %2 %3").arg(time, QString::fromUtf8(info->label), where);
    return preview;
}

// Render-thread side of the view: owns all VTK rendering objects.
class PreviewScene : public vtkObject
{
public:
    static PreviewScene *New();
    vtkTypeMacro(PreviewScene, vtkObject);

    vtkNew<vtkRenderer> renderer;
    vtkNew<vtkPolyDataMapper> stlMapper, geometryMapper, modelMapper;
    vtkNew<vtkActor> stlActor, geometryActor, modelActor;
    vtkNew<vtkColorTransferFunction> colors;
    vtkNew<vtkScalarBarActor> scalarBar;
    // Tunnel preview around the imported STL, until the case has a mesh.
    vtkNew<vtkPolyDataMapper> outlineMapper, inletMapper, arrowMapper;
    vtkNew<vtkActor> outlineActor, inletActor, arrowActor;
    vtkNew<vtkBillboardTextActor3D> inletLabel;
    double tunnelView[6] = {0, -1, 0, -1, 0, -1}; // tunnel plus inlet arrow, for framing
    QString stlPath;                             // STL currently in stlMapper
    bool hasStl = false;
    std::shared_ptr<const CasePreview> preview;  // preview currently shown
    QString colorMap;                            // palette in `colors`
    int theme = -1;                              // 1 dark, 0 light, -1 not applied yet
};
vtkStandardNewMacro(PreviewScene);

struct SceneState {
    QString stlPath;
    std::shared_ptr<const CasePreview> preview;
    QString colorMap;
    bool darkTheme = true;
};

void styleModel(vtkActor *actor)
{
    actor->GetProperty()->SetColor(0.32, 0.82, 0.72);
    actor->GetProperty()->SetMetallic(0.18);
    actor->GetProperty()->SetRoughness(0.35);
}

void setupScene(PreviewScene *scene)
{
    vtkRenderer *renderer = scene->renderer;
    renderer->SetBackground(0.055, 0.075, 0.10);
    renderer->SetBackground2(0.10, 0.15, 0.19);
    renderer->GradientBackgroundOn();

    scene->stlActor->SetMapper(scene->stlMapper);
    styleModel(scene->stlActor);
    scene->modelActor->SetMapper(scene->modelMapper);
    styleModel(scene->modelActor);
    scene->geometryActor->SetMapper(scene->geometryMapper);
    scene->geometryActor->GetProperty()->SetEdgeColor(0.36, 0.62, 0.57);

    scene->colors->SetColorSpaceToRGB();
    scene->colors->SetVectorModeToMagnitude();
    for (vtkPolyDataMapper *mapper : {scene->geometryMapper.Get(), scene->modelMapper.Get()}) {
        mapper->SetLookupTable(scene->colors);
        mapper->SetScalarModeToUsePointFieldData();
        mapper->UseLookupTableScalarRangeOn();
    }

    scene->scalarBar->SetLookupTable(scene->colors);
    scene->scalarBar->SetNumberOfLabels(5);
    scene->scalarBar->SetLabelFormat("%.3g");
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

    scene->outlineActor->SetMapper(scene->outlineMapper);
    scene->outlineActor->GetProperty()->SetColor(0.62, 0.71, 0.78);
    scene->outlineActor->GetProperty()->SetLineWidth(1.5);
    scene->outlineActor->GetProperty()->LightingOff();
    scene->inletActor->SetMapper(scene->inletMapper);
    scene->inletActor->GetProperty()->SetColor(0.35, 0.84, 0.74);
    scene->inletActor->GetProperty()->SetOpacity(0.18);
    scene->inletActor->GetProperty()->LightingOff();
    scene->arrowActor->SetMapper(scene->arrowMapper);
    scene->arrowActor->GetProperty()->SetColor(0.35, 0.84, 0.74);
    scene->inletLabel->SetInput("INLET");
    vtkTextProperty *label = scene->inletLabel->GetTextProperty();
    label->SetColor(0.35, 0.84, 0.74);
    label->SetFontSize(14);
    label->BoldOn();
    label->ShadowOff();
    label->SetJustificationToCentered();
    label->SetVerticalJustificationToBottom();

    for (vtkActor *actor : {scene->stlActor.Get(), scene->geometryActor.Get(), scene->modelActor.Get(),
                            scene->outlineActor.Get(), scene->inletActor.Get(), scene->arrowActor.Get()}) {
        actor->VisibilityOff();
        renderer->AddActor(actor);
    }
    scene->inletLabel->VisibilityOff();
    renderer->AddViewProp(scene->inletLabel);
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
    camera->SetViewAngle(30); // Zoom() below narrows it; start from the default on every reframe
    renderer->ResetCamera(bounds);
    camera->Azimuth(-12);
    camera->Elevation(10);
    camera->Zoom(1.5); // ResetCamera fits a bounding sphere, which leaves a wide margin
    renderer->ResetCameraClippingRange();
}

// Box of the computational domain (as blockMesh will build it), its inlet face and an arrow
// showing the flow entering the tunnel.
void buildTunnelPreview(PreviewScene *scene, vtkPolyData *model)
{
    double modelBounds[6];
    model->GetBounds(modelBounds);
    std::array<double, 6> m;
    std::copy(modelBounds, modelBounds + 6, m.begin());
    const std::array<double, 6> t = OpenFoamCase::tunnelBounds(m);

    vtkNew<vtkOutlineSource> outline;
    outline->SetBounds(t.data());
    outline->Update();
    scene->outlineMapper->SetInputData(outline->GetOutput());

    vtkNew<vtkPlaneSource> inlet;
    inlet->SetOrigin(t[0], t[2], t[4]);
    inlet->SetPoint1(t[0], t[3], t[4]);
    inlet->SetPoint2(t[0], t[2], t[5]);
    inlet->Update();
    scene->inletMapper->SetInputData(inlet->GetOutput());

    // Arrow ending just short of the inlet face, centred on it, pointing +x into the domain.
    const double arrowLength = 0.35 * std::min(t[3] - t[2], t[5] - t[4]);
    const double yc = 0.5 * (t[2] + t[3]), zc = 0.5 * (t[4] + t[5]);
    vtkNew<vtkArrowSource> arrow;
    arrow->SetTipLength(0.3);
    arrow->SetTipRadius(0.12);
    arrow->SetShaftRadius(0.045);
    arrow->SetTipResolution(24);
    arrow->SetShaftResolution(24);
    vtkNew<vtkTransform> place;
    place->Translate(t[0] - 1.05 * arrowLength, yc, zc);
    place->Scale(arrowLength, arrowLength, arrowLength);
    vtkNew<vtkTransformPolyDataFilter> placed;
    placed->SetInputConnection(arrow->GetOutputPort());
    placed->SetTransform(place);
    placed->Update();
    scene->arrowMapper->SetInputData(placed->GetOutput());
    scene->inletLabel->SetPosition(t[0] - 0.55 * arrowLength, yc, zc + 0.2 * arrowLength);

    const double view[6] = {t[0] - 1.1 * arrowLength, t[1], t[2], t[3], t[4], t[5]};
    std::copy(view, view + 6, scene->tunnelView);
}

void applyPreview(PreviewScene *scene, const CasePreview &preview)
{
    scene->geometryMapper->SetInputData(preview.geometry);
    scene->modelMapper->SetInputData(preview.model);

    if (preview.colored) {
        const QByteArray field = preview.field.toUtf8();
        scene->geometryMapper->SelectColorArray(field.constData());
        scene->modelMapper->SelectColorArray(field.constData());
        scene->scalarBar->SetTitle(preview.colorTitle.toUtf8().constData());
    }
    scene->geometryMapper->SetScalarVisibility(preview.colored);
    scene->modelMapper->SetScalarVisibility(preview.colorModel);

    vtkProperty *geometry = scene->geometryActor->GetProperty();
    geometry->SetEdgeVisibility(!preview.colored && !preview.lines); // show the mesh until there is a field
    geometry->SetFrontfaceCulling(preview.cullFrontFaces);
}

void applyColorMap(PreviewScene *scene)
{
    if (!scene->preview || !scene->preview->colored)
        return;
    const ColorMap &map = colorMapNamed(scene->colorMap);
    const double low = scene->preview->range[0], high = scene->preview->range[1];
    scene->colors->RemoveAllPoints();
    for (int i = 0; i < 5; ++i)
        scene->colors->AddRGBPoint(low + (high - low) * i / 4.0, map.stops[i][0], map.stops[i][1], map.stops[i][2]);
}

void applyTheme(PreviewScene *scene, bool dark)
{
    if (dark) {
        scene->renderer->SetBackground(0.055, 0.075, 0.10);
        scene->renderer->SetBackground2(0.10, 0.15, 0.19);
    } else {
        scene->renderer->SetBackground(0.80, 0.85, 0.89);
        scene->renderer->SetBackground2(0.95, 0.96, 0.97);
    }
    const double text = dark ? 0.87 : 0.16;
    for (vtkTextProperty *label : {scene->scalarBar->GetTitleTextProperty(), scene->scalarBar->GetLabelTextProperty()})
        label->SetColor(text, text + 0.02, text + 0.05);
    scene->outlineActor->GetProperty()->SetColor(dark ? 0.62 : 0.30, dark ? 0.71 : 0.38, dark ? 0.78 : 0.46);
    // Mesh views: dark cells with teal edges, or light cells with darker teal edges.
    scene->geometryActor->GetProperty()->SetColor(dark ? 0.13 : 0.88, dark ? 0.17 : 0.91, dark ? 0.22 : 0.93);
    scene->geometryActor->GetProperty()->SetEdgeColor(dark ? 0.36 : 0.13, dark ? 0.62 : 0.45, dark ? 0.57 : 0.42);
    double accent[3] = {dark ? 0.35 : 0.10, dark ? 0.84 : 0.58, dark ? 0.74 : 0.50}; // VTK setters take non-const arrays
    scene->arrowActor->GetProperty()->SetColor(accent);
    scene->inletActor->GetProperty()->SetColor(accent);
    scene->inletLabel->GetTextProperty()->SetColor(accent);
}

void syncScene(PreviewScene *scene, const SceneState &state)
{
    if (scene->theme != int(state.darkTheme)) {
        scene->theme = int(state.darkTheme);
        applyTheme(scene, state.darkTheme);
    }
    bool reframe = false;
    if (scene->stlPath != state.stlPath) {
        scene->stlPath = state.stlPath;
        auto surface = readStl(state.stlPath);
        scene->hasStl = surface != nullptr;
        scene->stlMapper->SetInputData(surface ? surface.Get() : vtkNew<vtkPolyData>().Get());
        if (surface)
            buildTunnelPreview(scene, surface);
        reframe = true;
    }
    const CasePreview *preview = state.preview.get();
    // Reframe when switching between STL and case, or between near-model and whole-domain views;
    // keep the user's camera across time steps and fields.
    const auto framing = [](const CasePreview *p) { return p ? (p->mode == QStringLiteral("domain") ? 2 : 1) : 0; };
    if (framing(preview) != framing(scene->preview.get()))
        reframe = true;
    if (state.preview != scene->preview || state.colorMap != scene->colorMap) {
        const bool newPreview = state.preview != scene->preview;
        scene->preview = state.preview;
        scene->colorMap = state.colorMap;
        if (preview && newPreview)
            applyPreview(scene, *preview);
        applyColorMap(scene);
    }
    const bool hasModelPatch = preview && preview->model->GetNumberOfCells() > 0;
    scene->stlActor->SetVisibility(scene->hasStl && !hasModelPatch);
    scene->modelActor->SetVisibility(hasModelPatch);
    scene->geometryActor->SetVisibility(preview != nullptr);
    scene->scalarBar->SetVisibility(preview && preview->colored);
    const bool showTunnel = scene->hasStl && !preview;
    for (vtkProp *prop : {static_cast<vtkProp *>(scene->outlineActor.Get()), static_cast<vtkProp *>(scene->inletActor.Get()),
                          static_cast<vtkProp *>(scene->arrowActor.Get()), static_cast<vtkProp *>(scene->inletLabel.Get())})
        prop->SetVisibility(showTunnel);

    if (reframe) {
        if (preview) {
            frameCamera(scene->renderer, preview->focus);
        } else if (scene->hasStl) {
            frameCamera(scene->renderer, scene->tunnelView);
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
    syncScene(scene, {m_stlFile, m_preview, m_colorMap, m_darkTheme});
    return scene;
}
#else
struct CaseData {};
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
    resetCasePreview();
    requestCasePreview(true);
}

void VtkView::setPreviewRevision(int revision)
{
    if (m_previewRevision == revision)
        return;
    m_previewRevision = revision;
    emit previewRevisionChanged();
    if (revision <= 0)
        resetCasePreview();
    else
        requestCasePreview(true);
}

void VtkView::setColorMap(const QString &colorMap)
{
    if (m_colorMap == colorMap)
        return;
    m_colorMap = colorMap;
    emit colorMapChanged();
    updateScene();
}

void VtkView::setDarkTheme(bool dark)
{
    if (m_darkTheme == dark)
        return;
    m_darkTheme = dark;
    emit darkThemeChanged();
    updateScene();
}

QVariantList VtkView::colorMaps() const
{
    QVariantList maps;
    for (const ColorMap &map : kColorMaps) {
        QStringList colors;
        for (const auto &stop : map.stops)
            colors.append(QColor::fromRgbF(float(stop[0]), float(stop[1]), float(stop[2])).name());
        maps.append(QVariantMap{{QStringLiteral("value"), QString::fromLatin1(map.value)},
                                {QStringLiteral("label"), QString::fromLatin1(map.label)},
                                {QStringLiteral("colors"), colors}});
    }
    return maps;
}

void VtkView::setRenderMode(const QString &mode)
{
    if (m_renderMode == mode)
        return;
    m_renderMode = mode;
    emit renderModeChanged();
    requestCasePreview(false);
}

void VtkView::setField(const QString &field)
{
    if (m_field == field)
        return;
    m_field = field;
    emit fieldChanged();
    requestCasePreview(false);
}

void VtkView::resetCasePreview()
{
    ++m_loadGeneration; // drop any job still in flight
    m_jobPending = m_rereadPending = false;
    m_data.reset();
    m_preview.reset();
    setPreviewInfo({});
    updateScene();
}

void VtkView::requestCasePreview(bool reread)
{
    if (m_casePath.isEmpty() || m_previewRevision <= 0)
        return;
    m_jobPending = true;
    m_rereadPending = m_rereadPending || reread;
    if (!m_loading)
        startJob();
}

void VtkView::setLoading(bool loading)
{
    if (m_loading == loading)
        return;
    m_loading = loading;
    emit loadingChanged();
}

void VtkView::startJob()
{
#ifdef WINDTUNNEL_HAS_VTK
    const bool reread = m_rereadPending || !m_data;
    m_jobPending = m_rereadPending = false;
    setLoading(true);
    // Reading and filtering a large mesh takes a while; do it off the GUI and render threads.
    QThreadPool::globalInstance()->start([guard = QPointer<VtkView>(this), casePath = m_casePath,
                                          cached = reread ? std::shared_ptr<const CaseData>() : m_data,
                                          mode = m_renderMode, field = m_field, generation = m_loadGeneration] {
        auto data = cached ? cached : loadCaseData(casePath);
        auto preview = data ? buildPreview(data, mode, field) : nullptr;
        QMetaObject::invokeMethod(QCoreApplication::instance(), [guard, generation, data, preview] {
            if (guard) guard->applyJobResult(generation, data, preview);
        }, Qt::QueuedConnection);
    });
#endif
}

void VtkView::applyJobResult(int generation, std::shared_ptr<const CaseData> data, std::shared_ptr<const CasePreview> preview)
{
#ifdef WINDTUNNEL_HAS_VTK
    if (generation == m_loadGeneration && data) { // a failed read keeps the previous picture
        m_data = data;
        if (preview && preview->mode == m_renderMode && preview->field == m_field) {
            m_preview = preview;
            setPreviewInfo(preview->info);
            updateScene();
        } else {
            m_jobPending = true; // mode or field changed while building
        }
    }
    if (m_jobPending)
        startJob();
    else
        setLoading(false);
#else
    Q_UNUSED(generation) Q_UNUSED(data) Q_UNUSED(preview)
#endif
}

void VtkView::updateScene()
{
#ifdef WINDTUNNEL_HAS_VTK
    dispatch_async([state = SceneState{m_stlFile, m_preview, m_colorMap, m_darkTheme}](vtkRenderWindow *, vtkUserData userData) {
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
