import QtQuick

// Translucent card floating over the 3D view. It absorbs pointer input, so dragging or
// scrolling on the card does not move the camera underneath; controls inside still work.
Rectangle {
    radius: 14
    color: Theme.floating
    border.color: Theme.border

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.AllButtons
        onWheel: wheel => wheel.accepted = true
    }
}
