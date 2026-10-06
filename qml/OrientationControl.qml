import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Rotate the model about x, y or z in fixed steps; shows the angle about each axis.
ColumnLayout {
    id: root
    property vector3d angles   // degrees about x, then y, then z
    property int step: 15
    signal rotate(int axis, real degrees)
    signal reset()
    spacing: 8

    RowLayout {
        Label { text: "Orientation"; color: Theme.textStrong; font.pixelSize: 14; font.bold: true; Layout.fillWidth: true }
        SegmentedControl {
            options: [{ value: "15", label: "15°" }, { value: "45", label: "45°" }, { value: "90", label: "90°" }]
            current: String(root.step)
            onActivated: value => root.step = Number(value)
        }
    }

    Repeater {
        // Colors match the axes marker in the 3D view (vtkAxesActor defaults).
        model: [{ name: "X", color: "#e05252" }, { name: "Y", color: "#d8c23a" }, { name: "Z", color: "#4cbf5a" }]
        delegate: RowLayout {
            required property var modelData
            required property int index
            readonly property real angle: index === 0 ? root.angles.x : index === 1 ? root.angles.y : root.angles.z
            spacing: 8
            Rectangle { width: 8; height: 8; radius: 4; color: modelData.color }
            Label { text: modelData.name; color: Theme.text; font.pixelSize: 13; font.bold: true; Layout.preferredWidth: 14 }
            component StepButton: Button {
                implicitWidth: 44; implicitHeight: 30
                contentItem: Text { text: parent.text; color: Theme.text; font.pixelSize: 13; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 7; color: parent.down ? Theme.selected : parent.hovered ? Theme.controlHover : Theme.control; border.color: Theme.controlBorder }
            }
            StepButton {
                text: "⟲ −"
                ToolTip.visible: hovered; ToolTip.text: "Rotate −" + root.step + "° about " + modelData.name
                onClicked: root.rotate(index, -root.step)
            }
            Rectangle {
                Layout.fillWidth: true; implicitHeight: 30; radius: 7
                color: Theme.field; border.color: angle !== 0 ? Theme.accent : Theme.controlBorder
                Label {
                    anchors.centerIn: parent
                    text: (angle > 0 ? "+" : "") + Math.round(angle) + "°"
                    color: angle !== 0 ? Theme.accent : Theme.muted
                    font.pixelSize: 13; font.bold: angle !== 0
                }
            }
            StepButton {
                text: "+ ⟳"
                ToolTip.visible: hovered; ToolTip.text: "Rotate +" + root.step + "° about " + modelData.name
                onClicked: root.rotate(index, root.step)
            }
        }
    }

    Button {
        Layout.alignment: Qt.AlignRight
        text: "Reset orientation"
        enabled: root.angles.x !== 0 || root.angles.y !== 0 || root.angles.z !== 0
        flat: true
        font.pixelSize: 12
        onClicked: root.reset()
    }
}
