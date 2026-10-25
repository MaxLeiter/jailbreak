import UIKit

/// Keys and clicks the touchscreen cannot send: Esc/Tab/arrows, modifier
/// combinations, text, middle/right click and the wheel. Everything goes to the
/// desktop on glass through the PresentView.
final class KeyPadViewController: FormViewController {
    private unowned let target: PresentView
    private var ctrl = false, alt = false, shift = false
    private var ctrlButton: UIButton?, altButton: UIButton?, shiftButton: UIButton?

    init(target: PresentView) {
        self.target = target
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var maxContentWidth: CGFloat { 560 }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Keyboard Pad"
        navigationItem.rightBarButtonItem = closeButtonItem()

        section("Send Text")
        let field = textField("Text")
        stack.addArrangedSubview(field)
        buttonRow([
            pill("Send Text") { [weak self, weak field] in
                self?.target.send(text: field?.text ?? "")
                field?.text = ""
            },
            pill("Paste") { [weak self] in
                self?.target.send(text: UIPasteboard.general.string ?? "")
            },
        ])

        section("Keys")
        note("Modifiers stay armed until you tap them again.")
        let c = pill("Ctrl") { [weak self] in self?.toggle(\.ctrl, self?.ctrlButton) }
        let a = pill("Alt") { [weak self] in self?.toggle(\.alt, self?.altButton) }
        let s = pill("Shift") { [weak self] in self?.toggle(\.shift, self?.shiftButton) }
        ctrlButton = c; altButton = a; shiftButton = s
        buttonRow([c, a, s])
        buttonRow([key("Esc", 0xff1b), key("Tab", 0xff09), key("Enter", 0xff0d), key("Back", 0xff08)])
        buttonRow([key("Left", 0xff51), key("Up", 0xff52), key("Down", 0xff54), key("Right", 0xff53)])
        buttonRow([key("Home", 0xff50), key("End", 0xff57), key("PgUp", 0xff55), key("PgDn", 0xff56)])

        section("Mouse")
        buttonRow([
            pill("Left Click") { [weak self] in self?.target.sendClick(button: 1) },
            pill("Middle") { [weak self] in self?.target.sendClick(button: 2) },
            pill("Right") { [weak self] in self?.target.sendClick(button: 3) },
        ])
        buttonRow([
            pill("Wheel Up") { [weak self] in self?.target.sendWheel(button: 4) },
            pill("Wheel Down") { [weak self] in self?.target.sendWheel(button: 5) },
            pill("Wheel Left") { [weak self] in self?.target.sendWheel(button: 6) },
            pill("Wheel Right") { [weak self] in self?.target.sendWheel(button: 7) },
        ])
    }

    private func key(_ title: String, _ keysym: UInt32) -> UIButton {
        pill(title) { [weak self] in
            guard let self else { return }
            self.target.send(keysym: keysym, ctrl: self.ctrl, alt: self.alt, shift: self.shift)
        }
    }

    private func toggle(_ path: ReferenceWritableKeyPath<KeyPadViewController, Bool>, _ button: UIButton?) {
        self[keyPath: path].toggle()
        var config = button?.configuration
        config?.baseBackgroundColor = self[keyPath: path]
            ? Style.accent.withAlphaComponent(0.85) : UIColor(white: 0.24, alpha: 1)
        button?.configuration = config
    }
}
