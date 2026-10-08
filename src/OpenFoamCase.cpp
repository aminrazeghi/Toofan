// inja first: its headers must not see Qt's keyword macros (emit, signals, ...).
#include <inja/inja.hpp>

#include "OpenFoamCase.h"
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QMap>
#include <QtEndian>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <limits>

namespace {
using json = nlohmann::json;

const QString kTemplateRoot = QStringLiteral(":/templates/windTunnel");
const QString kCaseMarker = QStringLiteral(".toofan-case");
const QString kLegacyCaseMarker = QStringLiteral(".windtunnel-case"); // cases from before the rename
constexpr double kMolWeight = 28.96;  // air, kg/kmol
constexpr double kGamma = 1.4;

struct Bounds {
    std::array<double, 3> min{std::numeric_limits<double>::max(), std::numeric_limits<double>::max(), std::numeric_limits<double>::max()};
    std::array<double, 3> max{std::numeric_limits<double>::lowest(), std::numeric_limits<double>::lowest(), std::numeric_limits<double>::lowest()};
    void add(double x, double y, double z)
    {
        const std::array<double, 3> p{x, y, z};
        for (int i = 0; i < 3; ++i) { min[i] = std::min(min[i], p[i]); max[i] = std::max(max[i], p[i]); }
    }
    bool valid() const { return min[0] <= max[0] && min[1] <= max[1] && min[2] <= max[2]; }
    double extent(int i) const { return max[i] - min[i]; }
    double center(int i) const { return 0.5 * (min[i] + max[i]); }
};

// Binary STL: 80-byte header, uint32 triangle count, 50 bytes per triangle
// (normal and three vertices as little-endian floats, then 2 attribute bytes).
quint32 binaryStlTriangles(const QByteArray &data)
{
    if (data.size() < 84) return 0;
    const quint32 count = qFromLittleEndian<quint32>(data.constData() + 80);
    return 84 + qint64(count) * 50 == data.size() ? count : 0;
}

bool readFile(const QString &path, QByteArray *data, QString *error)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        *error = QStringLiteral("Cannot read %1: %2").arg(path, file.errorString());
        return false;
    }
    *data = file.readAll();
    return true;
}

bool readStlBounds(const QString &path, Bounds *bounds, QString *error)
{
    QByteArray data;
    if (!readFile(path, &data, error)) return false;
    if (const quint32 count = binaryStlTriangles(data)) {
        for (quint32 t = 0; t < count; ++t) {
            const char *vertex = data.constData() + 84 + qint64(t) * 50 + 12;
            for (int v = 0; v < 3; ++v, vertex += 12) {
                float xyz[3];
                for (int i = 0; i < 3; ++i) xyz[i] = qFromLittleEndian<float>(vertex + 4 * i);
                bounds->add(xyz[0], xyz[1], xyz[2]);
            }
        }
    }
    if (!bounds->valid()) {
        for (const QByteArray &line : data.split('\n')) {
            const QList<QByteArray> parts = line.simplified().split(' ');
            if (parts.size() == 4 && parts[0] == "vertex")
                bounds->add(parts[1].toDouble(), parts[2].toDouble(), parts[3].toDouble());
        }
    }
    if (!bounds->valid() || std::max({bounds->extent(0), bounds->extent(1), bounds->extent(2)}) <= 0.0) {
        *error = QStringLiteral("The STL file contains no usable geometry.");
        return false;
    }
    return true;
}

using Matrix3 = std::array<std::array<double, 3>, 3>;

// R = Rz * Ry * Rx: rotate about x, then y, then z, all fixed axes. VtkView's preview uses the same order.
Matrix3 rotationMatrix(const std::array<double, 3> &degrees)
{
    const double r = M_PI / 180.0;
    const double cx = std::cos(degrees[0] * r), sx = std::sin(degrees[0] * r);
    const double cy = std::cos(degrees[1] * r), sy = std::sin(degrees[1] * r);
    const double cz = std::cos(degrees[2] * r), sz = std::sin(degrees[2] * r);
    const Matrix3 rx{{{1, 0, 0}, {0, cx, -sx}, {0, sx, cx}}};
    const Matrix3 ry{{{cy, 0, sy}, {0, 1, 0}, {-sy, 0, cy}}};
    const Matrix3 rz{{{cz, -sz, 0}, {sz, cz, 0}, {0, 0, 1}}};
    const auto multiply = [](const Matrix3 &a, const Matrix3 &b) {
        Matrix3 m{};
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
                for (int k = 0; k < 3; ++k) m[i][j] += a[i][k] * b[k][j];
        return m;
    };
    return multiply(rz, multiply(ry, rx));
}

