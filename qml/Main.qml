import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import WindTunnel

ApplicationWindow {
    width: 1280
    height: 820
    minimumWidth: 960
    minimumHeight: 640
    visible: true
    title: "Digital Wind Tunnel"
    color: "#0c1118"
    property color panel: "#111821"
    property color muted: "#8c9aab"
    property color accent: "#58d6bd"

    function formatCoefficient(value) {
        if (isNaN(value)) return "—"
        return Math.abs(value) >= 1e-3 || value === 0 ? value.toFixed(4) : value.toExponential(2)
    }

    header: ToolBar {
        background: Rectangle { color: "#0c1118"; border.color: "#202a36"; border.width: 1 }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 24; anchors.rightMargin: 24
            Label { text: "◈"; color: accent; font.pixelSize: 23 }
            Label { text: "FLOW / LAB"; color: "#f3f6f8"; font.bold: true; font.letterSpacing: 2 }
            Item { Layout.fillWidth: true }
            Rectangle {
                radius: 12; color: "#17231f"; implicitWidth: statusText.implicitWidth + 20; implicitHeight: 30
                Row { anchors.centerIn: parent; spacing: 8
                    Rectangle { width: 7; height: 7; radius: 4; color: accent; anchors.verticalCenter: parent.verticalCenter }
                    Label { id: statusText; text: simulation.status; color: "#b9d8d1"; font.pixelSize: 12 }
                }
            }
        }
    }

    FileDialog {
        id: stlDialog
        title: "Choose a model"
        nameFilters: ["STL models (*.stl)", "All files (*)"]
        onAccepted: simulation.stlPath = selectedFile
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 24
        spacing: 18
        RowLayout {
            Layout.fillWidth: true
            ColumnLayout { spacing: 3
                Label { text: "Your model, in the flow."; color: "#f1f4f8"; font.pixelSize: 27; font.weight: Font.DemiBold }
                Label { text: "Set up a run. We’ll take care of the tunnel."; color: muted; font.pixelSize: 14 }
            }
            Item { Layout.fillWidth: true }
            Button {
                text: "▶   Start simulation"
                enabled: !simulation.status.startsWith("Running ")
                onClicked: simulation.startSimulation()
                contentItem: Text { text: parent.text; color: "#071511"; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 9; color: parent.enabled ? accent : "#39534d"; implicitWidth: 190; implicitHeight: 44 }
            }
            Button { text: "Stop"; enabled: simulation.status.startsWith("Running "); onClicked: simulation.stopSimulation() }
        }

        RowLayout {
            Layout.fillWidth: true; Layout.fillHeight: true; spacing: 18
            Rectangle {
                Layout.preferredWidth: 330; Layout.fillHeight: true; radius: 16; color: panel; border.color: "#202a36"
                ColumnLayout {
                    anchors.fill: parent; anchors.margins: 20; spacing: 18
                    Label { text: "RUN SETUP"; color: muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.6 }
                    Label { text: "Model geometry"; color: "#e7edf3"; font.pixelSize: 14; font.bold: true }
                    Rectangle {
                        Layout.fillWidth: true; Layout.preferredHeight: 118; radius: 12
                        color: "#0d131b"; border.color: simulation.stlPath ? accent : "#334253"
                        Column { anchors.centerIn: parent; spacing: 8
                            Label { anchors.horizontalCenter: parent.horizontalCenter; text: "＋"; color: accent; font.pixelSize: 24 }
                            Label { anchors.horizontalCenter: parent.horizontalCenter; text: simulation.stlPath ? simulation.stlPath.split("/").pop() : "Drop an STL or browse"; color: "#d9e1e8"; font.pixelSize: 12; elide: Text.ElideMiddle; width: 270; horizontalAlignment: Text.AlignHCenter }
                        }
                        MouseArea { anchors.fill: parent; onClicked: stlDialog.open() }
                    }
                    Button { text: "Browse files"; Layout.fillWidth: true; onClicked: stlDialog.open() }
                    Rectangle { Layout.fillWidth: true; height: 1; color: "#27313d" }
                    Label { text: "Inlet speed"; color: "#e7edf3"; font.pixelSize: 14; font.bold: true }
                    RowLayout {
                        Layout.fillWidth: true
                        Slider { id: speedSlider; Layout.fillWidth: true; from: 1; to: 250; value: simulation.speed; onMoved: simulation.speed = value }
                        Label { text: Math.round(speedSlider.value) + " m/s"; color: "#f1f4f8"; font.pixelSize: 14; Layout.preferredWidth: 58 }
                    }
                    Label { text: "Selected solver  ·  " + simulation.solver; color: muted; font.pixelSize: 12 }
                    Rectangle { Layout.fillWidth: true; height: 1; color: "#27313d" }
                    Label { text: "Mesh resolution"; color: "#e7edf3"; font.pixelSize: 14; font.bold: true }
                    RowLayout {
                        Layout.fillWidth: true
                        Repeater {
                            model: ["Coarse", "Fine"]
                            delegate: Button {
                                required property string modelData
                                Layout.fillWidth: true; text: modelData
                                onClicked: simulation.meshQuality = modelData
                                background: Rectangle { radius: 8; color: simulation.meshQuality === modelData ? "#1f3633" : "#151b24"; border.color: simulation.meshQuality === modelData ? accent : "#283342" }
                                contentItem: Text { text: parent.text; color: simulation.meshQuality === modelData ? accent : muted; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter; padding: 8 }
                            }
                        }
                    }
                    Item { Layout.fillHeight: true }
                    Label { text: "Air properties and tunnel dimensions are currently defaults."; color: "#718093"; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true; Layout.fillHeight: true; spacing: 14
                TabBar {
                    id: tabs
                    background: Rectangle { color: "transparent" }
                    TabButton { text: "Flow field" }
                    TabButton { text: "Monitors" }
                }
                StackLayout {
                    currentIndex: tabs.currentIndex; Layout.fillWidth: true; Layout.fillHeight: true
                    Rectangle {
                        radius: 16; color: panel; border.color: "#202a36"
                        VtkView {
                            id: vtkView
                            anchors.fill: parent; anchors.margins: 1
                            stlFile: simulation.stlPath
                            casePath: simulation.casePath
                            previewRevision: simulation.previewRevision
                        }
                        Rectangle {
                            visible: vtkView.previewInfo.length > 0
                            anchors { left: parent.left; top: parent.top; margins: 14 }
                            radius: 8; color: "#cc0d131b"; border.color: "#283342"
                            implicitWidth: previewLabel.implicitWidth + 20; implicitHeight: previewLabel.implicitHeight + 12
                            Label { id: previewLabel; anchors.centerIn: parent; text: vtkView.previewInfo; color: "#d9e1e8"; font.pixelSize: 12 }
                        }
                        Column {
                            anchors.centerIn: parent; spacing: 12
                            visible: simulation.stlPath.length === 0
                            Label { text: "◌"; color: "#3b776e"; font.pixelSize: 54; anchors.horizontalCenter: parent.horizontalCenter }
                            Label { text: "Your model preview"; color: "#dce4ea"; font.pixelSize: 17; font.bold: true; anchors.horizontalCenter: parent.horizontalCenter }
                            Label { text: "Choose an STL to inspect it in 3D."; color: muted; font.pixelSize: 13; anchors.horizontalCenter: parent.horizontalCenter }
                        }
                    }
                    ColumnLayout {
                        spacing: 14
                        RowLayout {
                            Layout.fillWidth: true
                            MetricCard { Layout.fillWidth: true; label: "DRAG COEFFICIENT"; value: formatCoefficient(simulation.dragCoefficient) }
                            MetricCard { Layout.fillWidth: true; label: "LIFT COEFFICIENT"; value: formatCoefficient(simulation.liftCoefficient) }
                            MetricCard { Layout.fillWidth: true; label: "CELLS"; value: simulation.cellCount > 0 ? simulation.cellCount.toLocaleString(Qt.locale(), "f", 0) : "—" }
                        }
                        Rectangle {
                            Layout.fillWidth: true; Layout.fillHeight: true; radius: 16; color: panel; border.color: "#202a36"
                            ResidualPlot { anchors.fill: parent; anchors.margins: 16; series: simulation.residuals }
                        }
                        Rectangle {
                            Layout.fillWidth: true; Layout.preferredHeight: 110; radius: 12; color: "#0a0f15"; border.color: "#202a36"
                            ScrollView { anchors.fill: parent; anchors.margins: 10
                                TextArea { readOnly: true; text: simulation.log; color: "#b6c5d1"; font.family: "monospace"; font.pixelSize: 11; wrapMode: TextEdit.NoWrap; background: null }
                            }
                        }
                    }
                }
            }
        }
    }
}
