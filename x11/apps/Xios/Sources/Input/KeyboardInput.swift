import UIKit

/// Everything about the software keyboard and sticky modifiers: the auto on-screen
/// keyboard policy driven by the compositor's TRAITS records, the modifier row above
/// the keyboard, and turning typed text into wire records. The hardware keyboard is
/// XiosHardwareKeyboard (GameController), owned by the PresentView.
final class KeyboardController {
    private unowned let view: PresentView

    // Sticky modifiers. Ctrl/Alt/Shift are one-shots: armed by a tap, applied to the
    // next key, then auto-cleared.
    private var modCtrl = false, modAlt = false, modShift = false
    private var modRow: UIView?
    private weak var ctrlBtn: UIButton?
    private weak var altBtn: UIButton?
    private weak var shiftBtn: UIButton?

    // Auto on-screen-keyboard responder policy (design: x11/docs/osk-plan.md).
    private var autoShown = false          // the auto path raised the keyboard
    private var userDismissed = false      // user hid it while the field was still enabled
    private var programmaticResign = false // our resign vs the user's
    private var hideTimer: Timer?
    private var lastHint: UInt32 = 0
    private var lastPurpose: UInt32 = 0
    private var lastEnabled: UInt32 = 0

    init(view: PresentView) { self.view = view }

    var accessoryView: UIView {
        if let modRow { return modRow }
        let row = buildModRow()
        modRow = row
        return row
    }

    // MARK: responder bookkeeping

    func didBecomeFirstResponder() { userDismissed = false }

    func didResignFirstResponder() {
        guard !programmaticResign else { return }
        // The user hid the keyboard (toggle or dismiss key) while the field may
        // still be focused: do not fight them on the next broadcast.
        if lastEnabled != 0 { userDismissed = true }
        autoShown = false
    }

    /// A new desktop is on glass: forget the previous one's field state.
    func reset() {
        hideTimer?.invalidate(); hideTimer = nil
        if autoShown, view.isFirstResponder {
            programmaticResign = true
            _ = view.resignFirstResponder()
            programmaticResign = false
        }
        autoShown = false
        userDismissed = false
        lastHint = 0; lastPurpose = 0; lastEnabled = 0
        clearStickyMods()
        applyTraits(hint: 0, purpose: 0, enabled: 0)
    }

    // MARK: TRAITS -> keyboard policy

