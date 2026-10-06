import QuartzCore

/// The display link and the ONE seam through which the frame rate is set.
///
/// The link's targetTimestamp is the deadline for the frame being built. Sent to
/// the compositor each tick it turns iosc's coalesced repaint from event-loop paced
/// into vblank paced. The rate is a RANGE (CAFrameRateRange), never
/// preferredFramesPerSecond: a range is something CoreAnimation can settle inside on
/// its own. The thermal track clamps `range` through `setRange` (invariant 4).
final class FrameClock: NSObject {
    /// The idle/no-signal holding frame: nothing animates, so ask for very little.
    static let holding = CAFrameRateRange(minimum: 10, maximum: 20, preferred: 20)
    /// A live desktop. The floor is deliberately well below the ceiling so
    /// CoreAnimation can throttle a thermally constrained A10 without stuttering.
    static let live = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)

    var onTick: ((CADisplayLink) -> Void)?
    private var link: CADisplayLink?
    private(set) var range = FrameClock.holding
    /// Refresh interval the link last reported, for the status line.
    var lastIntervalUs: UInt32 = 0

    var isPaused: Bool {
        get { link?.isPaused ?? true }
        set { link?.isPaused = newValue }
    }

    func start() {
        guard link == nil else { return }
        let dl = CADisplayLink(target: self, selector: #selector(fire(_:)))
        dl.preferredFrameRateRange = range
        dl.add(to: .main, forMode: .common)
        link = dl
    }

    @objc private func fire(_ l: CADisplayLink) { onTick?(l) }

    func setRange(_ new: CAFrameRateRange) {
        guard new != range else { return }
        range = new
        link?.preferredFrameRateRange = new
        publishStatus()
    }

    /// "vblank" is the app's claim that it IS driving the compositor's clock; the
    /// compositor publishes its own `pacing` key saying whether it accepted one. Both
    /// appear in `xios-status`, attributed.
    func publishStatus() {
        let interval = lastIntervalUs > 0
            ? String(format: " interval=%.2fms", Double(lastIntervalUs) / 1000.0) : ""
        // `preferred` is optional in the SDK: nil means "no preference".
        let preferred = range.preferred.map { String(format: "/%g", $0) } ?? ""
        let fps = String(format: "%g-%g", range.minimum, range.maximum)
        StatusWriter.shared.setValue("pacing", "vblank fps=\(fps)\(preferred)\(interval)")
    }
}
