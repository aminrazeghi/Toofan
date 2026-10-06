import QtQuick
import QtQuick.Controls

Rectangle {
    required property string label
    required property string value
    radius: 14
    color: "#151b24"
    border.color: "#283342"
    implicitHeight: 84
    Column {
        anchors.fill: parent
        anchors.margins: 14
        spacing: 7
        Label { text: label; color: "#8c9aab"; font.pixelSize: 12 }
        Label { text: value; color: "#f2f5f8"; font.pixelSize: 19; font.weight: Font.DemiBold }
    }
}
