import QtQuick
import QtQuick.Controls

// Line plot of monitor series against simulated time, on a log or linear y axis.
Item {
    id: root
    // [{name, times: [...], values: [...]}], as provided by the simulation controller
    property var series: []
    property string title
    property bool logScale: false
    property string emptyText: "Data appears here once the solver starts."
    readonly property var seriesColors: Theme.seriesColors
    onSeriesChanged: canvas.requestPaint()
    onSeriesColorsChanged: canvas.requestPaint() // theme switch
    onLogScaleChanged: canvas.requestPaint()

    // Header strip: title on the left, legend on the right (wrapping onto more lines when narrow).
    Item { id: header; width: parent.width; height: Math.max(26, legend.height) }
    Label { id: titleLabel; text: root.title; y: (26 - height) / 2; color: Theme.textStrong; font.pixelSize: 14; font.bold: true }
    Flow {
        id: legend
        anchors.right: parent.right
        width: parent.width - titleLabel.implicitWidth - 16
        layoutDirection: Qt.RightToLeft
        spacing: 12
        Repeater {
            // Laid out right to left, so fed last series first to read in series order.
            model: root.series.length
            Row {
                required property int index
                readonly property int seriesIndex: root.series.length - 1 - index
                readonly property var modelData: root.series[seriesIndex]
                spacing: 6
                height: 26
                Rectangle { width: 12; height: 3; radius: 1; color: root.seriesColors[seriesIndex % root.seriesColors.length]; anchors.verticalCenter: parent.verticalCenter }
                // Single-series plots also show the latest value.
                Label {
                    text: modelData.name + (root.series.length === 1 && modelData.values.length
                                            ? "  " + Number(modelData.values[modelData.values.length - 1]).toPrecision(4) : "")
                    color: Theme.text; font.pixelSize: 11
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }
    Label {
        anchors.centerIn: canvas; visible: root.series.length === 0
        width: canvas.width - 24; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
        text: root.emptyText; color: Theme.muted; font.pixelSize: 12
    }
    Canvas {
        id: canvas
        anchors { top: header.bottom; topMargin: 6; left: parent.left; right: parent.right; bottom: parent.bottom }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        // Round tick step: 1, 2 or 5 times a power of ten, giving about `count` intervals.
        function niceStep(span, count) {
            const raw = span / count;
            const magnitude = Math.pow(10, Math.floor(Math.log10(raw)));
            const residual = raw / magnitude;
            return magnitude * (residual > 5 ? 10 : residual > 2 ? 5 : residual > 1 ? 2 : 1);
        }

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const series = root.series;
            if (!series || series.length === 0)
                return;

            let tMin = Infinity, tMax = -Infinity, points = 0;
            for (const s of series) {
                for (let i = 0; i < s.times.length; ++i) {
                    tMin = Math.min(tMin, s.times[i]); tMax = Math.max(tMax, s.times[i]);
                    ++points;
                }
            }
            if (!isFinite(tMin))
                return;
            if (tMax <= tMin)
                tMax = tMin + 1e-9;
            // On a linear axis, scale to the data after the start-up transient (an impulsive start
            // gives force coefficients orders of magnitude above the developed flow); the transient
            // is still drawn, clipped at the plot edge.
            const scaleFrom = !root.logScale && points >= 20 ? tMin + 0.05 * (tMax - tMin) : tMin;
            let vMin = Infinity, vMax = -Infinity;
            for (const s of series) {
                for (let i = 0; i < s.times.length; ++i) {
                    if (s.times[i] < scaleFrom || (root.logScale && !(s.values[i] > 0)))
                        continue;
                    vMin = Math.min(vMin, s.values[i]); vMax = Math.max(vMax, s.values[i]);
                }
            }
            if (!isFinite(vMin))
                return;

            // y axis: whole decades on a log scale, round steps with a little headroom otherwise.
            let yMin, yMax, ticks = [];
            if (root.logScale) {
                yMin = Math.floor(Math.log10(vMin));
                yMax = Math.max(yMin + 1, Math.ceil(Math.log10(vMax)));
                const step = Math.max(1, Math.ceil((yMax - yMin) / 8));
                for (let d = yMin; d <= yMax; d += step)
                    ticks.push({ at: d, text: "1e" + d });
            } else {
                const pad = vMax > vMin ? 0.08 * (vMax - vMin) : Math.max(Math.abs(vMax) * 0.1, 1e-3);
                const step = niceStep((vMax + pad) - (vMin - pad), 5);
                yMin = Math.floor((vMin - pad) / step) * step;
                yMax = Math.ceil((vMax + pad) / step) * step;
                const digits = Math.max(0, -Math.floor(Math.log10(step)));
                for (let v = yMin; v <= yMax + step / 2; v += step)
                    ticks.push({ at: v, text: (Math.abs(v) < step / 2 ? 0 : v).toFixed(digits) });
            }
            const toAxis = v => root.logScale ? Math.log10(v) : v;

            const left = 52, right = 10, top = 6, bottom = 26;
            const w = width - left - right, h = height - top - bottom;
            if (w <= 0 || h <= 0)
                return;
            const x = t => left + (t - tMin) / (tMax - tMin) * w;
            const y = v => top + (yMax - toAxis(v)) / (yMax - yMin) * h;
            const yTick = a => top + (yMax - a) / (yMax - yMin) * h;

            ctx.font = "11px sans-serif";
            ctx.lineWidth = 1;
            ctx.textAlign = "right"; ctx.textBaseline = "middle";
            for (const tick of ticks) {
                const py = yTick(tick.at);
                ctx.strokeStyle = String(Theme.plotGrid);
                ctx.beginPath(); ctx.moveTo(left, py); ctx.lineTo(left + w, py); ctx.stroke();
                ctx.fillStyle = String(Theme.muted);
                ctx.fillText(tick.text, left - 6, py);
            }
            ctx.textBaseline = "top";
            for (let i = 0; i <= 4; ++i) {
                const t = tMin + (tMax - tMin) * i / 4;
                ctx.textAlign = i === 0 ? "left" : i === 4 ? "right" : "center"; // keep end labels inside
                ctx.fillText(Number(t.toPrecision(3)) + (i === 4 ? " s" : ""), x(t), top + h + 8);
            }
            ctx.strokeStyle = String(Theme.plotFrame);
            ctx.strokeRect(left, top, w, h);

            ctx.save();
            ctx.beginPath(); ctx.rect(left, top, w, h); ctx.clip();
            ctx.lineWidth = 1.5;
            for (let s = 0; s < series.length; ++s) {
                const times = series[s].times, values = series[s].values;
                ctx.strokeStyle = root.seriesColors[s % root.seriesColors.length];
                ctx.beginPath();
                let started = false;
                for (let i = 0; i < times.length; ++i) {
                    if (root.logScale && !(values[i] > 0))
                        continue;
                    if (!started) { ctx.moveTo(x(times[i]), y(values[i])); started = true; }
                    else ctx.lineTo(x(times[i]), y(values[i]));
                }
                ctx.stroke();
            }
            ctx.restore();
        }
    }
}
