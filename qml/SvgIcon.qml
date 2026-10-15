import QtQuick
import QtQuick.Effects

// White-on-transparent SVG drawn in `color`, so one file serves every theme and state.
Item {
    id: root
    property url source
    property color color: Theme.text
    property int size: 18
    implicitWidth: size; implicitHeight: size

    Image {
        id: image
        anchors.fill: parent
        visible: false // drawn through the effect below
        source: root.source
        sourceSize: Qt.size(root.size, root.size)
    }
    MultiEffect {
        anchors.fill: parent
        source: image
        colorization: 1
        colorizationColor: root.color
    }
}
