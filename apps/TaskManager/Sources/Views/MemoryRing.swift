import SwiftUI

/// Radial gauge for memory in use. The track is a dim step of the same hue as
/// the fill (ring-on-ring), so state reads across the whole circle; the center
/// carries the number, so meaning never rests on color alone.
struct MemoryRing: View {
    let memory: MemorySnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double { memory.appUsedFraction }
    private var tint: Color { Theme.load(fraction) }

    var body: some View {
        VStack(spacing: 12) {
            Text("Memory").tileLabel()
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(tint.opacity(0.16), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: fraction)

                VStack(spacing: 2) {
                    Text(Fmt.percent(fraction * 100))
                        .font(.system(.title, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("in use").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(height: 128)
            .padding(.vertical, 4)

            VStack(spacing: 6) {
                legendRow(color: tint, label: "Used", value: Fmt.memory(memory.appUsed))
                legendRow(color: tint.opacity(0.16), label: "Available", value: Fmt.memory(memory.available))
            }
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue("\(Fmt.percent(fraction * 100)) in use, \(Fmt.memory(memory.appUsed)) of \(Fmt.memory(memory.total))")
    }

    private func legendRow(color: Color, label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}
