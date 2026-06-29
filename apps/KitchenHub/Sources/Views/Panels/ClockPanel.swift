import SwiftUI

/// Big glanceable time + date. Honours the device's 12/24-hour locale setting.
struct ClockPanel: View {
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 2) {
            Text(now, format: .dateTime.hour().minute())
                .font(.system(size: 240, weight: .bold, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.1)
                .lineLimit(1)
                .foregroundStyle(Theme.text)

            Text(now, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.system(size: 64, weight: .medium, design: .rounded))
                .minimumScaleFactor(0.1)
                .lineLimit(1)
                .foregroundStyle(Theme.subtext)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(18)
        .onReceive(tick) { now = $0 }
    }
}
