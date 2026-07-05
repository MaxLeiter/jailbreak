import SwiftUI

/// A compact line+area sparkline drawn with `Canvas` — deliberately NOT a Swift
/// Charts `Chart`. It renders inline in every process row and refreshes at 1 Hz,
/// so at ~300 rows a full `Chart` per row (view tree, scales, layout) was the
/// scroll-jank bottleneck. `Canvas` draws two paths directly, which is an order
/// of magnitude cheaper. The detail sheet keeps real Swift Charts for its larger,
/// axis-bearing plots.
///
/// Mark spec preserved: 2px round-capped line over a soft top-down area wash.
struct Sparkline: View {
    let values: [Double]
    let color: Color
    /// Upper bound of the y-scale. nil = auto-fit to the data's max.
    var ceiling: Double?
    var showEndDot = false

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            guard values.count > 1, size.width > 0, size.height > 0 else { return }
            let maxV = max(ceiling ?? (values.max() ?? 1), 0.0001)
            let stepX = size.width / CGFloat(values.count - 1)
            func point(_ i: Int) -> CGPoint {
                let clamped = min(max(values[i], 0), maxV)
                let y = size.height - CGFloat(clamped / maxV) * size.height
                return CGPoint(x: CGFloat(i) * stepX, y: y)
            }

            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(
                Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))

            ctx.stroke(line, with: .color(color),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            if showEndDot {
                let p = point(values.count - 1)
                let r: CGFloat = 3
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(color))
            }
        }
        .accessibilityHidden(true)  // the numeric value beside it carries the meaning
    }
}
