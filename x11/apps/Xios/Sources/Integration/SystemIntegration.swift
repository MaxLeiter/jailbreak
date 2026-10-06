import UIKit
import AVFoundation
import MediaPlayer

/// Native-feel bundle: rotation, hardware volume, light/dark match, haptics,
/// desktop-driven volume and brightness.
///
/// The observers are process-wide (there is one iPad), but the wire is per desktop:
/// everything is sent to the presented session's SysIntLink and re-sent whole when
/// a different desktop takes over, so volume, dark mode and orientation apply to
/// whichever desktop is on glass (design decision 3).
final class SystemIntegration {
    static let shared = SystemIntegration()

    private weak var hostView: UIView?
    private var installed = false
    private var link: SysIntLink?
    private var orientationTimer: Timer?
    private var volumeObservation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private weak var volumeSlider: UISlider?
    // A desktop volume request waiting for MPVolumeView to grow its slider: only
    // the newest is kept, with one retry pending at a time (invariant 52).
    private var pendingVolume: UInt32?
    private var volumeRetryScheduled = false
    private var volumeRetries = 0
    private static let maxVolumeRetries = 100   // 10 s at 0.1 s
    private var lastTransform: Int32 = -1
    private var lastDark: Int32 = -1

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionTick = UISelectionFeedbackGenerator()

