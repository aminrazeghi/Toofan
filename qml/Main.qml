import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import WindTunnel

ApplicationWindow {
    id: window
    width: 1440
    height: 900
    minimumWidth: 1100
    minimumHeight: 700
    visible: true
    title: "Digital Wind Tunnel"
    color: Theme.window
    property color panel: Theme.panel
    property color muted: Theme.muted
    property color accent: Theme.accent
    property color danger: Theme.danger
    // Basic-style controls (buttons, sliders, text fields, combo boxes) follow the theme too.
    palette {
        window: Theme.panel; windowText: Theme.text
        base: Theme.field; alternateBase: Theme.control; text: Theme.textStrong
        button: Theme.control; buttonText: Theme.text
        light: Theme.controlHover; midlight: Theme.controlHover; mid: Theme.controlBorder; dark: Theme.controlBorder
        highlight: Theme.accent; highlightedText: Theme.accentText
        placeholderText: Theme.faint
    }

    Settings {
        id: appSettings
        category: "appearance"
        property bool darkTheme: true
        property string colorMap: "viridis"
    }
    Binding { target: Theme; property: "dark"; value: appSettings.darkTheme }

    // Turbulence fields that exist for the selected model, for the field selector.
    function turbulenceFields(model) {
        if (model === "kOmegaSST") return [{ value: "k", label: "k" }, { value: "omega", label: "ω" }]
        if (model === "kEpsilon" || model === "realizableKE") return [{ value: "k", label: "k" }, { value: "epsilon", label: "ε" }]
        if (model === "SpalartAllmaras") return [{ value: "nuTilda", label: "ν̃" }]
        return []
    }
    // Plot shown over the 3D view: "", "residuals", "drag" or "lift".
    property string openPlot: ""
    readonly property int sideWidth: 250

    function formatCoefficient(value) {
        if (isNaN(value)) return "—"
        return Math.abs(value) >= 1e-3 || value === 0 ? value.toFixed(4) : value.toExponential(2)
    }

    header: ToolBar {
        background: Rectangle { color: Theme.window; border.color: Theme.border; border.width: 1 }
        implicitHeight: 60
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 20; anchors.rightMargin: 16
            spacing: 10
            Label { text: "◈"; color: accent; font.pixelSize: 23 }
            Label { text: "Toofan CFD"; color: Theme.textStrong; font.bold: true; font.letterSpacing: 2 }
            Item { Layout.fillWidth: true }
            ToolButton {
                text: "⚙"
                ToolTip.visible: hovered; ToolTip.text: "Settings"
                onClicked: settingsDialog.open()
                contentItem: Text { text: parent.text; color: Theme.muted; font.pixelSize: 19; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 9; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 38; implicitHeight: 38 }
            }
            Button {
                text: "▶   Start simulation"
                enabled: !simulation.running
                onClicked: simulation.startSimulation()
                contentItem: Text { text: parent.text; color: Theme.accentText; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 9; color: parent.enabled ? accent : Theme.accentDisabled; implicitWidth: 180; implicitHeight: 38 }
            }
            Button {
                text: "Stop"
                enabled: simulation.status.startsWith("Running ")
                onClicked: simulation.stopSimulation()
                contentItem: Text { text: parent.text; color: parent.enabled ? Theme.textStrong : Theme.faint; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 9; color: Theme.control; border.color: parent.enabled ? danger : Theme.controlBorder; implicitWidth: 90; implicitHeight: 38 }
            }
        }
    }

    SettingsDialog {
        id: settingsDialog
        darkTheme: appSettings.darkTheme
        colorMap: appSettings.colorMap
        colorMaps: vtkView.colorMaps()
        onThemeSelected: dark => appSettings.darkTheme = dark
        onColorMapSelected: value => appSettings.colorMap = value
    }

    FileDialog {
        id: stlDialog
        title: "Choose a model"
        nameFilters: ["STL models (*.stl)", "All files (*)"]
        onAccepted: simulation.stlPath = selectedFile
    }

    GridLayout {
        anchors.fill: parent
        anchors.margins: 14
        columns: 3
        rowSpacing: 12; columnSpacing: 12

        // ---- Left: run setup (locked and slid away while a run is in progress) ----
        Rectangle {
            id: setupPanel
            readonly property bool collapsed: simulation.running
            Layout.preferredWidth: collapsed ? 52 : 320; Layout.fillHeight: true
            radius: 14; color: panel; border.color: Theme.border
            clip: true
            Behavior on Layout.preferredWidth { NumberAnimation { duration: 320; easing.type: Easing.InOutCubic } }

            // Collapsed strip: what the running case was set up with.
            Label {
                anchors.centerIn: parent
                rotation: -90
                opacity: setupPanel.collapsed ? 1 : 0
                visible: opacity > 0
                // Appear only once the controls have slid out; disappear immediately on expand.
                Behavior on opacity {
                    SequentialAnimation {
                        PauseAnimation { duration: setupPanel.collapsed ? 300 : 0 }
                        NumberAnimation { duration: setupPanel.collapsed ? 200 : 120 }
                    }
                }
                text: "RUN SETUP  ·  " + (simulation.stlPath ? simulation.stlPath.split("/").pop() : "no model")
                      + "  ·  " + Math.round(simulation.speed) + " m/s  ·  " + simulation.meshQuality
                color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.2
            }

            ColumnLayout {
                x: setupPanel.collapsed ? -width - 20 : 18
                Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.InOutCubic } }
                y: 18; width: 284; height: parent.height - 36; spacing: 16
                enabled: !setupPanel.collapsed
                opacity: setupPanel.collapsed ? 0.35 : 1
                Behavior on opacity { NumberAnimation { duration: 240 } }
                RowLayout {
                    Label { text: "RUN SETUP"; color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.6; Layout.fillWidth: true }
                    SegmentedControl {
                        options: [{ value: "0", label: "Basic" }, { value: "1", label: "Advanced" }]
                        current: String(setupPages.currentIndex)
                        onActivated: value => setupPages.currentIndex = Number(value)
                    }
                }
                StackLayout {
                    id: setupPages
                    Layout.fillWidth: true; Layout.fillHeight: true
                ScrollView {
                id: basicScroll
                clip: true
                contentWidth: availableWidth
                ColumnLayout {
                width: basicScroll.availableWidth - 10
                spacing: 14
                Label { text: "Model geometry"; color: Theme.textStrong; font.pixelSize: 14; font.bold: true }
                Rectangle {
                    Layout.fillWidth: true; Layout.preferredHeight: 108; radius: 12
                    color: Theme.field; border.color: simulation.stlPath ? accent : Theme.controlBorder
                    Column { anchors.centerIn: parent; spacing: 8
                        Label { anchors.horizontalCenter: parent.horizontalCenter; text: "＋"; color: accent; font.pixelSize: 24 }
                        Label { anchors.horizontalCenter: parent.horizontalCenter; text: simulation.stlPath ? simulation.stlPath.split("/").pop() : "Drop an STL or browse"; color: Theme.text; font.pixelSize: 12; elide: Text.ElideMiddle; width: basicScroll.availableWidth - 30; horizontalAlignment: Text.AlignHCenter }
                    }
                    MouseArea { anchors.fill: parent; onClicked: stlDialog.open() }
                }
                Button { text: "Browse files"; Layout.fillWidth: true; onClicked: stlDialog.open() }
                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.divider }
                Label { text: "Inlet speed"; color: Theme.textStrong; font.pixelSize: 14; font.bold: true }
                RowLayout {
                    Layout.fillWidth: true
                    Slider { id: speedSlider; Layout.fillWidth: true; from: 1; to: 250; value: simulation.speed; onMoved: simulation.speed = value }
                    Label { text: Math.round(speedSlider.value) + " m/s"; color: Theme.textStrong; font.pixelSize: 14; Layout.preferredWidth: 58 }
                }
                Label { text: "Selected solver  ·  " + simulation.solver; color: muted; font.pixelSize: 12 }
                Rectangle { Layout.fillWidth: true; height: 1; color: Theme.divider }
                Label { text: "Mesh resolution"; color: Theme.textStrong; font.pixelSize: 14; font.bold: true }
                RowLayout {
                    Layout.fillWidth: true
                    Repeater {
                        model: ["Coarse", "Fine"]
                        delegate: Button {
                            required property string modelData
                            Layout.fillWidth: true; text: modelData
                            onClicked: simulation.meshQuality = modelData
                            background: Rectangle { radius: 8; color: simulation.meshQuality === modelData ? Theme.selected : Theme.control; border.color: simulation.meshQuality === modelData ? accent : Theme.controlBorder }
                            contentItem: Text { text: parent.text; color: simulation.meshQuality === modelData ? accent : muted; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; padding: 8 }
                        }
                    }
                }
                Label { text: "Turbulence, fluid properties and run length are under Advanced."; color: Theme.faint; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true; Layout.topMargin: 6 }
                }
                }
                ScrollView {
                    id: advancedScroll
                    clip: true
                    contentWidth: availableWidth
                    AdvancedSettings {
                        width: advancedScroll.availableWidth - 10
                        settings: simulation.settings
                        solver: simulation.solver
                    }
                }
                }
            }
        }

        // ---- Centre: 3D view, with plots opened over it ----
        Rectangle {
            Layout.fillWidth: true; Layout.fillHeight: true
            radius: 3; color: panel; border.color: Theme.border // the VTK surface is square; keep corners nearly square too
            VtkView {
                id: vtkView
                anchors.fill: parent; anchors.margins: 1
                stlFile: simulation.stlPath
                casePath: simulation.casePath
                previewRevision: simulation.previewRevision
                colorMap: appSettings.colorMap
                darkTheme: Theme.dark
            }
            Column {
                visible: simulation.previewRevision > 0
                anchors { right: parent.right; top: parent.top; margins: 14 }
                spacing: 8
                SegmentedControl {
                    anchors.right: parent.right
                    options: [{ value: "domain", label: "Full domain" }, { value: "slice", label: "Slice" }, { value: "streamlines", label: "Streamlines" }]
                    current: vtkView.renderMode
                    onActivated: value => vtkView.renderMode = value
                }
                SegmentedControl {
                    anchors.right: parent.right
                    options: [{ value: "U", label: "U" }, { value: "p", label: "p" }]
                             .concat(turbulenceFields(simulation.settings.turbulenceModel))
                             .concat(simulation.solver === "rhoPimpleFoam" ? [{ value: "T", label: "T" }, { value: "rho", label: "ρ" }, { value: "Ma", label: "Ma" }] : [])
                    current: vtkView.field
                    onActivated: value => vtkView.field = value
                    // Fall back to U when the selected field no longer exists (other model or solver).
                    onOptionsChanged: if (!options.some(o => o.value === vtkView.field)) vtkView.field = "U"
                }
            }
            Rectangle {
                visible: vtkView.previewInfo.length > 0 || vtkView.loading
                anchors { left: parent.left; top: parent.top; margins: 14 }
                radius: 8; color: Theme.overlay; border.color: Theme.controlBorder
                implicitWidth: previewLabel.implicitWidth + 20; implicitHeight: previewLabel.implicitHeight + 12
                Label { id: previewLabel; anchors.centerIn: parent; text: vtkView.previewInfo + (vtkView.loading ? (vtkView.previewInfo ? "  ·  " : "") + "Updating…" : ""); color: Theme.text; font.pixelSize: 12 }
            }
            Column {
                anchors.centerIn: parent; spacing: 12
                visible: simulation.stlPath.length === 0
                Label { text: "◌"; color: Theme.accent; font.pixelSize: 54; anchors.horizontalCenter: parent.horizontalCenter }
                Label { text: "Your model preview"; color: Theme.textStrong; font.pixelSize: 17; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter }
                Label { text: "Choose an STL to inspect it in 3D."; color: muted; font.pixelSize: 13; anchors.horizontalCenter: parent.horizontalCenter }
            }

            Rectangle {
                id: plotPanel
                readonly property bool shown: openPlot !== ""
                anchors { left: parent.left; right: parent.right; margins: 12 }
                height: Math.max(220, parent.height * 0.44)
                y: shown ? parent.height - height - 12 : parent.height + 8
                Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                visible: y < parent.height
                radius: 12; color: Theme.panel; border.color: Theme.controlBorder
                // Keep clicks and drags on the plot from rotating the 3D view underneath.
                MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons; onWheel: wheel => wheel.accepted = true }
                LinePlot {
                    id: monitorPlot
                    // Keep showing the last plot while sliding out.
                    property string kind: "residuals"
                    anchors { fill: parent; margins: 14; rightMargin: 46 }
                    title: kind === "drag" ? "Drag coefficient" : kind === "lift" ? "Lift coefficient" : "Residuals"
                    logScale: kind === "residuals"
                    series: kind === "drag" ? simulation.dragHistory : kind === "lift" ? simulation.liftHistory : simulation.residuals
                    emptyText: kind === "residuals" ? "Residuals appear here once the solver starts."
                                                    : "Force coefficients appear here once the solver starts."
                }
                Connections {
                    target: window
                    function onOpenPlotChanged() { if (openPlot !== "") monitorPlot.kind = openPlot }
                }
                ToolButton {
                    anchors { right: parent.right; top: parent.top; margins: 8 }
                    text: "✕"
                    onClicked: openPlot = ""
                    contentItem: Text { text: parent.text; color: muted; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { radius: 6; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 30; implicitHeight: 30 }
                }
            }
        }

        // ---- Right: results and plot buttons ----
        Rectangle {
            Layout.preferredWidth: sideWidth; Layout.fillHeight: true
            radius: 14; color: panel; border.color: Theme.border
            clip: true // the window can be shorter than the content at its minimum size
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 14; spacing: 8
                Label { text: "RESULTS"; color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.6 }
                MetricCard { Layout.fillWidth: true; label: "DRAG COEFFICIENT"; value: formatCoefficient(simulation.dragCoefficient) }
                MetricCard { Layout.fillWidth: true; label: "LIFT COEFFICIENT"; value: formatCoefficient(simulation.liftCoefficient) }
                MetricCard { Layout.fillWidth: true; label: "CELLS"; value: simulation.cellCount > 0 ? simulation.cellCount.toLocaleString(Qt.locale(), "f", 0) : "—" }
                Item { Layout.preferredHeight: 6 }
                Label { text: "PLOTS"; color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.6 }
                Repeater {
                    model: [{ kind: "residuals", label: "Residuals", glyph: "∿" },
                            { kind: "drag", label: "Drag coefficient", glyph: "Cd" },
                            { kind: "lift", label: "Lift coefficient", glyph: "Cl" }]
                    delegate: Button {
                        required property var modelData
                        readonly property bool active: openPlot === modelData.kind
                        Layout.fillWidth: true
                        onClicked: openPlot = active ? "" : modelData.kind
                        contentItem: RowLayout {
                            spacing: 10
                            Label { text: modelData.glyph; color: accent; font.pixelSize: 13; font.bold: true; Layout.preferredWidth: 22; horizontalAlignment: Text.AlignHCenter }
                            Label { text: modelData.label; color: active ? accent : Theme.text; font.pixelSize: 13; Layout.fillWidth: true }
                            Label { text: active ? "▾" : "▸"; color: muted; font.pixelSize: 12 }
                        }
                        background: Rectangle { radius: 9; implicitHeight: 38; color: active ? Theme.selected : (parent.hovered ? Theme.controlHover : Theme.control); border.color: active ? accent : Theme.controlBorder }
                    }
                }
                Item { Layout.fillHeight: true }
            }
        }

        // ---- Bottom: OpenFOAM console (under setup and view) and status (under results) ----
        Rectangle {
            Layout.columnSpan: 2
            Layout.fillWidth: true; Layout.preferredHeight: 150
            radius: 12; color: Theme.consoleBackground; border.color: Theme.border
            Label { id: consoleTitle; text: "OPENFOAM LOG"; color: muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.6; x: 14; y: 10 }
            ScrollView {
                id: consoleScroll
                // Follow new output unless the user has scrolled up to read.
                property bool follow: true
                function scrollToEnd() { contentItem.contentY = Math.max(0, contentItem.contentHeight - contentItem.height) }
                anchors { fill: parent; topMargin: 26; leftMargin: 6; rightMargin: 6; bottomMargin: 6 }
                ScrollBar.vertical.onPressedChanged: if (!ScrollBar.vertical.pressed) follow = contentItem.atYEnd
                TextArea {
                    readOnly: true; text: simulation.log
                    color: Theme.text; font.family: "monospace"; font.pixelSize: 11
                    wrapMode: TextEdit.NoWrap; background: null; selectByMouse: true
                    onTextChanged: if (consoleScroll.follow) Qt.callLater(consoleScroll.scrollToEnd)
                }
                Connections {
                    target: consoleScroll.contentItem
                    function onMovementEnded() { consoleScroll.follow = consoleScroll.contentItem.atYEnd }
                }
            }
        }
        Rectangle {
            id: statusBox
            readonly property string status: simulation.status
            readonly property bool failed: status === "Failed" || status === "Needs attention" || status === "OpenFOAM unavailable"
            readonly property color tone: failed ? danger : simulation.running || status === "Complete" ? accent : muted
            Layout.preferredWidth: sideWidth; Layout.preferredHeight: 150
            radius: 12; color: panel; border.color: failed ? Theme.dangerBorder : Theme.border
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 16; spacing: 6
                Label { text: "STATUS"; color: muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.6 }
                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 10; height: 10; radius: 5; color: statusBox.tone
                        SequentialAnimation on opacity {
                            running: simulation.running; loops: Animation.Infinite
                            alwaysRunToEnd: true // finish the pulse at full opacity when the run ends
                            NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
                        }
                    }
                    Label { text: statusBox.status; color: Theme.textStrong; font.pixelSize: 17; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                }
                Label {
                    text: simulation.solver + (simulation.simulatedTime > 0 ? "  ·  t = " + Number(simulation.simulatedTime.toPrecision(4)) + " s" : "")
                    color: muted; font.pixelSize: 12
                }
                Item { Layout.fillHeight: true }
                Label {
                    visible: simulation.casePath.length > 0
                    text: simulation.casePath; color: Theme.faint; font.pixelSize: 10
                    elide: Text.ElideLeft; Layout.fillWidth: true
                }
            }
        }
    }
}
