import QtQuick
import QtQuick.Controls
import QtQuick.Effects

// Row of mutually exclusive options, styled like the run setup buttons.
Rectangle {
    id: root
    // [{value, label}], or [{value, icon, tip}] for icon buttons: icon is a white-on-transparent
    // SVG, drawn in the theme's text or accent color; tip is shown on hover.
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
                readonly property color foreground: selected ? Theme.accent : Theme.text
                implicitWidth: modelData.icon ? 34 : label.implicitWidth + 18
                implicitHeight: label.implicitHeight + 10 // same height for icon and text buttons
                Label {
                    id: label
                    anchors.centerIn: parent
                    visible: !modelData.icon
                    text: modelData.label ?? ""
                    color: parent.foreground
                    font.pixelSize: 12
                }
                Image {
                    id: icon
                    anchors.centerIn: parent
                    visible: false // drawn through the effect below
                    source: modelData.icon ?? ""
                    sourceSize: Qt.size(18, 18)
                }
                MultiEffect {
                    anchors.fill: icon
                    visible: !!modelData.icon
                    source: icon
                    colorization: 1
                    colorizationColor: parent.foreground
                }
                ToolTip.visible: !!modelData.tip && hover.hovered
                ToolTip.text: modelData.tip ?? ""
                ToolTip.delay: 500
                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.activated(modelData.value) }
            }
        }
    }
}
