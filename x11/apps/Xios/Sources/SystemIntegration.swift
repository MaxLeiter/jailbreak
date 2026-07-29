import UIKit
import AVFoundation
import MediaPlayer

// Native-feel bundle: rotation, hardware volume, light/dark match, haptics.
// Everything here observes iOS state and forwards it over SysIntClient.c's
// config-bound sockets, so the view-side integration point is one line:
//
//     SystemIntegration.shared.install(on: self)      // in XScreenView.start()

final class SystemIntegration {
    static let shared = SystemIntegration()
    private static let maxNativeEventsPerTick = 4

    private weak var hostView: UIView?
    private var installed = false
    private var pump: Timer?
    private var pumpTicks = 0
    private var volumeObservation: NSKeyValueObservation?
    private var volumeView: MPVolumeView?
    private weak var volumeSlider: UISlider?
    private var lastTransform: Int32 = -1
    private var lastDark: Int32 = -1

    private let impactLight = UIImpactFeedbackGenerator(style: .light)
    private let impactMedium = UIImpactFeedbackGenerator(style: .medium)
    private let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
    private let selectionTick = UISelectionFeedbackGenerator()

    /// Invisible hierarchy member whose only job is to hear trait changes for
    /// the light/dark mirror (registerForTraitChanges needs iOS 17; we target 16).
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

        // Appearance: spy view hears style flips; seed the current state now.
        let spy = TraitSpyView(frame: .zero)
        spy.isHidden = true
        spy.isUserInteractionEnabled = false
        spy.onStyleChange = { [weak self] in self?.sendAppearance() }
        view.addSubview(spy)
        traitSpy = spy
        sendAppearance()
        installVolumeSetter(on: view)

        // Volume: an active (ambient, mixing) session makes outputVolume KVO
        // track the hardware buttons. .mixWithOthers so the PulseAudio daemon's
        // playback in the other process is never interrupted.
        activateAudioSession()
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.initial, .new]
        ) { session, _ in
            sysint_send_volume(UInt32((session.outputVolume * 65535).rounded()))
        }

        // Rotation: UIKit rotates the scene, we mirror the new interface
        // orientation to iosc (which re-lays-out + reallocates the output).
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationMayHaveChanged),
            name: UIDevice.orientationDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)

        // Haptic pump + a 1 Hz orientation safety net (catches the initial
        // orientation before the first notification and any missed transition).
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(t, forMode: .common)
        pump = t
    }

    // MARK: rotation

    /// wl_output transform for the current interface orientation. The desktop's
    /// natural shape is landscape, so both landscapes are "normal"; portrait is a
    /// quarter turn. UIKit keeps the drawable upright either way — the transform
    /// is metadata plus the width/height swap trigger.
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

    func syncOutputNow() {
        syncOrientation(force: true)
    }

    private func syncOrientation(force: Bool = false) {
        guard let t = currentTransform(), force || t != lastTransform else { return }
        lastTransform = t
        sysint_send_output(t, 0, 0)   // 0,0 = iosc derives the size by swapping
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

    private func installVolumeSetter(on view: UIView) {
        let vv = MPVolumeView(frame: CGRect(x: -1000, y: -1000, width: 1, height: 1))
        vv.showsVolumeSlider = true
        vv.alpha = 0.01
        vv.isUserInteractionEnabled = false
        view.addSubview(vv)
        volumeView = vv
        DispatchQueue.main.async { [weak self] in
            self?.refreshVolumeSlider()
        }
    }

    private func refreshVolumeSlider() {
        volumeSlider = volumeView?.subviews.compactMap { $0 as? UISlider }.first
    }

    private func setDeviceVolume(_ v16: UInt32) {
        if volumeSlider == nil {
            refreshVolumeSlider()
        }
        guard let slider = volumeSlider else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.setDeviceVolume(v16)
            }
            return
        }

        let clamped = min(v16, 65535)
        let value = Float(clamped) / 65535.0
        if abs(slider.value - value) < 0.002 { return }
        slider.setValue(value, animated: false)
        slider.sendActions(for: .valueChanged)
        slider.sendActions(for: .touchUpInside)
    }

    // MARK: appearance

    private func sendAppearance() {
        let style = traitSpy?.traitCollection.userInterfaceStyle
            ?? UITraitCollection.current.userInterfaceStyle
        let dark: Int32 = style == .dark ? 1 : 0
        if dark != lastDark {
            lastDark = dark
            sysint_send_appearance(dark)
        }
    }

    // MARK: haptics

    private func drainNativeEvents(poll: (UnsafeMutablePointer<UInt32>?) -> Int32,
                                   handle: (UInt32) -> Void) {
        var value: UInt32 = 0
        var drained = 0
        while poll(&value) == 1 && drained < Self.maxNativeEventsPerTick {
            handle(value)
            drained += 1
        }
    }

    private func tick() {
        drainNativeEvents(poll: sysint_poll_haptic) { fire(style: $0) }
        drainNativeEvents(poll: sysint_poll_volume_set) { setDeviceVolume($0) }
        pumpTicks += 1
        if pumpTicks % 20 == 0 { syncOrientation() }   // 1 Hz safety net
    }

    private func fire(style: UInt32) {
        switch style {
        case 1: impactMedium.impactOccurred()
        case 2: impactHeavy.impactOccurred()
        case 3: selectionTick.selectionChanged()
        default: impactLight.impactOccurred()
        }
    }

    /// App-local haptic for the long-press right-click (gesture track calls this
    /// when its deferred press fires — no compositor round-trip).
    func rightClickHaptic() {
        impactMedium.impactOccurred()
    }
}
