import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Version, author, repository and logo.
Popup {
    id: root
    property var info: ({})   // appInfo from main.cpp: Qt and VTK versions
    readonly property string version: "0.1.2"
    readonly property string author: "amin razeghiyadaki"
    readonly property string repositoryUrl: "https://github.com/aminrazeghi/Toofan"

    modal: true
    focus: true
    anchors.centerIn: Overlay.overlay
    width: 440
    padding: 22
    background: Rectangle { radius: 14; color: Theme.panel; border.color: Theme.border }
    Overlay.modal: Rectangle { color: "#80000000"; radius: Theme.windowRadius }

    component InfoRow: RowLayout {
        property string label
        default property alias content: valueSlot.data
        spacing: 12
        Label { text: parent.label; color: Theme.muted; font.pixelSize: 12; Layout.preferredWidth: 86 }
        Item { id: valueSlot; Layout.fillWidth: true; implicitHeight: childrenRect.height }
    }

    ColumnLayout {
        width: parent.width
        spacing: 16
        RowLayout {
            Label { text: "About"; color: Theme.textStrong; font.pixelSize: 18; font.bold: true; Layout.fillWidth: true }
            ToolButton {
                text: "✕"
                onClicked: root.close()
                contentItem: Text { text: parent.text; color: Theme.muted; font.pixelSize: 14; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 6; color: parent.hovered ? Theme.controlHover : "transparent"; implicitWidth: 30; implicitHeight: 30 }
            }
        }

        // The logo's wordmark is dark navy, so it sits on a light card in both themes.
        Rectangle {
            Layout.fillWidth: true
            implicitHeight: logo.height + 24
            radius: 12
            color: "#ffffff"
            border.color: Theme.border
            Image {
                id: logo
                anchors.centerIn: parent
                source: "qrc:/assets/toofan-logo.svg"
                width: parent.width - 24
                height: width * 300 / 680
                sourceSize: Qt.size(width * 2, height * 2) // render the SVG sharp on high-DPI screens
                fillMode: Image.PreserveAspectFit
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: 10
            InfoRow {
                label: "Version"
                Label { text: root.version; color: Theme.textStrong; font.pixelSize: 13 }
            }
            InfoRow {
                label: "Author"
                Label { text: root.author; color: Theme.textStrong; font.pixelSize: 13 }
            }
            InfoRow {
                label: "Repository"
                Label {
                    readonly property string url: root.repositoryUrl
                    width: parent.width
                    // Inline color: linkColor is not applied to rich-text anchors.
                    text: url ? "<a href=\"" + url + "\" style=\"color:" + Theme.accent + "\">" + url + "</a>" : "Not set yet"
                    textFormat: url ? Text.RichText : Text.PlainText
                    color: url ? Theme.textStrong : Theme.faint
                    font.pixelSize: 13; elide: Text.ElideRight
                    onLinkActivated: link => Qt.openUrlExternally(link)
                    HoverHandler { enabled: parent.url.length > 0; cursorShape: Qt.PointingHandCursor }
                }
            }
            InfoRow {
                label: "Built with"
                Label {
                    text: "Qt " + (root.info.qtVersion || "?") + (root.info.vtkVersion ? "  ·  VTK " + root.info.vtkVersion : "") + "  ·  OpenFOAM"
                    color: Theme.text; font.pixelSize: 12
                }
            }
        }
    }
}
