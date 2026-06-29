import SwiftUI
import AudioToolbox

/// Countdown logic for one timer panel. Uses an absolute end date so it stays
/// accurate even if the tick fires late.
@MainActor
final class TimerEngine: ObservableObject {
    @Published var remaining: TimeInterval
    @Published var duration: TimeInterval
    @Published var running = false
    @Published var finished = false

    private var ticker: Timer?
    private var endDate: Date?

    init(duration: TimeInterval = 5 * 60) {
        self.duration = duration
        self.remaining = duration
    }

    func setDuration(_ seconds: TimeInterval) {
        stopTicker()
        duration = seconds
        remaining = seconds
        running = false
        finished = false
    }

    func addTime(_ seconds: TimeInterval) {
        duration += seconds
        remaining += seconds
        finished = false
        if running { endDate = Date().addingTimeInterval(remaining) }
    }

    func startPause() {
        running ? pause() : start()
    }

    func start() {
        guard remaining > 0 else { return }
        finished = false
        running = true
        endDate = Date().addingTimeInterval(remaining)
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    func pause() {
        running = false
        stopTicker()
    }

    func reset() {
        stopTicker()
        running = false
        finished = false
        remaining = duration
    }

    private func tick() {
        guard let endDate else { return }
        remaining = max(0, endDate.timeIntervalSinceNow)
        if remaining <= 0 {
            running = false
            finished = true
            stopTicker()
            AudioServicesPlaySystemSound(1005)
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

/// A kitchen timer. Drop several on the board — each keeps its own countdown and
/// remembers its set length across relaunches (persisted in the panel config).
struct TimerPanel: View {
    let panelID: UUID
    @EnvironmentObject private var store: BoardStore
    @StateObject private var engine: TimerEngine
    @State private var showCustom = false

    private let presets = [1, 3, 5, 10]   // minutes

    init(panelID: UUID, initialSeconds: TimeInterval) {
        self.panelID = panelID
        _engine = StateObject(wrappedValue: TimerEngine(duration: initialSeconds))
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                Text(timeString(engine.remaining))
                    .font(.system(size: 220, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .minimumScaleFactor(0.1)
                    .lineLimit(1)
                    .foregroundStyle(engine.finished ? Theme.accent : Theme.text)
                    .frame(maxWidth: .infinity)

                if geo.size.height > 150 {
                    HStack(spacing: 6) {
                        ForEach(presets, id: \.self) { m in
                            Button("\(m)m") { setDuration(TimeInterval(m * 60)) }
                                .buttonStyle(PresetButtonStyle())
                        }
                        Button("Custom") { showCustom = true }
                            .buttonStyle(PresetButtonStyle())
                    }
                }

                HStack(spacing: 12) {
                    Button { engine.addTime(60) } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(ControlButtonStyle())

                    Button { engine.startPause() } label: {
                        Image(systemName: engine.running ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(ControlButtonStyle(prominent: true))

                    Button { engine.reset() } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(ControlButtonStyle())
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(engine.finished ? Theme.accent.opacity(0.16) : Color.clear)
            .animation(.easeInOut(duration: 0.4), value: engine.finished)
        }
        .sheet(isPresented: $showCustom) {
            TimePickerSheet(initial: engine.duration) { secs in
                setDuration(secs)
                engine.start()
            }
        }
    }

    /// Set the timer and remember the length in the panel's persisted config.
    private func setDuration(_ secs: TimeInterval) {
        engine.setDuration(secs)
        store.setConfig(panelID, ["seconds": String(Int(secs))])
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }
}
