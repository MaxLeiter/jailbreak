import UIKit
import AVFoundation

// Native-feel bundle: rotation, hardware volume, light/dark match, haptics.
// Self-contained by design — everything here observes iOS state and forwards it
// over SysIntClient.c's own sockets, so the ONLY integration point is one line:
//
//     SystemIntegration.shared.install(on: self)      // in XScreenView.start()
//
// The C entry points are declared via @_silgen_name instead of the bridging
// header so this file lands without editing any shared file; fold them into
// Xios-Bridging-Header.h whenever convenient.
@_silgen_name("sysint_send_volume") private func c_send_volume(_ v16: UInt32)
@_silgen_name("sysint_send_appearance") private func c_send_appearance(_ dark: Int32)
@_silgen_name("sysint_send_output")
private func c_send_output(_ transform: Int32, _ lw: Int32, _ lh: Int32)
@_silgen_name("sysint_poll_haptic")
private func c_poll_haptic(_ style: UnsafeMutablePointer<UInt32>?) -> Int32

final class SystemIntegration {
    static let shared = SystemIntegration()

    private weak var hostView: UIView?
    private var installed = false
    private var pump: Timer?
    private var pumpTicks = 0
    private var volumeObservation: NSKeyValueObservation?
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

        // Volume: an active (ambient, mixing) session makes outputVolume KVO
        // track the hardware buttons. .mixWithOthers so the PulseAudio daemon's
        // playback in the other process is never interrupted.
        activateAudioSession()
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.initial, .new]
        ) { session, _ in
            c_send_volume(UInt32((session.outputVolume * 65535).rounded()))
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

    private func syncOrientation() {
        guard let t = currentTransform(), t != lastTransform else { return }
        lastTransform = t
        c_send_output(t, 0, 0)   // 0,0 = iosc derives the size by swapping
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

    // MARK: appearance

    private func sendAppearance() {
        let style = traitSpy?.traitCollection.userInterfaceStyle
            ?? UITraitCollection.current.userInterfaceStyle
        let dark: Int32 = style == .dark ? 1 : 0
        if dark != lastDark {
            lastDark = dark
            c_send_appearance(dark)
        }
    }

    // MARK: haptics

    private func tick() {
        var style: UInt32 = 0
        var drained = 0
        while c_poll_haptic(&style) == 1 && drained < 4 {
            fire(style: style)
            drained += 1
        }
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
