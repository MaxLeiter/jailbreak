import Foundation
import GameController
import UIKit

/// Process-wide physical-keyboard bridge shared by the classic Xios desktop and
/// native per-window host. GameController exposes raw HID transitions without
/// requiring a text field or first responder, which is exactly what a desktop
/// needs for held keys, simultaneous chords, and modifier-only shortcuts.
final class XiosHardwareKeyboard {
    typealias Handler = (_ keysym: UInt32, _ down: Bool, _ modifiers: UInt32) -> Void

    // Wire modifier bits (xios_input_socket.h).
    static let shift: UInt32 = 1 << 0
    static let control: UInt32 = 1 << 1
    static let alternate: UInt32 = 1 << 2
    static let superKey: UInt32 = 1 << 3
    static let capsLock: UInt32 = 1 << 4
    static let numLock: UInt32 = 1 << 5

    private var handler: Handler?
    private var observers: [NSObjectProtocol] = []
    private var pressed: [Int: UInt32] = [:]
    private var modifiers: UInt32 = 0
    private var lastPhysicalTransition = Date.distantPast

    func start(_ handler: @escaping Handler) {
        guard self.handler == nil else { return }
        self.handler = handler
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCKeyboardDidConnect, object: nil, queue: .main
        ) { [weak self] _ in self?.attach() })
        observers.append(center.addObserver(
            forName: .GCKeyboardDidDisconnect, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseAll() })
        observers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.releaseAll() })
        attach()
    }

    func stop() {
        releaseAll()
        GCKeyboard.coalesced?.keyboardInput?.keyChangedHandler = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        handler = nil
    }

    func releasePressedKeys() {
        releaseAll()
    }

    /// UIKit can also call UIKeyInput for the same physical printable key while
    /// the desktop view owns the responder. Suppress only the immediate echo;
    /// on-screen keyboard input remains untouched even with a keyboard attached.
    func isLikelyUIKitEcho() -> Bool {
        GCKeyboard.coalesced != nil &&
            Date().timeIntervalSince(lastPhysicalTransition) < 0.12
    }

    private func attach() {
        guard let input = GCKeyboard.coalesced?.keyboardInput else { return }
        input.keyChangedHandler = { [weak self] _, _, code, down in
            let hid = code.rawValue
            if Thread.isMainThread {
                self?.transition(hid: hid, down: down)
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.transition(hid: hid, down: down)
                }
            }
        }
    }

    private func transition(hid: Int, down: Bool) {
        guard let keysym = Self.keysym(forHID: hid) else { return }
        if down {
            guard pressed[hid] == nil else { return }
            if hid == 0x39 { modifiers ^= Self.capsLock }
            if hid == 0x53 { modifiers ^= Self.numLock }
            if let bit = Self.depressedModifierBit(forHID: hid) { modifiers |= bit }
            pressed[hid] = keysym
        } else {
            guard pressed.removeValue(forKey: hid) != nil else { return }
            if let bit = Self.depressedModifierBit(forHID: hid) { modifiers &= ~bit }
        }
        lastPhysicalTransition = Date()
        handler?(keysym, down, modifiers)
    }

    private func releaseAll() {
        // Release ordinary keys while their chord modifiers are still active,
        // then release modifiers. This avoids a lost focus/background edge
        // leaving Ctrl, Alt, or a mouse-look movement key stuck on the desktop.
        let hids = pressed.keys.sorted {
            (Self.depressedModifierBit(forHID: $0) == nil ? 0 : 1,
             $0) <
            (Self.depressedModifierBit(forHID: $1) == nil ? 0 : 1,
             $1)
        }
        for hid in hids { transition(hid: hid, down: false) }
    }

    private static func depressedModifierBit(forHID hid: Int) -> UInt32? {
        switch hid {
        case 0xe1, 0xe5: return shift
        case 0xe0, 0xe4: return control
        case 0xe2, 0xe6: return alternate
        case 0xe3, 0xe7: return superKey
        default: return nil
        }
    }

    /// USB HID usage -> X keysym. The compositor advertises a pc105/us XKB
    /// keymap, so unshifted keysyms plus the independent modifier snapshot give
    /// clients the same semantics as an evdev keyboard.
    static func keysym(forHID hid: Int) -> UInt32? {
        XiosHardwareKeymap.keysym(forHID: hid)
    }
}
