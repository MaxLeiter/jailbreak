import UIKit

/// The sheet over a desktop (three-finger tap or a pull from the top edge): Home,
/// the other desktops, Apps, Keyboard pad, Stop. The desktop itself stays chrome-free.
final class SwitcherViewController: FormViewController {
    private let manager = SessionManager.shared
    private unowned let presentView: PresentView

    init(presentView: PresentView) {
        self.presentView = presentView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var maxContentWidth: CGFloat { 520 }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = manager.presented?.info.title ?? "Xios"
        navigationItem.rightBarButtonItem = closeButtonItem()
        build()
    }

    private func build() {
        clearForm()
        _ = row(title: "Home", detail: "Back to your desktops", symbol: "square.grid.2x2") { [weak self] in
            self?.dismiss(animated: true) { SessionManager.shared.goHome() }
        }

        let others = manager.sessions.filter { $0 !== manager.presented && !$0.info.state.isTerminal }
        if !others.isEmpty {
            section("Switch To")
            for conn in others {
                _ = row(title: conn.info.title,
                        detail: [conn.info.state.title, conn.info.subtitle].joined(separator: " \u{00b7} "),
                        symbol: "display") { [weak self] in
                    self?.dismiss(animated: true) { SessionManager.shared.present(conn) }
                }
            }
        }

        section("In This Desktop")
        _ = row(title: "Apps", detail: "Open an app in this desktop", symbol: "square.grid.3x3",
                enabled: manager.presented != nil) { [weak self] in
            guard let self, let conn = self.manager.presented else { return }
            self.navigationController?.pushViewController(AppPickerViewController(connection: conn),
                                                          animated: true)
        }
        _ = row(title: "Keyboard Pad", detail: "Esc, Tab, arrows, clicks and scroll", symbol: "keyboard") {
            [weak self] in
            guard let self else { return }
            self.navigationController?.pushViewController(KeyPadViewController(target: self.presentView),
                                                          animated: true)
        }
        _ = row(title: "Fit to Screen", detail: "Reset zoom", symbol: "arrow.up.left.and.arrow.down.right") {
            [weak self] in
            self?.presentView.fitToScreen()
            self?.dismiss(animated: true)
        }

        _ = row(title: "Settings & Debug", detail: "Render scale, diagnostics, home screen apps",
                symbol: "gearshape") { [weak self] in
            guard let self else { return }
            self.navigationController?.pushViewController(
                SettingsViewController(presentView: self.presentView), animated: true)
        }

        if let conn = manager.presented {
            section("Danger")
            let name = conn.info.isLegacyMain ? "Stop All Desktops" : "Stop \(conn.info.title)"
            _ = row(title: name, symbol: "stop.circle", destructive: true) { [weak self] in
                self?.dismiss(animated: true) { SessionManager.shared.stop(conn) }
            }
        }
    }
}
