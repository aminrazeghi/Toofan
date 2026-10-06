import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Advanced physics, run-control and mesh settings for the next run.
ColumnLayout {
    id: root
    required property var settings   // CaseSettings
    required property string solver  // pimpleFoam or rhoPimpleFoam, chosen from the inlet speed
    readonly property bool compressible: solver !== "pimpleFoam"
    spacing: 10

    readonly property var turbulenceModels: [
        { value: "kOmegaSST", label: "k-ω SST" },
        { value: "kEpsilon", label: "k-ε" },
        { value: "realizableKE", label: "Realizable k-ε" },
        { value: "SpalartAllmaras", label: "Spalart-Allmaras" },
        { value: "laminar", label: "Laminar (no model)" }
    ]

    component SectionTitle: Label {
        color: Theme.muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.4
        Layout.topMargin: 6
    }

    SectionTitle { text: "TURBULENCE"; Layout.topMargin: 0 }
    RowLayout {
        spacing: 8
        Label { text: "Model"; color: Theme.text; font.pixelSize: 12; Layout.fillWidth: true }
        ComboBox {
            id: modelBox
            Layout.preferredWidth: 160
            font.pixelSize: 12
            model: root.turbulenceModels
            textRole: "label"
            valueRole: "value"
            // `count` makes this re-evaluate once the model is loaded, not only when the setting changes.
            currentIndex: count > 0 ? indexOfValue(root.settings.turbulenceModel) : -1
            onActivated: root.settings.turbulenceModel = currentValue
        }
    }
    NumberField {
        Layout.fillWidth: true
        visible: root.settings.turbulenceModel !== "laminar"
        label: "Inlet intensity"; unit: "%"; maximum: 50
        value: root.settings.turbulenceIntensity
        onEdited: v => root.settings.turbulenceIntensity = v
    }
    NumberField {
        Layout.fillWidth: true
        visible: root.settings.turbulenceModel !== "laminar" && root.settings.turbulenceModel !== "SpalartAllmaras"
        label: "Inlet length scale"; unit: "× L"; minimum: 1e-4; maximum: 10
        value: root.settings.turbulenceLengthScale
        onEdited: v => root.settings.turbulenceLengthScale = v
    }

    SectionTitle { text: "FLUID  ·  " + (root.compressible ? "COMPRESSIBLE" : "INCOMPRESSIBLE") }
    NumberField {
        Layout.fillWidth: true; visible: !root.compressible
        label: "Density ρ"; unit: "kg/m³"; minimum: 1e-6
        value: root.settings.density
        onEdited: v => root.settings.density = v
    }
    NumberField {
        Layout.fillWidth: true; visible: !root.compressible
        label: "Kinematic viscosity ν"; unit: "m²/s"; minimum: 1e-12
        value: root.settings.kinematicViscosity
        onEdited: v => root.settings.kinematicViscosity = v
    }
    NumberField {
        Layout.fillWidth: true; visible: root.compressible
        label: "Pressure p"; unit: "Pa"; minimum: 1
        value: root.settings.pressure
        onEdited: v => root.settings.pressure = v
    }
    NumberField {
        Layout.fillWidth: true
        label: "Temperature T"; unit: "K"; minimum: 1; maximum: 5000
        value: root.settings.temperature
        onEdited: v => root.settings.temperature = v
    }
    NumberField {
        Layout.fillWidth: true; visible: root.compressible
        label: "Dynamic viscosity μ"; unit: "Pa·s"; minimum: 1e-12
        value: root.settings.dynamicViscosity
        onEdited: v => root.settings.dynamicViscosity = v
    }
    Label {
        Layout.fillWidth: true
        text: root.compressible ? "Air as a perfect gas; density follows from p and T."
                                : "T sets the speed of sound used to choose the solver."
        color: Theme.faint; font.pixelSize: 11; wrapMode: Text.WordWrap
    }

    SectionTitle { text: "RUN CONTROL" }
    NumberField {
        Layout.fillWidth: true
        label: "Run length"; unit: "flow-thr."; minimum: 0.01; maximum: 1000
        value: root.settings.flowThroughs
        onEdited: v => root.settings.flowThroughs = v
    }
    NumberField {
        Layout.fillWidth: true
        label: "Max Courant (0 = auto)"; unit: ""; maximum: 100
        value: root.settings.maxCourant
        onEdited: v => root.settings.maxCourant = v
    }
    NumberField {
        Layout.fillWidth: true; integer: true
        label: "Results written"; unit: "steps"; minimum: 1; maximum: 10000
        value: root.settings.writeCount
        onEdited: v => root.settings.writeCount = v
    }

    SectionTitle { text: "MESH" }
    NumberField {
        Layout.fillWidth: true; integer: true
        label: "Surface layers"; unit: ""; maximum: 20
        value: root.settings.surfaceLayers
        onEdited: v => root.settings.surfaceLayers = v
    }

    Button {
        Layout.fillWidth: true; Layout.topMargin: 8
        text: "Restore defaults"
        onClicked: root.settings.restoreDefaults()
    }
}
