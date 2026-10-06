pragma Singleton
import QtQuick

// App colors for the dark and light themes.
QtObject {
    property bool dark: true

    readonly property color window: dark ? "#0c1118" : "#e7ecf0"
    readonly property color panel: dark ? "#111821" : "#ffffff"
    readonly property color border: dark ? "#202a36" : "#d3dbe3"
    readonly property color control: dark ? "#151b24" : "#f1f4f7"        // buttons, cards
    readonly property color controlHover: dark ? "#18202a" : "#e6ebf0"
    readonly property color controlBorder: dark ? "#283342" : "#cdd6df"
    readonly property color field: dark ? "#0d131b" : "#f6f8fa"          // inputs, drop zone
    readonly property color consoleBackground: dark ? "#0a0f15" : "#f6f8fa"
    readonly property color overlay: dark ? "#cc0d131b" : "#e6ffffff"    // labels over the 3D view
    readonly property color divider: dark ? "#27313d" : "#e1e6eb"
    readonly property color text: dark ? "#d9e1e8" : "#2a3540"
    readonly property color textStrong: dark ? "#f2f5f8" : "#111a22"
    readonly property color muted: dark ? "#8c9aab" : "#66768a"
    readonly property color faint: dark ? "#5d6b7a" : "#9aa7b4"
    readonly property color accent: dark ? "#58d6bd" : "#13917b"
    readonly property color accentText: dark ? "#071511" : "#ffffff"     // on an accent fill
    readonly property color accentDisabled: dark ? "#39534d" : "#a9d6cc"
    readonly property color selected: dark ? "#1f3633" : "#dcf2ec"
    readonly property color danger: dark ? "#ef6f6c" : "#cc4642"
    readonly property color dangerBorder: dark ? "#5a2c2f" : "#efc2c0"
    readonly property color plotGrid: dark ? "#202a36" : "#e3e8ed"
    readonly property color plotFrame: dark ? "#334253" : "#c4cdd6"
    readonly property var seriesColors: dark
        ? ["#58d6bd", "#6aa8ff", "#f2b84b", "#ef6f6c", "#b48cff", "#8fd16a", "#e58fd0", "#9aa7b4"]
        : ["#13917b", "#2f6fdb", "#c98a10", "#d14b47", "#7d52d9", "#4f9a2b", "#c2479f", "#66768a"]
}