    /// Invisible hierarchy member whose only job is to hear trait changes for the
    /// light/dark mirror (registerForTraitChanges needs iOS 17; we target 16).
    private final class TraitSpyView: UIView {
        var onStyleChange: (() -> Void)?
        override func traitCollectionDidChange(_ previous: UITraitCollection?) {
            super.traitCollectionDidChange(previous)
            if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
                onStyleChange?()
            }
        }
    }
    private var traitSpy: TraitSpyView?

    func install(on view: UIView) {
        if installed { return }
        installed = true
        hostView = view

        let spy = TraitSpyView(frame: .zero)
        spy.isHidden = true
        spy.isUserInteractionEnabled = false
        spy.onStyleChange = { [weak self] in self?.sendAppearance() }
        view.addSubview(spy)
        traitSpy = spy
        installVolumeSetter(on: view)

        // Volume: an active (ambient, mixing) session makes outputVolume KVO track
        // the hardware buttons. .mixWithOthers so PulseAudio's playback in the
        // other process is never interrupted (invariant 56).
        activateAudioSession()
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.initial, .new]
        ) { [weak self] session, _ in
            // KVO runs on whichever thread AVAudioSession updated from. The link
            // reference is main-owned, so hop to main (invariant 51); the link
            // itself then serializes the send on its own queue.
            let v16 = UInt32((session.outputVolume * 65535).rounded())
            DispatchQueue.main.async { self?.link?.sendVolume(v16) }
        }

        // Rotation: UIKit rotates the scene, we mirror the new interface
        // orientation to iosc (which re-lays-out and reallocates the output).
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationMayHaveChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        // A 1 Hz orientation safety net: catches the initial orientation before the
        // first notification and any missed transition. No I/O: a scene read.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncOrientation()
        }
        RunLoop.main.add(t, forMode: .common)
        orientationTimer = t
    }

    // MARK: per-desktop link

    /// A different desktop is now presented: send it everything it should mirror.
    func attach(link: SysIntLink) {
        self.link = link
        lastDark = -1
        sendAppearance()
        link.sendVolume(UInt32((AVAudioSession.sharedInstance().outputVolume * 65535).rounded()))
        syncOutputNow()
    }

    func detach(link: SysIntLink) {
        if self.link === link { self.link = nil }
    }

    func handle(_ event: SysIntLink.Event) {
        switch event {
        case .haptic(let style): fire(style: style)
        case .volume(let v16): setDeviceVolume(v16)
        case .brightness(let v16): setDeviceBrightness(v16)
        }
    }

    // MARK: rotation

    /// wl_output transform for the current interface orientation. The desktop's
    /// natural shape is landscape, so both landscapes are "normal"; portrait is a
    /// quarter turn. UIKit keeps the drawable upright either way: the transform is
    /// metadata plus the width/height swap trigger.
    private func currentTransform() -> Int32? {
        guard let scene = hostView?.window?.windowScene else { return nil }
        switch scene.interfaceOrientation {
        case .landscapeLeft, .landscapeRight: return 0
        case .portrait: return 1
        case .portraitUpsideDown: return 3
        default: return nil
        }
    }

    @objc private func orientationMayHaveChanged() {
        // Let UIKit settle the scene geometry first, then read the result.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.syncOrientation()
        }
    }

    /// Force-resend the current orientation: after every adopt and layout, because
    /// a compositor restarted in the same orientation has forgotten it (invariant 55).
    func syncOutputNow() { syncOrientation(force: true) }

    private func syncOrientation(force: Bool = false) {
        guard let t = currentTransform(), force || t != lastTransform else { return }
        lastTransform = t
        link?.sendOutput(transform: t)   // logical size 0,0: iosc swaps by itself
    }

    @objc private func becameActive() {
        // The session can be deactivated while backgrounded; KVO resumes with it.
        activateAudioSession()
        syncOrientation()
        sendAppearance()
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    // MARK: volume

    private func installVolumeSetter(on view: UIView) {
        let vv = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        vv.showsVolumeSlider = true
        vv.alpha = 0.01
        vv.isUserInteractionEnabled = false
        view.addSubview(vv)
        volumeView = vv
        DispatchQueue.main.async { [weak self] in self?.refreshVolumeSlider() }
    }

    private func refreshVolumeSlider() {
        volumeSlider = volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    private func setDeviceVolume(_ v16: UInt32) {
        if volumeSlider == nil { refreshVolumeSlider() }
        guard let slider = volumeSlider else {
            // The newest request waits alone, and is dropped after maxVolumeRetries.
            pendingVolume = v16
            scheduleVolumeRetry()
            return
        }
        pendingVolume = nil
        volumeRetries = 0

        let value = Float(min(v16, 65535)) / 65535.0
        if abs(slider.value - value) < 0.002 { return }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
    }

    private func scheduleVolumeRetry() {
        guard !volumeRetryScheduled else { return }
        guard volumeRetries < Self.maxVolumeRetries else {
            pendingVolume = nil
            volumeRetries = 0
            return
        }
        volumeRetryScheduled = true
        volumeRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.volumeRetryScheduled = false
            if let v16 = self.pendingVolume { self.setDeviceVolume(v16) }
        }
    }

    // MARK: brightness

    /// Apply a desktop brightness request to the panel. This lives in the app
    /// rather than in xios-hwbridged because BKSDisplayBrightnessSet is inert on
    /// iPadOS 17.6.1 outside SpringBoard; UIScreen.brightness works from a real app
    /// process, so the daemon relays the value here through xios-sysintd (invariant 54).
    private func setDeviceBrightness(_ v16: UInt32) {
        let value = CGFloat(min(v16, 65535)) / 65535.0
        let screen = (traitSpy ?? volumeView)?.window?.windowScene?.screen ?? UIScreen.main
        // The daemon re-sends while a request is outstanding, and assigning
        // brightness animates and notifies observers, so ignore anything under one
        // 0..255 step of what the panel already shows.
        if abs(screen.brightness - value) < (1.0 / 255.0) { return }
        screen.brightness = value
    }

    // MARK: appearance

    private func sendAppearance() {
        let style = traitSpy?.traitCollection.userInterfaceStyle
            ?? UITraitCollection.current.userInterfaceStyle
        let dark: Int32 = style == .dark ? 1 : 0
        if dark != lastDark {
            lastDark = dark
            link?.sendAppearance(dark: dark == 1)
        }
    }

    // MARK: haptics

    private func fire(style: UInt32) {
        switch style {
        case 1: impactMedium.impactOccurred()
        case 2: impactHeavy.impactOccurred()
        case 3: selectionTick.selectionChanged()
        default: impactLight.impactOccurred()
        }
    }

    /// App-local haptic for the long-press right click (no compositor round trip;
    /// a no-op without a Taptic Engine, e.g. iPad 7).
    func rightClickHaptic() { impactMedium.impactOccurred() }
}
