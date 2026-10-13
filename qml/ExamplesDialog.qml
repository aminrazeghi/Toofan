import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Ready-made cases bundled with the app; choosing one starts a new project from it.
Popup {
    id: root
    property var examples: []   // SimulationController.examples
    property bool busy: false   // a run is in progress: examples cannot be opened
    signal exampleSelected(string id)

    modal: true
    focus: true
    anchors.centerIn: Overlay.overlay
    width: 480
    padding: 22
    background: Rectangle { radius: 14; color: Theme.panel; border.color: Theme.border }
    Overlay.modal: Rectangle { color: "#80000000"; radius: Theme.windowRadius }

    ColumnLayout {
        width: parent.width
        spacing: 12
        RowLayout {
            Label { text: "Examples"; color: Theme.textStrong; font.pixelSize: 18; font.bold: true; Layout.fillWidth: true }
            ToolButton {
                text: "✕"
                onClicked: root.close()
                contentItem: Text { text: parent.text; color: Theme.muted; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 6; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 30; implicitHeight: 30 }
            }
        }
        Label {
            Layout.fillWidth: true
            text: root.busy ? "Stop the running simulation to open an example."
                            : "Opens the example's model and settings as a new project; change anything before starting it."
            color: root.busy ? Theme.danger : Theme.faint; font.pixelSize: 11; wrapMode: Text.WordWrap
        }
        Repeater {
            model: root.examples
            delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: card.implicitHeight + 24
                radius: 9
                opacity: root.busy ? 0.5 : 1
                color: hover.hovered && !root.busy ? Theme.controlHover : Theme.control
                border.color: hover.hovered && !root.busy ? Theme.accent : Theme.controlBorder
                ColumnLayout {
                    id: card
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; margins: 14 }
                    spacing: 4
                    Label { text: modelData.title; color: Theme.textStrong; font.pixelSize: 14; font.bold: true; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                    Label { text: modelData.description; color: Theme.text; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                }
                HoverHandler { id: hover; cursorShape: root.busy ? Qt.ArrowCursor : Qt.PointingHandCursor }
                TapHandler {
                    enabled: !root.busy
                    onTapped: { root.exampleSelected(modelData.id); root.close() }
                }
            }
        }
    }
}