// Writes `source` rotated about the centre of `model` to `target`, keeping its format: binary stays
// binary, and ASCII keeps everything but the normal and vertex coordinates (so named solids survive).
bool writeRotatedStl(const QString &source, const QString &target, const std::array<double, 3> &degrees,
                     const Bounds &model, QString *error)
{
    QByteArray data;
    if (!readFile(source, &data, error)) return false;
    const Matrix3 m = rotationMatrix(degrees);
    const double centre[3] = {model.center(0), model.center(1), model.center(2)};
    // Points rotate about the centre; normals are directions and only rotate.
    const auto rotated = [&](const double p[3], bool point) {
        std::array<double, 3> q{};
        for (int i = 0; i < 3; ++i) {
            for (int k = 0; k < 3; ++k) q[i] += m[i][k] * (p[k] - (point ? centre[k] : 0.0));
            if (point) q[i] += centre[i];
        }
        return q;
    };

    if (const quint32 count = binaryStlTriangles(data)) {
        for (quint32 t = 0; t < count; ++t) {
            char *record = data.data() + 84 + qint64(t) * 50;
            for (int v = 0; v < 4; ++v) { // normal, then three vertices
                double p[3];
                for (int i = 0; i < 3; ++i) p[i] = qFromLittleEndian<float>(record + 12 * v + 4 * i);
                const auto q = rotated(p, v > 0);
                for (int i = 0; i < 3; ++i) qToLittleEndian<float>(float(q[i]), record + 12 * v + 4 * i);
            }
        }
    } else {
        QList<QByteArray> lines = data.split('\n');
        for (QByteArray &line : lines) {
            const QByteArray trimmed = line.trimmed();
            const bool vertex = trimmed.startsWith("vertex");
            if (!vertex && !trimmed.startsWith("facet normal")) continue;
            const QList<QByteArray> parts = trimmed.simplified().split(' ');
            const int first = vertex ? 1 : 2;
            if (parts.size() < first + 3) continue;
            const double p[3] = {parts[first].toDouble(), parts[first + 1].toDouble(), parts[first + 2].toDouble()};
            const auto q = rotated(p, vertex);
            const QByteArray indent = line.left(line.indexOf(trimmed.at(0)));
            line = indent + (vertex ? "vertex " : "facet normal ") + QByteArray::number(q[0], 'g', 9) + ' '
                   + QByteArray::number(q[1], 'g', 9) + ' ' + QByteArray::number(q[2], 'g', 9)
                   + (line.endsWith('\r') ? "\r" : "");
        }
        data = lines.join('\n');
    }

    QFile file(target);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) || file.write(data) != data.size()) {
        *error = QStringLiteral("Cannot write %1: %2").arg(target, file.errorString());
        return false;
    }
    return true;
}

// Six significant digits keeps the dictionaries readable (no 0.30000000000000004).
double round6(double value) { return QString::number(value, 'g', 6).toDouble(); }
json vec(double x, double y, double z) { return json::array({round6(x), round6(y), round6(z)}); }

