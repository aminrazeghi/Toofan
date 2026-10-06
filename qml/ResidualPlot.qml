import QtQuick
import QtQuick.Controls

// Log-scale plot of solver initial residuals against simulated time.
Item {
    id: root
    // [{name, times: [...], values: [...]}], as provided by simulation.residuals
    property var series: []
    readonly property var seriesColors: ["#58d6bd", "#6aa8ff", "#f2b84b", "#ef6f6c", "#b48cff", "#8fd16a", "#e58fd0", "#9aa7b4"]
    onSeriesChanged: canvas.requestPaint()

    Label { id: title; text: "Residuals"; color: "#dce4ea"; font.pixelSize: 15; font.bold: true }
    Row {
        anchors.right: parent.right; anchors.verticalCenter: title.verticalCenter; spacing: 14
        Repeater {
            model: root.series
            Row {
                required property var modelData
                required property int index
                spacing: 6
                Rectangle { width: 12; height: 3; radius: 1; color: root.seriesColors[index % root.seriesColors.length]; anchors.verticalCenter: parent.verticalCenter }
                Label { text: modelData.name; color: "#b6c5d1"; font.pixelSize: 12 }
            }
        }
    }
    Label {
        anchors.centerIn: canvas; visible: root.series.length === 0
        text: "Residuals appear here once the solver starts."; color: "#8c9aab"; font.pixelSize: 13
    }
    Canvas {
        id: canvas
        anchors { top: title.bottom; topMargin: 12; left: parent.left; right: parent.right; bottom: parent.bottom }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const series = root.series;
            if (!series || series.length === 0)
                return;

            let tMin = Infinity, tMax = -Infinity, vMin = Infinity, vMax = -Infinity;
            for (const s of series) {
                for (let i = 0; i < s.times.length; ++i) {
                    tMin = Math.min(tMin, s.times[i]); tMax = Math.max(tMax, s.times[i]);
                    vMin = Math.min(vMin, s.values[i]); vMax = Math.max(vMax, s.values[i]);
                }
            }
            if (!isFinite(tMin))
                return;
            if (tMax <= tMin)
                tMax = tMin + 1e-9;
            const decadeMin = Math.floor(Math.log10(vMin));
            const decadeMax = Math.max(decadeMin + 1, Math.ceil(Math.log10(vMax)));

            const left = 46, right = 10, top = 6, bottom = 26;
            const w = width - left - right, h = height - top - bottom;
            if (w <= 0 || h <= 0)
                return;
            const x = t => left + (t - tMin) / (tMax - tMin) * w;
            const y = v => top + (decadeMax - Math.log10(v)) / (decadeMax - decadeMin) * h;

            ctx.font = "11px sans-serif";
            ctx.lineWidth = 1;
            // One grid line per decade, thinned out when the range is large.
            const decadeStep = Math.max(1, Math.ceil((decadeMax - decadeMin) / 8));
            ctx.textAlign = "right"; ctx.textBaseline = "middle";
            for (let d = decadeMin; d <= decadeMax; d += decadeStep) {
                const py = y(Math.pow(10, d));
                ctx.strokeStyle = "#202a36";
                ctx.beginPath(); ctx.moveTo(left, py); ctx.lineTo(left + w, py); ctx.stroke();
                ctx.fillStyle = "#8c9aab";
                ctx.fillText("1e" + d, left - 6, py);
            }
            ctx.textBaseline = "top";
            for (let i = 0; i <= 4; ++i) {
                const t = tMin + (tMax - tMin) * i / 4;
                ctx.textAlign = i === 0 ? "left" : i === 4 ? "right" : "center"; // keep end labels inside
                ctx.fillText(Number(t.toPrecision(3)) + (i === 4 ? " s" : ""), x(t), top + h + 8);
            }
            ctx.strokeStyle = "#334253";
            ctx.strokeRect(left, top, w, h);

            ctx.lineWidth = 1.5;
            for (let s = 0; s < series.length; ++s) {
                const times = series[s].times, values = series[s].values;
                ctx.strokeStyle = root.seriesColors[s % root.seriesColors.length];
                ctx.beginPath();
                for (let i = 0; i < times.length; ++i) {
                    if (i === 0) ctx.moveTo(x(times[i]), y(values[i]));
                    else ctx.lineTo(x(times[i]), y(values[i]));
                }
                ctx.stroke();
            }
        }
    }
}
