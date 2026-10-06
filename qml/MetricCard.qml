import QtQuick
import QtQuick.Controls

Rectangle {
    required property string label
    required property string value
    radius: 14
    color: Theme.control
    border.color: Theme.controlBorder
    implicitHeight: 66
    Column {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 4
        Label { text: label; color: Theme.muted; font.pixelSize: 12 }
        Label { text: value; color: Theme.textStrong; font.pixelSize: 18; font.weight: Font.DemiBold }
    }
}