json buildTemplateData(const CaseOptions &options, const QString &solver, const Bounds &model)
{
    const bool fine = options.meshQuality == QStringLiteral("Fine");
    const bool compressible = solver != QStringLiteral("pimpleFoam");
    const double length = std::max({model.extent(0), model.extent(1), model.extent(2)});
    const double baseCell = length / (fine ? 6.0 : 4.0);
    const int surfaceLevelMin = fine ? 4 : 3;
    const int surfaceLevelMax = surfaceLevelMin + 1;

    const std::array<double, 6> tunnel = OpenFoamCase::tunnelBounds({model.min[0], model.max[0], model.min[1], model.max[1], model.min[2], model.max[2]});
    const std::array<double, 3> lo{tunnel[0], tunnel[2], tunnel[4]};
    const std::array<double, 3> hi{tunnel[1], tunnel[3], tunnel[5]};
    std::array<int, 3> cells{};
    std::array<double, 3> location{};
    for (int i = 0; i < 3; ++i) {
        cells[i] = std::max(1, int(std::ceil((hi[i] - lo[i]) / baseCell)));
        // Inside the second background cell near the inlet corner, off every face at all refinement levels.
        location[i] = lo[i] + 1.4321 * (hi[i] - lo[i]) / cells[i];
    }

    const double speed = std::max(options.inletSpeed, 1e-3);
    const double pressure = options.pressure, temperature = options.temperature;
    const double gasConstant = 8314.46 / kMolWeight;
    const double rho = compressible ? pressure / (gasConstant * temperature) : options.density;
    const double nu = compressible ? options.dynamicViscosity / rho : options.kinematicViscosity;
    const double mach = speed / OpenFoamCase::speedOfSound(temperature);

    // Inlet turbulence from intensity I and length scale l (standard estimates).
    const double cmu = 0.09;
    const double l = std::max(options.turbulenceLengthScale, 1e-6) * length;
    const double k = 1.5 * std::pow(speed * options.turbulenceIntensity, 2);
    const double omega = std::sqrt(k) / (std::pow(cmu, 0.25) * l);
    const double epsilon = std::pow(cmu, 0.75) * std::pow(k, 1.5) / l;
    const double nuTilda = 3.0 * nu; // free-stream Spalart-Allmaras value

    const QString &turbulenceModel = options.turbulenceModel;
    const bool laminar = turbulenceModel == QStringLiteral("laminar");
    const bool spalart = turbulenceModel == QStringLiteral("SpalartAllmaras");
    const bool usesOmega = turbulenceModel == QStringLiteral("kOmegaSST");
    const bool usesEpsilon = turbulenceModel == QStringLiteral("kEpsilon") || turbulenceModel == QStringLiteral("realizableKE");

    const double minCell = baseCell / std::pow(2.0, surfaceLevelMax);
    const double tunnelLength = hi[0] - lo[0];
    const double endTime = std::max(options.flowThroughs, 0.01) * tunnelLength / speed;
    const double maxCo = options.maxCourant > 0 ? options.maxCourant : (compressible ? 1.0 : 2.0);

    const double lRef = model.extent(0) > 0 ? model.extent(0) : length;
    const double frontalArea = model.extent(1) * model.extent(2);

    json data;
    data["solver"] = solver.toStdString();
    data["compressible"] = compressible;
    // Each field template checks the flags it needs; templates that render empty are not written.
    data["turbulence"] = {
        {"model", turbulenceModel.toStdString()}, {"laminar", laminar},
        {"usesK", usesOmega || usesEpsilon}, {"usesOmega", usesOmega}, {"usesEpsilon", usesEpsilon}, {"usesNuTilda", spalart},
        {"nutWallFunction", spalart ? "nutUSpaldingWallFunction" : "nutkWallFunction"},
    };
    data["surface"] = {{"file", "model.stl"}, {"name", "model"}, {"group", "modelGroup"}, {"eMesh", "model.eMesh"}};
    data["flow"] = {
        {"U", vec(speed, 0, 0)}, {"Umag", round6(speed)}, {"mach", round6(mach)}, {"transonic", mach >= 0.7},
        {"k", round6(k)}, {"omega", round6(omega)}, {"epsilon", round6(epsilon)}, {"nuTilda", round6(nuTilda)},
        {"nu", round6(nu)},
        {"rhoInf", round6(rho)},
        {"p", round6(pressure)}, {"T", round6(temperature)}, {"mu", round6(options.dynamicViscosity)},
        {"Cp", 1005.0}, {"Pr", 0.71}, {"molWeight", kMolWeight},
    };
    data["domain"] = {
        {"xMin", round6(lo[0])}, {"xMax", round6(hi[0])},
        {"yMin", round6(lo[1])}, {"yMax", round6(hi[1])},
        {"zMin", round6(lo[2])}, {"zMax", round6(hi[2])},
        {"nx", cells[0]}, {"ny", cells[1]}, {"nz", cells[2]},
        {"length", round6(tunnelLength)},
    };
    data["mesh"] = {
        {"surfaceLevelMin", surfaceLevelMin}, {"surfaceLevelMax", surfaceLevelMax},
        {"featureLevel", surfaceLevelMax}, {"boxLevel", 2},
        {"refinementBox", {
            {"min", vec(model.min[0] - 0.5 * length, model.min[1] - 0.5 * length, model.min[2] - 0.5 * length)},
            {"max", vec(model.max[0] + 2.0 * length, model.max[1] + 0.5 * length, model.max[2] + 0.5 * length)},
        }},
        {"locationInMesh", vec(location[0], location[1], location[2])},
        {"maxGlobalCells", fine ? 8000000 : 2000000}, {"maxLocalCells", fine ? 8000000 : 2000000},
        {"addLayers", options.surfaceLayers > 0 ? "true" : "false"}, {"nSurfaceLayers", std::max(options.surfaceLayers, 1)},
    };
    data["time"] = {
        {"endTime", round6(endTime)},
        {"deltaT", round6(0.2 * minCell / speed)},
        {"writeInterval", round6(endTime / std::max(options.writeCount, 1))},
        {"maxCo", round6(maxCo)},
    };
    data["parallel"] = {
        {"enabled", options.processors > 1}, {"processors", std::max(options.processors, 1)}, {"method", "scotch"},
    };
    data["forces"] = {
        {"CofR", vec(model.center(0), model.center(1), model.center(2))},
        {"lRef", round6(lRef)},
        {"Aref", round6(frontalArea > 0 ? frontalArea : length * length)},
    };
    return data;
}