    /// TRAITS enable raises the keyboard, disable lowers it, but a keyboard the user
    /// opened or dismissed stays user-owned, and a focus hop (disable then enable
    /// back to back) is debounced 200 ms so it does not bounce (invariant 46).
    private func updateAuto(enabled: Bool) {
        if enabled {
            hideTimer?.invalidate()
            hideTimer = nil
            if !view.isFirstResponder && !userDismissed {
                if view.becomeFirstResponder() { autoShown = true }
            }
        } else {
            userDismissed = false   // focus left the field; the next enable may raise again
            guard autoShown, hideTimer == nil else { return }
            hideTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.hideTimer = nil
                guard self.autoShown else { return }
                self.programmaticResign = true
                _ = self.view.resignFirstResponder()
                self.programmaticResign = false
                self.autoShown = false
            }
        }
    }

    func applyTraits(hint: UInt32, purpose: UInt32, enabled: UInt32) {
        updateAuto(enabled: enabled != 0)   // before the change guard: see osk-plan.md
        guard hint != lastHint || purpose != lastPurpose || enabled != lastEnabled else { return }
        lastHint = hint
        lastPurpose = purpose
        lastEnabled = enabled

        if enabled == 0 {
            view.isSecureTextEntry = false
            view.keyboardType = .default
            view.returnKeyType = .default
            view.autocorrectionType = .no
            view.spellCheckingType = .no
            view.autocapitalizationType = .none
            if view.isFirstResponder { view.reloadInputViews() }
            return
        }

        let completion = (hint & 0x1) != 0
        let spellcheck = (hint & 0x2) != 0
        let autoCaps = (hint & 0x4) != 0
        let uppercase = (hint & 0x10) != 0
        let titlecase = (hint & 0x20) != 0
        let hidden = (hint & 0x40) != 0
        let sensitive = (hint & 0x80) != 0
        let multiline = (hint & 0x200) != 0
        // Secure entry when hidden, sensitive, or purpose password/pin (8/9).
        let secure = hidden || sensitive || purpose == 8 || purpose == 9

        view.isSecureTextEntry = secure
        view.keyboardType = .default
        view.returnKeyType = multiline ? .default : .done
        view.autocorrectionType = (!secure && completion) ? .yes : .no
        view.spellCheckingType = (!secure && spellcheck) ? .yes : .no
        view.autocapitalizationType = .none

        switch purpose {
        case 2, 9:
            view.keyboardType = .numberPad
        case 3:
            view.keyboardType = .numbersAndPunctuation
        case 4:
            view.keyboardType = .phonePad
        case 5:
            view.keyboardType = .URL
            view.returnKeyType = .go
        case 6:
            view.keyboardType = .emailAddress
        case 8:
            view.keyboardType = .asciiCapable
        case 13:
            view.keyboardType = .asciiCapable
            view.returnKeyType = .default
            view.autocorrectionType = .no
            view.spellCheckingType = .no
        default:
            break
        }

        if uppercase {
            view.autocapitalizationType = .allCharacters
        } else if titlecase {
            view.autocapitalizationType = .words
        } else if autoCaps {
            view.autocapitalizationType = .sentences
        }
        if view.isFirstResponder { view.reloadInputViews() }
    }

    // MARK: typed input -> wire

    static func modifierBits(ctrl: Bool, alt: Bool, shift: Bool) -> UInt32 {
        var mods: UInt32 = 0
        if shift { mods |= 1 }; if ctrl { mods |= 2 }; if alt { mods |= 4 }
        return mods
    }

    /// Accessory and OSK keys are taps. Hardware keys keep independent down/up
    /// transitions through XiosHardwareKeyboard.
    func sendKeysym(_ keysym: UInt32, ctrl: Bool, alt: Bool, shift: Bool) {
        view.inputLink?.keyTap(keysym, mods: Self.modifierBits(ctrl: ctrl, alt: alt, shift: shift))
    }

    func insertText(_ text: String) {
        guard view.inputLink != nil else { return }
        if view.hardwareKeyboard.isLikelyUIKitEcho() { return }
        if !modCtrl && !modAlt && !modShift {
            sendTextWithKeyBreaks(text)
            return
        }
        for ch in text {
            if let ks = Self.keysym(for: ch) {
                // Sticky mods apply to the first typed key, then auto-clear.
                sendKeysym(ks, ctrl: modCtrl, alt: modAlt, shift: modShift)
                clearStickyMods()
            }
        }
        clearStickyMods()
    }

    func deleteBackward() {
        guard view.inputLink != nil else { return }
        if view.hardwareKeyboard.isLikelyUIKitEcho() { return }
        sendKeysym(0xff08, ctrl: modCtrl, alt: modAlt, shift: modShift)   // XK_BackSpace
        clearStickyMods()
    }

    /// Text path, but with Return and Tab broken out as real key taps (invariant 45).
    /// The desktop commits a TEXT record into the focused field verbatim, so a
    /// committed "\n" would land as a literal newline: the iOS keyboard's Done/Go key
    /// would type into a browser address bar instead of submitting it, and Tab would
    /// insert whitespace instead of moving focus. Everything the iOS keyboard is
    /// actually good at (emoji, dictation, autocorrect replacements) still rides TEXT.
    func sendTextWithKeyBreaks(_ text: String) {
        var run = ""
        for ch in text {
            guard ch == "\n" || ch == "\r" || ch == "\t" else { run.append(ch); continue }
            if !run.isEmpty { view.inputLink?.text(run); run = "" }
            sendKeysym(ch == "\t" ? 0xff09 : 0xff0d, ctrl: false, alt: false, shift: false)
        }
        if !run.isEmpty { view.inputLink?.text(run) }
    }

    /// Latin-1 keysyms equal the codepoint for 0x20-0xff; Return/Tab are explicit.
    private static func keysym(for ch: Character) -> UInt32? {
        if ch == "\n" || ch == "\r" { return 0xff0d }   // XK_Return
        if ch == "\t" { return 0xff09 }                 // XK_Tab
        let scalars = ch.unicodeScalars
        guard scalars.count == 1, let v = scalars.first?.value else { return nil }
        if (0x20...0x7e).contains(v) || (0xa0...0xff).contains(v) { return v }
        return nil
    }

    /// A non-text key (Esc/Tab/arrows) with the armed sticky modifiers, then clear them.
    private func sendSpecial(_ ks: UInt32) {
        guard view.inputLink != nil else { return }
        sendKeysym(ks, ctrl: modCtrl, alt: modAlt, shift: modShift)
        clearStickyMods()
    }

    private func clearStickyMods() {
        guard modCtrl || modAlt || modShift else { return }
        modCtrl = false; modAlt = false; modShift = false
        styleSticky(ctrlBtn, on: false)
        styleSticky(altBtn, on: false)
        styleSticky(shiftBtn, on: false)
    }

    private func styleSticky(_ b: UIButton?, on: Bool) {
        b?.backgroundColor = on ? .systemBlue : UIColor(white: 0.28, alpha: 1)
    }

    // MARK: modifier row

    private func buildModRow() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48),
                              inputViewStyle: .keyboard)
        bar.autoresizingMask = .flexibleWidth

        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])

        stack.addArrangedSubview(keycap("esc") { [weak self] in self?.sendSpecial(0xff1b) })
        stack.addArrangedSubview(keycap("tab") { [weak self] in self?.sendSpecial(0xff09) })

        let ctrl = keycap("ctrl") { [weak self] in
            guard let self else { return }
            self.modCtrl.toggle(); self.styleSticky(self.ctrlBtn, on: self.modCtrl)
        }
        let alt = keycap("alt") { [weak self] in
            guard let self else { return }
            self.modAlt.toggle(); self.styleSticky(self.altBtn, on: self.modAlt)
        }
        let shift = keycap("shift") { [weak self] in
            guard let self else { return }
            self.modShift.toggle(); self.styleSticky(self.shiftBtn, on: self.modShift)
        }
        ctrlBtn = ctrl; altBtn = alt; shiftBtn = shift
        [ctrl, alt, shift].forEach { stack.addArrangedSubview($0) }

        stack.addArrangedSubview(keycap("\u{2190}") { [weak self] in self?.sendSpecial(0xff51) })
        stack.addArrangedSubview(keycap("\u{2191}") { [weak self] in self?.sendSpecial(0xff52) })
        stack.addArrangedSubview(keycap("\u{2193}") { [weak self] in self?.sendSpecial(0xff54) })
        stack.addArrangedSubview(keycap("\u{2192}") { [weak self] in self?.sendSpecial(0xff53) })
        return bar
    }

    private func keycap(_ title: String, _ action: @escaping () -> Void) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 12)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
            var attrs = attrs
            attrs.font = .systemFont(ofSize: 15, weight: .medium)
            return attrs
        }
        let b = UIButton(configuration: config)
        b.backgroundColor = UIColor(white: 0.28, alpha: 1)
        b.layer.cornerRadius = 6
        b.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return b
    }
}
