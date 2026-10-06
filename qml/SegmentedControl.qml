import QtQuick
import QtQuick.Controls

// Row of mutually exclusive options, styled like the run setup buttons.
Rectangle {
    id: root
    // [{value, label}]
    property var options: []
    property string current
    signal activated(string value)

    radius: 9
    color: Theme.overlay
    border.color: Theme.controlBorder
    implicitWidth: row.implicitWidth + 8
    implicitHeight: row.implicitHeight + 8

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 2
        Repeater {
            model: root.options
            delegate: Rectangle {
                required property var modelData
                readonly property bool selected: root.current === modelData.value
                radius: 6
                color: selected ? Theme.selected : (hover.hovered ? Theme.controlHover : "transparent")
                border.color: selected ? Theme.accent : "transparent"
                implicitWidth: label.implicitWidth + 18
                implicitHeight: label.implicitHeight + 10
                Label {
                    id: label
                    anchors.centerIn: parent
                    text: modelData.label
                    color: parent.selected ? Theme.accent : Theme.text
                    font.pixelSize: 12
                }
                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.activated(modelData.value) }
            }
        }
    }
}