bool readResource(const QString &path, std::string *contents, QString *error)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        *error = QStringLiteral("Cannot read template %1").arg(path);
        return false;
    }
    *contents = file.readAll().toStdString();
    return true;
}

bool renderTemplates(const json &data, const QString &solver, const QDir &root, QString *error)
{
    inja::Environment env;
    env.set_trim_blocks(true);
    env.set_lstrip_blocks(true);
    env.set_search_included_templates_in_files(false);
    env.add_callback("vec", 1, [](inja::Arguments &args) {
        const json &value = *args.at(0);
        std::string out = "(";
        for (std::size_t i = 0; i < value.size(); ++i) {
            if (i) out += ' ';
            out += value[i].dump();
        }
        return out + ")";
    });

    std::string contents;
    QString current;
    try {
        QDirIterator partials(kTemplateRoot + QStringLiteral("/_partials"), QDir::Files);
        while (partials.hasNext()) {
            current = partials.next();
            if (!readResource(current, &contents, error)) return false;
            env.include_template(QFileInfo(current).fileName().toStdString(), env.parse(contents));
        }

        // Solver files override common files with the same relative path.
        QMap<QString, QString> sources;
        for (const QString &layer : {QStringLiteral("common"), solver}) {
            const QDir base(kTemplateRoot + QLatin1Char('/') + layer);
            QDirIterator it(base.path(), QDir::Files, QDirIterator::Subdirectories);
            while (it.hasNext()) {
                const QString source = it.next();
                sources.insert(base.relativeFilePath(source), source);
            }
        }

        for (auto it = sources.cbegin(); it != sources.cend(); ++it) {
            current = it.value();
            if (!readResource(current, &contents, error)) return false;
            const std::string rendered = env.render(contents, data);
            // A template wrapped in a false condition (e.g. omega for k-epsilon) is not part of this case.
            if (rendered.find_first_not_of(" \t\r\n") == std::string::npos)
                continue;
            const QString target = root.filePath(it.key());
            QDir().mkpath(QFileInfo(target).path());
            QFile file(target);
            if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) ||
                file.write(rendered.data(), qint64(rendered.size())) != qint64(rendered.size())) {
                *error = QStringLiteral("Cannot write %1: %2").arg(target, file.errorString());
                return false;
            }
        }
    } catch (const std::exception &e) {
        *error = QStringLiteral("Template %1: %2").arg(current, QString::fromUtf8(e.what()));
        return false;
    }
    return true;
}

