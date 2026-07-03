import SwiftUI
import Charts

/// A compact line chart with a soft area wash — the app's one chart primitive,
/// reused inline in rows and (larger) in the detail sheet. Single series, so it
/// carries no legend or axes; the surrounding label says what it plots.
///
/// Follows the mark spec: 2px round-capped line, ~12% area wash, no gridlines at
/// this size. `baseline` fixes the y-scale so a flat-but-busy series and a
/// flat-but-idle series don't both render as a mid-line.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    /// Upper bound of the y-scale. nil = auto-fit to the data's max.
    var ceiling: Double?
    var showEndDot = false

    private var domainMax: Double {
        let dataMax = values.max() ?? 1
        if let ceiling { return max(ceiling, 0.0001) }
        return max(dataMax, 0.0001)
    }

    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { index, value in
            AreaMark(
                x: .value("t", index),
                yStart: .value("min", 0),
                yEnd: .value("v", value))
            .foregroundStyle(
                .linearGradient(
                    colors: [color.opacity(0.28), color.opacity(0.02)],
                    startPoint: .top, endPoint: .bottom))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("t", index),
                y: .value("v", value))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)

            if showEndDot, index == values.count - 1 {
                PointMark(x: .value("t", index), y: .value("v", value))
                    .foregroundStyle(color)
                    .symbolSize(60)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...domainMax)
        .chartLegend(.hidden)
        .accessibilityHidden(true)  // the numeric value beside it carries the meaning
    }
}
