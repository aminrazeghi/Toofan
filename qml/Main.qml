import QtCore
import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Effects
import QtQuick.Layouts
import WindTunnel

ApplicationWindow {
    id: window
    width: 1440
    height: 900
    minimumWidth: 1100
    minimumHeight: 700
    visible: true
    title: "Toofan CFD"
    // Frameless: the floating top bars move the window and hold its controls.
    flags: Qt.Window | Qt.FramelessWindowHint
    color: "transparent" // outside the rounded corners
    readonly property bool maximized: visibility === Window.Maximized || visibility === Window.FullScreen
    readonly property int cornerRadius: maximized ? 0 : 12
    function toggleMaximized() { if (maximized) showNormal(); else showMaximized() }
    Binding { target: Theme; property: "windowRadius"; value: window.cornerRadius }
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
    // Floating layout: distance from the window edge and between panels.
    readonly property int edge: 14
    readonly property int gap: 12
    readonly property int sideWidth: 250

    function formatCoefficient(value) {
        if (isNaN(value)) return "—"
        return Math.abs(value) >= 1e-3 || value === 0 ? value.toFixed(4) : value.toExponential(2)
    }

    AboutDialog {
        id: aboutDialog
        info: appInfo
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

    // Drag to move the window, double-click to maximize/restore.
    component WindowDragArea: Item {
        DragHandler { target: null; onActiveChanged: if (active) window.startSystemMove() }
        TapHandler { onDoubleTapped: window.toggleMaximized() }
    }
    // Minimal title-bar button; the glyph is drawn so it looks the same with every font.
    component WindowButton: ToolButton {
        id: wb
        property string glyph   // minimize, maximize, restore or close
        property string tip
        property bool closeButton: false
        ToolTip.visible: hovered; ToolTip.text: tip; ToolTip.delay: 600
        background: Rectangle {
            radius: 9; implicitWidth: 38; implicitHeight: 38
            color: wb.hovered ? (wb.closeButton ? Theme.danger : Theme.controlHover) : "transparent"
        }
        contentItem: Item {
            readonly property color ink: wb.hovered && wb.closeButton ? "#ffffff" : Theme.text
            Rectangle { visible: wb.glyph === "minimize"; anchors.centerIn: parent; width: 12; height: 1.5; color: parent.ink }
            Rectangle {
                visible: wb.glyph === "maximize" || wb.glyph === "restore"
                anchors.centerIn: parent
                anchors.horizontalCenterOffset: wb.glyph === "restore" ? -1.5 : 0
                anchors.verticalCenterOffset: wb.glyph === "restore" ? 1.5 : 0
                width: wb.glyph === "restore" ? 9 : 11; height: width; radius: 2
                color: "transparent"; border.color: parent.ink; border.width: 1.5
            }
            Rectangle {   // back square of the restore glyph
                visible: wb.glyph === "restore"
                anchors.centerIn: parent; anchors.horizontalCenterOffset: 1.5; anchors.verticalCenterOffset: -1.5
                width: 9; height: 9; radius: 2; z: -1
                color: "transparent"; border.color: parent.ink; border.width: 1.5
            }
            Repeater {
                model: wb.glyph === "close" ? [45, -45] : []
                Rectangle { anchors.centerIn: parent; width: 13; height: 1.5; rotation: modelData; color: parent.ink; antialiasing: true }
            }
        }
    }

    // Everything is drawn inside a frame clipped to rounded corners (square when maximized).
    Item {
        id: frameMask
        anchors.fill: parent
        visible: false
        layer.enabled: true
        Rectangle { anchors.fill: parent; radius: window.cornerRadius; color: "black"; antialiasing: true }
    }
    Item {
        id: frame
        anchors.fill: parent
        layer.enabled: window.cornerRadius > 0
        layer.effect: MultiEffect {
            maskEnabled: true
            maskSource: frameMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
        Rectangle { anchors.fill: parent; color: Theme.window } // until the 3D view has drawn

        // ---- The 3D view fills the window; everything else floats over it ----
        VtkView {
            id: vtkView
            anchors.fill: parent
            stlFile: simulation.stlPath
            casePath: simulation.casePath
            previewRevision: simulation.previewRevision
            modelRotation: simulation.modelRotation
            colorMap: appSettings.colorMap
            darkTheme: Theme.dark
            // Covered window edges, from the panels' resting sizes (not their animations).
            viewInsets: Qt.vector4d(edge + (setupPanel.collapsed ? 52 : 320) + gap,
                                    edge + brandBar.height + gap,
                                    edge + sideWidth + gap,
                                    edge + (consolePanel.expanded ? 170 : 40) + gap
                                        + (plotPanel.shown ? plotPanel.height + gap : 0))
        }

        Column {
            anchors.centerIn: parent; spacing: 12
            visible: simulation.stlPath.length === 0
            Label { text: "◌"; color: Theme.accent; font.pixelSize: 54; anchors.horizontalCenter: parent.horizontalCenter }
            Label { text: "Your model preview"; color: Theme.textStrong; font.pixelSize: 17; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter }
            Label { text: "Choose an STL to inspect it in 3D."; color: muted; font.pixelSize: 13; anchors.horizontalCenter: parent.horizontalCenter }
        }

        // ---- Top left: app icon (opens About) and name ----
        FloatingPanel {
            id: brandBar
            x: edge; y: edge
            height: 52
            width: brandRow.implicitWidth + 24
            WindowDragArea { anchors.fill: parent }
            RowLayout {
                id: brandRow
                anchors.centerIn: parent
                spacing: 10
                Rectangle {
                    implicitWidth: 38; implicitHeight: 38; radius: 9
                    color: iconHover.hovered ? Theme.controlHover : "transparent"
                    Image {
                        anchors.centerIn: parent
                        width: 30; height: 30
                        source: "qrc:/assets/toofan-cfd-icon.svg"
                        sourceSize: Qt.size(60, 60)
                    }
                    HoverHandler { id: iconHover; cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: aboutDialog.open() }
                    ToolTip.visible: iconHover.hovered; ToolTip.text: "About Toofan CFD"
                }
                Label { text: "Toofan CFD"; color: Theme.textStrong; font.bold: true; font.letterSpacing: 2; rightPadding: 6 }
            }
        }

        // ---- Top right: settings, start and stop ----
        FloatingPanel {
            id: actionBar
            anchors { right: parent.right; top: parent.top; margins: edge }
            height: 52
            width: actionRow.implicitWidth + 16
            WindowDragArea { anchors.fill: parent }
            RowLayout {
                id: actionRow
                anchors.centerIn: parent
                spacing: 8
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
                Rectangle { implicitWidth: 1; implicitHeight: 24; color: Theme.divider; Layout.leftMargin: 4; Layout.rightMargin: 4 }
                WindowButton { glyph: "minimize"; tip: "Minimize"; onClicked: window.showMinimized() }
                WindowButton { glyph: window.maximized ? "restore" : "maximize"; tip: window.maximized ? "Restore" : "Maximize"; onClicked: window.toggleMaximized() }
                WindowButton { glyph: "close"; tip: "Close"; closeButton: true; onClicked: window.close() }
            }
        }

        // ---- Left: run setup. Locked and collapsed while a run is in progress; collapsible by hand otherwise. ----
        FloatingPanel {
            id: setupPanel
            property bool userCollapsed: false
            readonly property bool collapsed: simulation.running || userCollapsed
            x: edge
            anchors { top: brandBar.bottom; topMargin: gap; bottom: consolePanel.top; bottomMargin: gap }
            width: collapsed ? 52 : 320
            clip: true
            Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.InOutCubic } }

            // Collapsed strip: what the case is set up with. Click to expand (when not running).
            Item {
                anchors.fill: parent
                visible: setupPanel.collapsed
                HoverHandler { enabled: !simulation.running; cursorShape: Qt.PointingHandCursor }
                TapHandler { enabled: !simulation.running; onTapped: setupPanel.userCollapsed = false }
            }
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
                readonly property vector3d r: simulation.modelRotation
                text: (simulation.running ? "" : "›  ") + "RUN SETUP  ·  " + (simulation.stlPath ? simulation.stlPath.split("/").pop() : "no model")
                      + (r.x || r.y || r.z ? "  ·  rot " + Math.round(r.x) + "/" + Math.round(r.y) + "/" + Math.round(r.z) + "°" : "")
                      + "  ·  " + Math.round(simulation.speed) + " m/s  ·  " + simulation.meshQuality
                color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.2
            }

            ColumnLayout {
                x: setupPanel.collapsed ? -width - 20 : 18
                Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.InOutCubic } }
                y: 16; width: 284; height: parent.height - 32; spacing: 14
                enabled: !setupPanel.collapsed
                opacity: setupPanel.collapsed ? 0.35 : 1
                Behavior on opacity { NumberAnimation { duration: 240 } }
                RowLayout {
                    spacing: 6
                    Label { text: "RUN SETUP"; color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.6; Layout.fillWidth: true }
                    SegmentedControl {
                        options: [{ value: "0", label: "Basic" }, { value: "1", label: "Advanced" }]
                        current: String(setupPages.currentIndex)
                        onActivated: value => setupPages.currentIndex = Number(value)
                    }
                    ToolButton {
                        text: "‹"
                        ToolTip.visible: hovered; ToolTip.text: "Hide run setup"
                        onClicked: setupPanel.userCollapsed = true
                        contentItem: Text { text: parent.text; color: Theme.muted; font.pixelSize: 20; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 7; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 28; implicitHeight: 28 }
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
                                Layout.fillWidth: true; Layout.preferredHeight: 96; radius: 12
                                color: Theme.field; border.color: simulation.stlPath ? accent : Theme.controlBorder
                                Column { anchors.centerIn: parent; spacing: 8
                                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: "＋"; color: accent; font.pixelSize: 24 }
                                    Label { anchors.horizontalCenter: parent.horizontalCenter; text: simulation.stlPath ? simulation.stlPath.split("/").pop() : "Drop an STL or browse"; color: Theme.text; font.pixelSize: 12; elide: Text.ElideMiddle; width: basicScroll.availableWidth - 30; horizontalAlignment: Text.AlignHCenter }
                                }
                                MouseArea { anchors.fill: parent; onClicked: stlDialog.open() }
                            }
                            Button { text: "Browse files"; Layout.fillWidth: true; onClicked: stlDialog.open() }
                            OrientationControl {
                                Layout.fillWidth: true
                                enabled: simulation.stlPath.length > 0
                                opacity: enabled ? 1 : 0.5
                                angles: simulation.modelRotation
                                onRotate: (axis, degrees) => simulation.rotateModel(axis, degrees)
                                onReset: simulation.resetModelRotation()
                            }
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

        // ---- Right: results and plot buttons, sized to their content ----
        FloatingPanel {
            id: resultsPanel
            property bool userCollapsed: false
            anchors { right: parent.right; rightMargin: edge; top: actionBar.bottom; topMargin: gap }
            width: sideWidth
            // Never taller than the space above the status card.
            height: Math.min(resultsColumn.implicitHeight + 28, statusPanel.y - gap - y)
            clip: true
            Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            ColumnLayout {
                id: resultsColumn
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
                spacing: 8
                RowLayout {
                    Label { text: "RESULTS"; color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.6; Layout.fillWidth: true }
                    ToolButton {
                        text: resultsPanel.userCollapsed ? "▾" : "▴"
                        ToolTip.visible: hovered; ToolTip.text: resultsPanel.userCollapsed ? "Show results" : "Hide results"
                        onClicked: resultsPanel.userCollapsed = !resultsPanel.userCollapsed
                        contentItem: Text { text: parent.text; color: Theme.muted; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                        background: Rectangle { radius: 7; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 26; implicitHeight: 24 }
                    }
                }
                ColumnLayout {
                    visible: !resultsPanel.userCollapsed
                    Layout.fillWidth: true
                    spacing: 8
                    MetricCard { Layout.fillWidth: true; label: "DRAG COEFFICIENT"; value: formatCoefficient(simulation.dragCoefficient) }
                    MetricCard { Layout.fillWidth: true; label: "LIFT COEFFICIENT"; value: formatCoefficient(simulation.liftCoefficient) }
                    MetricCard { Layout.fillWidth: true; label: "CELLS"; value: simulation.cellCount > 0 ? simulation.cellCount.toLocaleString(Qt.locale(), "f", 0) : "—" }
                    Item { Layout.preferredHeight: 4 }
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
                }
            }
        }

        // ---- View controls and info, in the gap between the side panels ----
        Rectangle {
            visible: vtkView.previewInfo.length > 0 || vtkView.loading
            x: Math.max(setupPanel.x + setupPanel.width, brandBar.x + brandBar.width) + gap
            anchors.verticalCenter: brandBar.verticalCenter
            radius: 8; color: Theme.overlay; border.color: Theme.controlBorder
            implicitWidth: previewLabel.implicitWidth + 20; implicitHeight: previewLabel.implicitHeight + 12
            Label { id: previewLabel; anchors.centerIn: parent; text: vtkView.previewInfo + (vtkView.loading ? (vtkView.previewInfo ? "  ·  " : "") + "Updating…" : ""); color: Theme.text; font.pixelSize: 12 }
        }
        Column {
            visible: simulation.previewRevision > 0
            anchors { right: resultsPanel.left; rightMargin: gap; top: resultsPanel.top }
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

        // ---- Plot, sliding up between the side panels above the console ----
        FloatingPanel {
            id: plotPanel
            readonly property bool shown: openPlot !== ""
            x: setupPanel.x + setupPanel.width + gap
            width: resultsPanel.x - gap - x
            height: Math.max(220, window.height * 0.4)
            y: shown ? consolePanel.y - gap - height : window.height + 8
            Behavior on y { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
            visible: y < window.height
            color: Theme.panel // opaque: plots must stay readable over any field colors
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

        // ---- Bottom: OpenFOAM console, collapsible to a one-line bar ----
        FloatingPanel {
            id: consolePanel
            property bool expanded: true
            anchors { left: parent.left; bottom: parent.bottom; margins: edge; right: statusPanel.left; rightMargin: gap }
            height: expanded ? 170 : 40
            Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
            radius: 12
            color: Qt.rgba(Theme.consoleBackground.r, Theme.consoleBackground.g, Theme.consoleBackground.b, 0.92)
            clip: true
            RowLayout {
                id: consoleHeader
                anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 14; rightMargin: 6; topMargin: 6 }
                height: 28
                spacing: 12
                Label { text: "OPENFOAM LOG"; color: muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.6 }
                Label {
                    // Latest line, so the collapsed bar still shows progress.
                    visible: !consolePanel.expanded
                    Layout.fillWidth: true
                    text: { const lines = simulation.log.trim().split("\n"); return lines[lines.length - 1] }
                    color: Theme.text; font.family: "monospace"; font.pixelSize: 11; elide: Text.ElideRight
                }
                Item { Layout.fillWidth: consolePanel.expanded }
                ToolButton {
                    text: consolePanel.expanded ? "▾" : "▴"
                    ToolTip.visible: hovered; ToolTip.text: consolePanel.expanded ? "Collapse log" : "Expand log"
                    onClicked: {
                        consolePanel.expanded = !consolePanel.expanded
                        if (consolePanel.expanded) consoleScroll.follow = true // reopen at the newest lines
                    }
                    contentItem: Text { text: parent.text; color: Theme.muted; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                    background: Rectangle { radius: 7; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 28; implicitHeight: 24 }
                }
            }
            ScrollView {
                id: consoleScroll
                visible: consolePanel.height > 60
                // Follow new output unless the user has scrolled up to read; then keep their place.
                property bool follow: true
                property real heldY: 0
                function scrollToEnd() { contentItem.contentY = Math.max(0, contentItem.contentHeight - contentItem.height) }
                function holdPosition() { contentItem.contentY = Math.min(heldY, Math.max(0, contentItem.contentHeight - contentItem.height)) }
                // Re-scroll as the panel expands; the viewport height is only final once the animation settles.
                onHeightChanged: if (follow) scrollToEnd()
                onVisibleChanged: if (visible && follow) scrollToEnd()
                anchors { left: parent.left; right: parent.right; top: consoleHeader.bottom; bottom: parent.bottom; leftMargin: 6; rightMargin: 6; bottomMargin: 6 }
                ScrollBar.vertical.onPressedChanged: if (!ScrollBar.vertical.pressed) { follow = contentItem.atYEnd; heldY = contentItem.contentY }
                TextArea {
                    readOnly: true; text: simulation.log
                    color: Theme.text; font.family: "monospace"; font.pixelSize: 11
                    wrapMode: TextEdit.NoWrap; background: null; selectByMouse: true
                    // Replacing the text resets the cursor to 0 and scrolls to it, after this handler runs.
                    // Keep the cursor at the end while following, and scroll (or restore) once that is done.
                    onTextChanged: {
                        if (consoleScroll.follow) {
                            cursorPosition = length
                            Qt.callLater(consoleScroll.scrollToEnd)
                        } else {
                            Qt.callLater(consoleScroll.holdPosition)
                        }
                    }
                }
                Connections {
                    target: consoleScroll.contentItem
                    function onMovementEnded() {
                        consoleScroll.follow = consoleScroll.contentItem.atYEnd
                        consoleScroll.heldY = consoleScroll.contentItem.contentY
                    }
                }
            }
        }

        // ---- Bottom right: status ----
        FloatingPanel {
            id: statusPanel
            readonly property string status: simulation.status
            readonly property bool failed: status === "Failed" || status === "Needs attention" || status === "OpenFOAM unavailable"
            readonly property color tone: failed ? danger : simulation.running || status === "Complete" ? accent : muted
            anchors { right: parent.right; bottom: parent.bottom; margins: edge }
            width: sideWidth
            height: statusColumn.implicitHeight + 28
            radius: 12
            border.color: failed ? Theme.dangerBorder : Theme.border
            ColumnLayout {
                id: statusColumn
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: 14 }
                spacing: 6
                Label { text: "STATUS"; color: muted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.6 }
                RowLayout {
                    spacing: 10
                    Rectangle {
                        width: 10; height: 10; radius: 5; color: statusPanel.tone
                        SequentialAnimation on opacity {
                            running: simulation.running; loops: Animation.Infinite
                            alwaysRunToEnd: true // finish the pulse at full opacity when the run ends
                            NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
                        }
                    }
                    Label { text: statusPanel.status; color: Theme.textStrong; font.pixelSize: 16; font.weight: Font.DemiBold; elide: Text.ElideRight; Layout.fillWidth: true }
                }
                Label {
                    text: simulation.solver + (simulation.simulatedTime > 0 ? "  ·  t = " + Number(simulation.simulatedTime.toPrecision(4)) + " s" : "")
                    color: muted; font.pixelSize: 12
                }
                Label {
                    visible: simulation.casePath.length > 0
                    text: simulation.casePath; color: Theme.faint; font.pixelSize: 10
                    elide: Text.ElideLeft; Layout.fillWidth: true
                }
            }
        }

        // Hairline edge so the window reads as an object on any desktop.
        Rectangle {
            anchors.fill: parent
            visible: window.cornerRadius > 0
            radius: window.cornerRadius
            color: "transparent"
            border.color: Theme.border
        }
    }

    // ---- Resize handles along the edges and corners (frameless windows have none) ----
    Repeater {
        model: [
            { edges: Qt.LeftEdge, cursor: Qt.SizeHorCursor }, { edges: Qt.RightEdge, cursor: Qt.SizeHorCursor },
            { edges: Qt.TopEdge, cursor: Qt.SizeVerCursor }, { edges: Qt.BottomEdge, cursor: Qt.SizeVerCursor },
            { edges: Qt.TopEdge | Qt.LeftEdge, cursor: Qt.SizeFDiagCursor }, { edges: Qt.BottomEdge | Qt.RightEdge, cursor: Qt.SizeFDiagCursor },
            { edges: Qt.TopEdge | Qt.RightEdge, cursor: Qt.SizeBDiagCursor }, { edges: Qt.BottomEdge | Qt.LeftEdge, cursor: Qt.SizeBDiagCursor }
        ]
        delegate: Item {
            required property var modelData
            readonly property int grip: 6
            readonly property bool atLeft: modelData.edges & Qt.LeftEdge
            readonly property bool atRight: modelData.edges & Qt.RightEdge
            readonly property bool atTop: modelData.edges & Qt.TopEdge
            readonly property bool atBottom: modelData.edges & Qt.BottomEdge
            visible: !window.maximized
            z: 100
            x: atRight ? window.width - (atTop || atBottom ? 3 * grip : grip) : 0
            y: atBottom ? window.height - (atLeft || atRight ? 3 * grip : grip) : 0
            width: atLeft || atRight ? (atTop || atBottom ? 3 * grip : grip) : window.width
            height: atTop || atBottom ? (atLeft || atRight ? 3 * grip : grip) : window.height
            HoverHandler { cursorShape: modelData.cursor }
            DragHandler { target: null; onActiveChanged: if (active) window.startSystemResize(modelData.edges) }
        }
    }
}