// Removes output of a previous run so the case matches the new settings. Only touches
// directories the app created (marked with kCaseMarker) and only the generated parts.
bool resetCaseDirectory(const QDir &root, QString *error)
{
    if (root.exists() && !root.isEmpty(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden) &&
        !QFileInfo::exists(root.filePath(kCaseMarker)) && !QFileInfo::exists(root.filePath(kLegacyCaseMarker))) {
        *error = QStringLiteral("%1 already exists and was not created by Toofan; refusing to overwrite it.").arg(root.path());
        return false;
    }
    const QStringList generated{QStringLiteral("0"), QStringLiteral("0.orig"), QStringLiteral("constant"),
                                QStringLiteral("system"), QStringLiteral("postProcessing")};
    for (const QFileInfo &entry : root.entryInfoList(QDir::Dirs | QDir::NoDotAndDotDot)) {
        bool isTime = false;
        entry.fileName().toDouble(&isTime);
        if (isTime || generated.contains(entry.fileName()) || entry.fileName().startsWith(QStringLiteral("processor")))
            QDir(entry.filePath()).removeRecursively();
    }
    for (const QString &log : root.entryList({QStringLiteral("*.log")}, QDir::Files))
        QFile::remove(root.filePath(log));
    if (!root.mkpath(QStringLiteral("constant/triSurface"))) {
        *error = QStringLiteral("Cannot create the OpenFOAM case directory %1.").arg(root.path());
        return false;
    }
    QFile foamFile(root.filePath(QStringLiteral("case.foam"))); // lets ParaView and the preview open the case
    if (!foamFile.open(QIODevice::WriteOnly)) {
        *error = QStringLiteral("Cannot write %1: %2").arg(foamFile.fileName(), foamFile.errorString());
        return false;
    }
    QFile::remove(root.filePath(kLegacyCaseMarker));
    QFile marker(root.filePath(kCaseMarker));
    if (!marker.open(QIODevice::WriteOnly)) {
        *error = QStringLiteral("Cannot write %1: %2").arg(marker.fileName(), marker.errorString());
        return false;
    }
    return true;
}
}

double OpenFoamCase::speedOfSound(double temperature)
{
    return std::sqrt(kGamma * 8314.46 / kMolWeight * std::max(temperature, 1.0));
}

QString OpenFoamCase::solverForSpeed(double speed, double temperature)
{
    const double mach = speed / speedOfSound(temperature);
    if (mach < 0.3) return QStringLiteral("pimpleFoam");
    if (mach < 1.0) return QStringLiteral("rhoPimpleFoam");
    return QStringLiteral("sonicFoam");
}

std::array<double, 6> OpenFoamCase::tunnelBounds(const std::array<double, 6> &model)
{
    // 3 model lengths upstream, 8 downstream, 2.5 on each side.
    const double length = std::max({model[1] - model[0], model[3] - model[2], model[5] - model[4]});
    return {model[0] - 3.0 * length, model[1] + 8.0 * length,
            model[2] - 2.5 * length, model[3] + 2.5 * length,
            model[4] - 2.5 * length, model[5] + 2.5 * length};
}

QString OpenFoamCase::defaultCaseRoot()
{
    return QDir::home().filePath(QStringLiteral("Toofan-Projects"));
}

bool OpenFoamCase::prepare(const CaseOptions &options, QString *message)
{
    QString scratch;
    QString *error = message ? message : &scratch;
    const QFileInfo stl(options.stlPath);
    if (!stl.exists() || !stl.isFile() || stl.suffix().compare(QStringLiteral("stl"), Qt::CaseInsensitive) != 0) {
        *error = QStringLiteral("Choose a readable STL file first.");
        return false;
    }
    const QString solver = solverForSpeed(options.inletSpeed, options.temperature);
    if (!QFileInfo(kTemplateRoot + QLatin1Char('/') + solver).isDir()) {
        *error = QStringLiteral("No wind tunnel template for %1 yet; lower the inlet speed below Mach 1 (pimpleFoam or rhoPimpleFoam).").arg(solver);
        return false;
    }
    Bounds original;
    if (!readStlBounds(stl.absoluteFilePath(), &original, error)) return false;

    const QDir root(options.casePath);
    if (!resetCaseDirectory(root, error)) return false;
    const QString surfacePath = root.filePath(QStringLiteral("constant/triSurface/model.stl"));
    const bool rotated = options.rotation != std::array<double, 3>{0.0, 0.0, 0.0};
    if (rotated) {
        if (!writeRotatedStl(stl.absoluteFilePath(), surfacePath, options.rotation, original, error)) return false;
    } else if (!QFile::copy(stl.absoluteFilePath(), surfacePath)) {
        *error = QStringLiteral("Cannot copy the STL into the case directory.");
        return false;
    }
    // The tunnel is sized around the model as it will be meshed.
    Bounds model;
    if (!readStlBounds(surfacePath, &model, error)) return false;
    const json data = buildTemplateData(options, solver, model);
    if (!renderTemplates(data, solver, root, error)) return false;

    const json &domain = data["domain"];
    *error = QStringLiteral("Prepared %1 wind tunnel case in %2 (%3 x %4 x %5 background cells).")
                 .arg(solver, root.path())
                 .arg(domain["nx"].get<int>()).arg(domain["ny"].get<int>()).arg(domain["nz"].get<int>());
    return true;
}
