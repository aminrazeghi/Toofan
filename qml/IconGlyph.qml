import QtQuick
import QtQuick.Shapes

// Small glyph drawn as vectors on a 14 × 14 grid, so it looks the same with every font:
// "first", "play", "pause", "last", "folder" or "plus".
Item {
    id: root
    property string kind: "play"
    property color color: Theme.textStrong
    implicitWidth: 14; implicitHeight: 14

    component Glyph: Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer
    }
    // Outline through points [[x, y], ...].
    component Outline: ShapePath {
        property var points: []
        strokeColor: root.color; strokeWidth: 1.5; fillColor: "transparent"
        joinStyle: ShapePath.RoundJoin; capStyle: ShapePath.RoundCap
        startX: points[0][0]; startY: points[0][1]
        PathPolyline { path: points.map(p => Qt.point(p[0], p[1])) }
    }
    // Filled polygon through points [[x, y], ...].
    component Polygon: ShapePath {
        property var points: []
        strokeColor: "transparent"; fillColor: root.color
        startX: points[0][0]; startY: points[0][1]
        PathPolyline { path: points.map(p => Qt.point(p[0], p[1])).concat([Qt.point(points[0][0], points[0][1])]) }
    }

    Glyph {
        visible: root.kind === "play"
        Polygon { points: [[3, 1], [13, 7], [3, 13]] }
    }
    Glyph {
        visible: root.kind === "pause"
        Polygon { points: [[3, 1.5], [5.5, 1.5], [5.5, 12.5], [3, 12.5]] }
        Polygon { points: [[8.5, 1.5], [11, 1.5], [11, 12.5], [8.5, 12.5]] }
    }
    Glyph {
        visible: root.kind === "first"
        Polygon { points: [[1.5, 1.5], [3.5, 1.5], [3.5, 12.5], [1.5, 12.5]] }
        Polygon { points: [[12.5, 1], [4, 7], [12.5, 13]] }
    }
    Glyph {
        visible: root.kind === "last"
        Polygon { points: [[10.5, 1.5], [12.5, 1.5], [12.5, 12.5], [10.5, 12.5]] }
        Polygon { points: [[1.5, 1], [10, 7], [1.5, 13]] }
    }
    Glyph {
        visible: root.kind === "folder"
        Outline { points: [[1, 3], [5.5, 3], [7, 4.5], [13, 4.5], [13, 12], [1, 12], [1, 3]] }
        Outline { points: [[1, 6.5], [13, 6.5]] }
    }
    Glyph {
        visible: root.kind === "plus"
        Outline { points: [[7, 1.5], [7, 12.5]] }
        Outline { points: [[1.5, 7], [12.5, 7]] }
    }
}
