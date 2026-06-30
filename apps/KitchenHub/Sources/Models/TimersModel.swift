import SwiftUI

/// Multiple named kitchen timers. Drives the Timers screen and the timer card.
@MainActor
final class TimersModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var duration: TimeInterval
        var remaining: TimeInterval
        var running: Bool
        var finished: Bool = false
        var endDate: Date?
        var progress: Double { duration > 0 ? max(0, min(1, remaining / duration)) : 0 }
    }

    @Published var items: [Item] = []
    @Published var selectedID: UUID?

    /// Quick-add presets shown on the Timers screen (label, minutes).
    let quickAdd: [(name: String, minutes: Int)] = [
        ("Eggs", 6), ("Pasta", 10), ("Tea", 3), ("Bread", 30)
    ]

    private var ticker: Foundation.Timer?

    var selected: Item? { items.first { $0.id == selectedID } ?? items.first }
    var runningCount: Int { items.filter { $0.running }.count }

    // Starts empty (synthesized init) — users add timers via Quick Add / New Timer.

    @discardableResult
    func add(name: String, minutes: Int) -> UUID { add(name: name, seconds: TimeInterval(minutes * 60)) }

    @discardableResult
    func add(name: String, seconds: TimeInterval) -> UUID {
        let item = Item(name: name, duration: seconds, remaining: seconds,
                        running: true, endDate: Date().addingTimeInterval(seconds))
        items.append(item)
        selectedID = item.id
        startTicker()
        refreshAlarm()
        return item.id
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = items.first?.id }
        refreshAlarm()
    }

    func toggle(_ id: UUID) {
        guard let i = idx(id) else { return }
        if items[i].running {
            items[i].running = false
            items[i].endDate = nil
        } else if items[i].remaining > 0 {
            items[i].running = true
            items[i].finished = false
            items[i].endDate = Date().addingTimeInterval(items[i].remaining)
            startTicker()
        }
        refreshAlarm()
    }

    func addTime(_ id: UUID, seconds: TimeInterval) {
        guard let i = idx(id) else { return }
        items[i].duration += seconds
        items[i].remaining += seconds
        items[i].finished = false
        if items[i].running { items[i].endDate = Date().addingTimeInterval(items[i].remaining) }
        refreshAlarm()
    }

    func reset(_ id: UUID) {
        guard let i = idx(id) else { return }
        items[i].running = false
        items[i].finished = false
        items[i].remaining = items[i].duration
        items[i].endDate = nil
        refreshAlarm()
    }

    func select(_ id: UUID) { selectedID = id }

    /// "5:30" / "1:02:03"
    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up)), h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    private func idx(_ id: UUID) -> Int? { items.firstIndex { $0.id == id } }

    private func startTicker() {
        guard ticker == nil else { return }
        // 1 Hz: countdowns are second-resolution, so this is enough and avoids
        // republishing `items` (and re-rendering every observer) 4× a second.
        let t = Foundation.Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        for i in items.indices where items[i].running {
            if let end = items[i].endDate {
                items[i].remaining = max(0, end.timeIntervalSinceNow)
                if items[i].remaining <= 0 {
                    items[i].running = false
                    items[i].finished = true
                    items[i].endDate = nil
                }
            }
        }
        refreshAlarm()
        // Keep ticking while a finished timer is still ringing (un-dismissed).
        if runningCount == 0 && !items.contains(where: { $0.finished }) {
            ticker?.invalidate(); ticker = nil
        }
    }

    /// Manage background audio: stay alive (silent) while a timer counts down so
    /// it finishes even if the screen sleeps; ring while any timer is finished;
    /// release everything once all timers are dismissed so the app can suspend.
    /// NOTE: TimersModel is currently the *sole* owner of keep-alive. If another
    /// subsystem ever needs the app awake, switch AlarmPlayer to a lease/refcount.
    private func refreshAlarm() {
        AlarmPlayer.shared.setKeepAlive(runningCount > 0)
        if items.contains(where: { $0.finished }) { AlarmPlayer.shared.start() }
        else { AlarmPlayer.shared.stop() }
    }
}
