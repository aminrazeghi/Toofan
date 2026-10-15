import QtQuick
import QtQuick.Controls
import QtQuick.Shapes

// The x, y and z axes as the 3D view's camera sees them. Clicking an axis end looks at the model
// from that side; the home button goes back to the default view.
Item {
    id: root
    property vector3d viewDirection: Qt.vector3d(0, 1, 0)  // camera to focal point (VtkView.viewDirection)
    property vector3d viewUp: Qt.vector3d(0, 0, 1)
    signal axisClicked(vector3d axis)
    signal homeClicked()

    implicitWidth: 144; implicitHeight: 144
    readonly property real ballRadius: 13
    readonly property real armLength: Math.min(width, height) / 2 - ballRadius - 2
    readonly property vector3d screenRight: viewDirection.crossProduct(viewUp).normalized()
    readonly property vector3d screenUp: screenRight.crossProduct(viewDirection).normalized() // viewUp, made perpendicular
    readonly property point centre: Qt.point(width / 2, height / 2)
    // Where an axis end is drawn.
    function project(axis) {
        return Qt.point(centre.x + armLength * axis.dotProduct(screenRight), centre.y - armLength * axis.dotProduct(screenUp))
    }
    // Same colors as the axes marker in the 3D view.
    readonly property var ends: [
        { label: "X", axis: Qt.vector3d(1, 0, 0), color: "#e5544f" },
        { label: "Y", axis: Qt.vector3d(0, 1, 0), color: "#4db55c" },
        { label: "Z", axis: Qt.vector3d(0, 0, 1), color: "#5478f5" },
        { label: "-X", axis: Qt.vector3d(-1, 0, 0), color: "#e5544f" },
        { label: "-Y", axis: Qt.vector3d(0, -1, 0), color: "#4db55c" },
        { label: "-Z", axis: Qt.vector3d(0, 0, -1), color: "#5478f5" }
    ]

    Rectangle {
        anchors.centerIn: parent
        width: 2 * (root.armLength + root.ballRadius) + 6; height: width; radius: width / 2
        color: Theme.overlay; opacity: 0.55
    }

    // Arms to the positive ends, under every ball.
    Shape {
        anchors.fill: parent
        z: -10
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: root.ends[0].color; strokeWidth: 2; capStyle: ShapePath.RoundCap
            startX: root.centre.x; startY: root.centre.y
            PathLine { x: root.project(root.ends[0].axis).x; y: root.project(root.ends[0].axis).y }
        }
        ShapePath {
            strokeColor: root.ends[1].color; strokeWidth: 2; capStyle: ShapePath.RoundCap
            startX: root.centre.x; startY: root.centre.y
            PathLine { x: root.project(root.ends[1].axis).x; y: root.project(root.ends[1].axis).y }
        }
        ShapePath {
            strokeColor: root.ends[2].color; strokeWidth: 2; capStyle: ShapePath.RoundCap
            startX: root.centre.x; startY: root.centre.y
            PathLine { x: root.project(root.ends[2].axis).x; y: root.project(root.ends[2].axis).y }
        }
    }

    Repeater {
        model: root.ends
        delegate: Rectangle {
            id: ball
            required property var modelData
            readonly property bool negative: modelData.label.startsWith("-")
            readonly property color axisColor: modelData.color
            readonly property point at: root.project(modelData.axis)
            readonly property bool active: hover.hovered
            x: at.x - width / 2; y: at.y - height / 2
            // Ends pointing at the viewer are drawn on top.
            z: -modelData.axis.dotProduct(root.viewDirection)
            width: 2 * root.ballRadius; height: width; radius: width / 2
            color: active ? axisColor : Theme.panel
            border.width: 2
            border.color: negative && !active ? Qt.rgba(axisColor.r, axisColor.g, axisColor.b, 0.5) : axisColor
            Label {
                anchors.centerIn: parent
                text: ball.modelData.label
                color: ball.active ? "#ffffff"
                     : ball.negative ? Qt.rgba(ball.axisColor.r, ball.axisColor.g, ball.axisColor.b, 0.6) : ball.axisColor
                font.pixelSize: ball.negative ? 10 : 12; font.bold: true
            }
            HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.axisClicked(ball.modelData.axis) }
            ToolTip.visible: hover.hovered; ToolTip.delay: 500
            ToolTip.text: "View from " + (ball.negative ? "" : "+") + ball.modelData.label
        }
    }

    ToolButton {
        id: home
        anchors { left: parent.left; top: parent.top }
        ToolTip.visible: hovered; ToolTip.text: "Reset view"; ToolTip.delay: 500
        onClicked: root.homeClicked()
        contentItem: Item { IconGlyph { anchors.centerIn: parent; kind: "home"; color: home.hovered ? Theme.accent : Theme.text } }
        background: Rectangle {
            radius: 8; implicitWidth: 30; implicitHeight: 30
            color: parent.hovered ? Theme.controlHover : Theme.overlay; border.color: Theme.controlBorder
        }
    }
}
