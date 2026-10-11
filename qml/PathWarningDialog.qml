import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Shown at startup when OpenFOAM cannot work with the projects folder (spaces or non-ASCII
// characters in its path) or with its own install location.
Popup {
    id: root
    property string folderProblem      // SimulationController.caseRootProblem
    property string openFoamProblem    // SimulationController.openFoamProblem
    signal chooseFolder()

    modal: true
    focus: true
    closePolicy: Popup.CloseOnEscape
    anchors.centerIn: Overlay.overlay
    width: 460
    padding: 22
    background: Rectangle { radius: 14; color: Theme.panel; border.color: Theme.border }
    Overlay.modal: Rectangle { color: "#80000000"; radius: Theme.windowRadius }

    ColumnLayout {
        width: parent.width
        spacing: 12
        Label {
            text: root.folderProblem ? "Choose a projects folder" : "Install location"
            color: Theme.textStrong; font.pixelSize: 18; font.bold: true
        }
        Label {
            Layout.fillWidth: true
            visible: root.openFoamProblem.length > 0
            text: root.openFoamProblem
            color: Theme.danger; font.pixelSize: 13; wrapMode: Text.WordWrap
        }
        Label {
            Layout.fillWidth: true
            visible: root.folderProblem.length > 0
            text: root.folderProblem + " Simulations cannot run until you choose a folder whose path has only "
                  + "plain letters, digits, '-', '_' and '.'"
                  + (Qt.platform.os === "windows" ? ", for example C:\\Toofan-Projects." : ", for example ~/Toofan-Projects.")
            color: Theme.text; font.pixelSize: 13; wrapMode: Text.WordWrap
        }
        Label {
            Layout.fillWidth: true
            visible: root.folderProblem.length > 0
            text: "You can change it later in Settings."
            color: Theme.faint; font.pixelSize: 11
        }
        RowLayout {
            Layout.fillWidth: true; Layout.topMargin: 6
            spacing: 10
            Item { Layout.fillWidth: true }
            Button {
                text: "Later"
                onClicked: root.close()
                contentItem: Text { text: parent.text; color: Theme.textStrong; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 9; color: parent.hovered ? Theme.controlHover : Theme.control; border.color: Theme.controlBorder; implicitWidth: 90; implicitHeight: 38 }
            }
            Button {
                visible: root.folderProblem.length > 0
                text: "Choose folder…"
                onClicked: root.chooseFolder()
                contentItem: Text { text: parent.text; color: Theme.accentText; font.bold: true; horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter }
                background: Rectangle { radius: 9; color: parent.hovered ? Qt.lighter(Theme.accent, 1.1) : Theme.accent; implicitWidth: 140; implicitHeight: 38 }
            }
        }
    }
}
