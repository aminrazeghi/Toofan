import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Labeled numeric input with a unit. Commits on Enter or focus loss; invalid input reverts.
RowLayout {
    id: root
    property string label
    property string unit
    property real value
    property bool integer: false
    property real minimum: 0
    property real maximum: 1e12
    signal edited(real value)
    spacing: 8

    function format(v) {
        if (integer || v === 0) return String(Math.round(v))
        return Math.abs(v) < 1e-3 || Math.abs(v) >= 1e6 ? Number(v.toPrecision(4)).toExponential() : String(Number(v.toPrecision(6)))
    }

    Label { text: root.label; color: Theme.text; font.pixelSize: 12; wrapMode: Text.WordWrap; Layout.fillWidth: true }
    TextField {
        id: input
        Layout.preferredWidth: 92
        horizontalAlignment: Text.AlignRight
        font.pixelSize: 12
        color: acceptableInput ? Theme.textStrong : Theme.danger
        selectByMouse: true
        text: root.format(root.value)
        validator: root.integer ? intValidator : doubleValidator
        background: Rectangle {
            radius: 6; implicitHeight: 30
            color: Theme.field
            border.color: input.activeFocus ? Theme.accent : Theme.controlBorder
        }
        onEditingFinished: {
            const v = Number(text)
            if (acceptableInput && isFinite(v) && v !== root.value)
                root.edited(v)
            text = Qt.binding(() => root.format(root.value))
        }
        IntValidator { id: intValidator; bottom: Math.ceil(root.minimum); top: Math.min(root.maximum, 2147483647) }
        DoubleValidator { id: doubleValidator; bottom: root.minimum; top: root.maximum; notation: DoubleValidator.ScientificNotation; locale: "C" }
    }
    Label { text: root.unit; color: Theme.muted; font.pixelSize: 11; Layout.preferredWidth: 40 }
}
