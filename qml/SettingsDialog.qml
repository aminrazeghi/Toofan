import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// App settings: theme and contour palette.
Popup {
    id: root
    property bool darkTheme: true
    property string colorMap
    property var colorMaps: []   // VtkView.colorMaps()
    signal themeSelected(bool dark)
    signal colorMapSelected(string value)

    modal: true
    focus: true
    anchors.centerIn: Overlay.overlay
    width: 420
    padding: 22
    background: Rectangle { radius: 14; color: Theme.panel; border.color: Theme.border }
    Overlay.modal: Rectangle { color: "#80000000" }

    ColumnLayout {
        width: parent.width
        spacing: 14
        RowLayout {
            Label { text: "Settings"; color: Theme.textStrong; font.pixelSize: 18; font.bold: true; Layout.fillWidth: true }
            ToolButton {
                text: "✕"
                onClicked: root.close()
                contentItem: Text { text: parent.text; color: Theme.muted; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 6; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 30; implicitHeight: 30 }
            }
        }

        Label { text: "THEME"; color: Theme.muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.4 }
        SegmentedControl {
            options: [{ value: "dark", label: "Dark" }, { value: "light", label: "Light" }]
            current: root.darkTheme ? "dark" : "light"
            onActivated: value => root.themeSelected(value === "dark")
        }

        Label { text: "CONTOUR PALETTE"; color: Theme.muted; font.pixelSize: 11; font.bold: true; font.letterSpacing: 1.4; Layout.topMargin: 6 }
        Repeater {
            model: root.colorMaps
            delegate: Rectangle {
                required property var modelData
                readonly property bool selected: root.colorMap === modelData.value
                Layout.fillWidth: true
                implicitHeight: 44
                radius: 9
                color: selected ? Theme.selected : (hover.hovered ? Theme.controlHover : Theme.control)
                border.color: selected ? Theme.accent : Theme.controlBorder
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 12
                    Rectangle {
                        Layout.preferredWidth: 150; Layout.preferredHeight: 14; radius: 3
                        gradient: Gradient {
                            orientation: Gradient.Horizontal
                            GradientStop { position: 0.0; color: modelData.colors[0] }
                            GradientStop { position: 0.25; color: modelData.colors[1] }
                            GradientStop { position: 0.5; color: modelData.colors[2] }
                            GradientStop { position: 0.75; color: modelData.colors[3] }
                            GradientStop { position: 1.0; color: modelData.colors[4] }
                        }
                    }
                    Label { text: modelData.label; color: selected ? Theme.accent : Theme.text; font.pixelSize: 13; Layout.fillWidth: true }
                    Label { text: "✓"; visible: selected; color: Theme.accent; font.pixelSize: 14 }
                }
                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.colorMapSelected(modelData.value) }
            }
        }
    }
}
