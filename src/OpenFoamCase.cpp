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
const QString kCaseMarker = QStringLiteral(".windtunnel-case");
constexpr double kSoundSpeed = 343.0; // provisional standard-air estimate (293 K)

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

bool readStlBounds(const QString &path, Bounds *bounds, QString *error)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        *error = QStringLiteral("Cannot read %1: %2").arg(path, file.errorString());
        return false;
    }
    const QByteArray data = file.readAll();
    // Binary STL: 80-byte header, uint32 triangle count, 50 bytes per triangle.
    if (data.size() >= 84) {
        const quint32 count = qFromLittleEndian<quint32>(data.constData() + 80);
        if (84 + qint64(count) * 50 == data.size()) {
            for (quint32 t = 0; t < count; ++t) {
                const char *vertex = data.constData() + 84 + qint64(t) * 50 + 12;
                for (int v = 0; v < 3; ++v, vertex += 12) {
                    float xyz[3];
                    for (int i = 0; i < 3; ++i) xyz[i] = qFromLittleEndian<float>(vertex + 4 * i);
                    bounds->add(xyz[0], xyz[1], xyz[2]);
                }
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

    // Tunnel box: 3 model lengths upstream, 8 downstream, 2.5 on each side.
    std::array<double, 3> lo{model.min[0] - 3.0 * length, model.min[1] - 2.5 * length, model.min[2] - 2.5 * length};
    std::array<double, 3> hi{model.max[0] + 8.0 * length, model.max[1] + 2.5 * length, model.max[2] + 2.5 * length};
    std::array<int, 3> cells{};
    std::array<double, 3> location{};
    for (int i = 0; i < 3; ++i) {
        cells[i] = std::max(1, int(std::ceil((hi[i] - lo[i]) / baseCell)));
        // Inside the second background cell near the inlet corner, off every face at all refinement levels.
        location[i] = lo[i] + 1.4321 * (hi[i] - lo[i]) / cells[i];
    }

    const double speed = std::max(options.inletSpeed, 1e-3);
    const double mach = speed / kSoundSpeed;
    const double intensity = 0.01;
    const double k = 1.5 * std::pow(speed * intensity, 2);
    const double omega = std::sqrt(k) / (std::pow(0.09, 0.25) * 0.1 * length);
    const double pressure = 101325.0, temperature = 293.15, molWeight = 28.96;
    const double gasConstant = 8314.46 / molWeight;

    const double minCell = baseCell / std::pow(2.0, surfaceLevelMax);
    const double tunnelLength = hi[0] - lo[0];
    const double endTime = 2.0 * tunnelLength / speed; // two flow-through times

    const double lRef = model.extent(0) > 0 ? model.extent(0) : length;
    const double frontalArea = model.extent(1) * model.extent(2);

    json data;
    data["solver"] = solver.toStdString();
    data["compressible"] = compressible;
    data["surface"] = {{"file", "model.stl"}, {"name", "model"}, {"group", "modelGroup"}, {"eMesh", "model.eMesh"}};
    data["flow"] = {
        {"U", vec(speed, 0, 0)}, {"Umag", round6(speed)}, {"mach", round6(mach)}, {"transonic", mach >= 0.7},
        {"k", round6(k)}, {"omega", round6(omega)},
        {"nu", 1.5e-5},
        {"rhoInf", compressible ? round6(pressure / (gasConstant * temperature)) : 1.225},
        {"p", pressure}, {"T", temperature}, {"mu", 1.81e-5}, {"Cp", 1005.0}, {"Pr", 0.71}, {"molWeight", molWeight},
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
        {"addLayers", "true"}, {"nSurfaceLayers", 3},
    };
    data["time"] = {
        {"endTime", round6(endTime)},
        {"deltaT", round6(0.2 * minCell / speed)},
        {"writeInterval", round6(endTime / 20.0)},
        {"maxCo", compressible ? 1.0 : 2.0},
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
        !QFileInfo::exists(root.filePath(kCaseMarker))) {
        *error = QStringLiteral("%1 already exists and was not created by Digital Wind Tunnel; refusing to overwrite it.").arg(root.path());
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
        root.remove(log);
    if (!root.mkpath(QStringLiteral("constant/triSurface"))) {
        *error = QStringLiteral("Cannot create the OpenFOAM case directory %1.").arg(root.path());
        return false;
    }
    QFile marker(root.filePath(kCaseMarker));
    if (!marker.open(QIODevice::WriteOnly)) {
        *error = QStringLiteral("Cannot write %1: %2").arg(marker.fileName(), marker.errorString());
        return false;
    }
    return true;
}
}

QString OpenFoamCase::solverForSpeed(double speed)
{
    const double mach = speed / kSoundSpeed;
    if (mach < 0.3) return QStringLiteral("pimpleFoam");
    if (mach < 1.0) return QStringLiteral("rhoPimpleFoam");
    return QStringLiteral("sonicFoam");
}

QString OpenFoamCase::defaultCaseRoot()
{
    return QDir::home().filePath(QStringLiteral("wind-tunnel"));
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
    const QString solver = solverForSpeed(options.inletSpeed);
    if (!QFileInfo(kTemplateRoot + QLatin1Char('/') + solver).isDir()) {
        *error = QStringLiteral("No wind tunnel template for %1 yet; lower the inlet speed below Mach 1 (pimpleFoam or rhoPimpleFoam).").arg(solver);
        return false;
    }
    Bounds model;
    if (!readStlBounds(stl.absoluteFilePath(), &model, error)) return false;

    const QDir root(options.casePath);
    if (!resetCaseDirectory(root, error)) return false;
    const QString surfacePath = root.filePath(QStringLiteral("constant/triSurface/model.stl"));
    if (!QFile::copy(stl.absoluteFilePath(), surfacePath)) {
        *error = QStringLiteral("Cannot copy the STL into the case directory.");
        return false;
    }
    const json data = buildTemplateData(options, solver, model);
    if (!renderTemplates(data, solver, root, error)) return false;

    const json &domain = data["domain"];
    *error = QStringLiteral("Prepared %1 wind tunnel case in %2 (%3 x %4 x %5 background cells).")
                 .arg(solver, root.path())
                 .arg(domain["nx"].get<int>()).arg(domain["ny"].get<int>()).arg(domain["nz"].get<int>());
    return true;
}
