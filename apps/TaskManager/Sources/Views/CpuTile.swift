import SwiftUI

/// CPU dashboard tile: the headline overall-CPU number over a rolling trend,
/// with a row of per-core meters beneath. All CPU marks share the one blue hue.
struct CpuTile: View {
    let overall: Double
    let history: [Double]
    let cores: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Processor").tileLabel()
                Spacer()
                Text("\(cores.count) cores").font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(Fmt.percent(overall))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                Text("avg").font(.callout).foregroundStyle(.secondary)
            }

            Sparkline(values: history, color: Theme.cpu, ceiling: 100)
                .frame(height: 56)

            Divider().overlay(Theme.hairline)

            VStack(spacing: 8) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                    CoreMeter(index: index, usage: usage, animate: !reduceMotion)
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Processor, \(Fmt.percent(overall)) average across \(cores.count) cores")
    }
}

/// One horizontal core meter. The filled portion is CPU blue; the track is a
/// dim step of it. Bar caps are rounded per the mark spec.
private struct CoreMeter: View {
    let index: Int
    let usage: Double
    let animate: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cpu.opacity(0.14))
                    Capsule().fill(Theme.cpu)
                        .frame(width: max(4, geo.size.width * min(1, usage / 100)))
                        .animation(animate ? .smooth(duration: 0.35) : nil, value: usage)
                }
            }
            .frame(height: 8)

            Text(Fmt.percent(usage))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Core \(index)")
        .accessibilityValue(Fmt.percent(usage))
    }
}
