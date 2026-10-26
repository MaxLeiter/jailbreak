import UIKit

/// Launcher <-> Desktop. The launcher is home; a presented desktop covers it
/// completely. The desktop view (a Metal layer) only lives in the hierarchy while a
/// desktop is presented, so home costs no drawable memory.
final class RootViewController: UIViewController {
    private let manager = SessionManager.shared
    private let launcher = UINavigationController(rootViewController: LauncherViewController())
    private var desktop: DesktopViewController?
    private var showingDesktop = false

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { showingDesktop }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Process-wide observers (volume, appearance, orientation) live on a view
        // that is always in the window; the wire to each desktop is per session.
        SystemIntegration.shared.install(on: view)
        launcher.navigationBar.prefersLargeTitles = true
        launcher.overrideUserInterfaceStyle = .dark
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        launcher.navigationBar.standardAppearance = appearance
        launcher.navigationBar.scrollEdgeAppearance = appearance
        addChild(launcher)
        launcher.view.frame = view.bounds
        launcher.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(launcher.view)
        launcher.didMove(toParent: self)

        manager.onPresentedChanged = { [weak self] connection in self?.presentedChanged(connection) }
        // Built up front so the manager always has a presenter to talk to (it is
        // cheap: the Metal layer gets no drawable until it is on screen).
        _ = ensureDesktop()
    }

    private func presentedChanged(_ connection: SessionConnection?) {
        guard connection != nil else { showLauncher(); return }
        showDesktop()
    }

    private func ensureDesktop() -> DesktopViewController? {
        if let desktop { return desktop }
        guard let renderer = manager.renderer else { return nil }
        let controller = DesktopViewController(manager: manager, renderer: renderer)
        desktop = controller
        addChild(controller)
        controller.didMove(toParent: self)
        manager.presenter = controller.presentView
        A11yBridge.shared.startup(view: controller.presentView)
        return controller
    }

    private func showDesktop() {
        guard let desktop = ensureDesktop() else { return }
        showingDesktop = true
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        desktop.view.frame = view.bounds
        desktop.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        if desktop.view.superview == nil { view.addSubview(desktop.view) }
        UIView.performWithoutAnimation { view.layoutIfNeeded() }
        desktop.setPresenting(true)
        // The launcher stays underneath until the first frame is up; covering it
        // right away avoids a flash of cards behind a black desktop.
        desktop.view.alpha = 1
    }

    private func showLauncher() {
        showingDesktop = false
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        desktop?.setPresenting(false)
        desktop?.view.removeFromSuperview()
    }

    func setBackgrounded(_ backgrounded: Bool) {
        // A background launch had no GPU; the desktop could not be built then.
        if !backgrounded { _ = ensureDesktop() }
        desktop?.setBackgrounded(backgrounded)
    }
}

/// Holds the PresentView and the one modal that goes over it (the switcher sheet).
final class DesktopViewController: UIViewController {
    let presentView: PresentView
    private let manager: SessionManager
    private var backgrounded = false
    private var presenting = false

    init(manager: SessionManager, renderer: Renderer) {
        self.manager = manager
        presentView = PresentView(manager: manager)
        super.init(nibName: nil, bundle: nil)
        presentView.bind(renderer: renderer)
        presentView.onOpenSwitcher = { [weak self] in self?.openSwitcher() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() { view = presentView }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    func setPresenting(_ on: Bool) {
        presenting = on
        presentView.setPresenting(on && !backgrounded)
        if !on, presentedViewController != nil { dismiss(animated: false) }
    }

    func setBackgrounded(_ on: Bool) {
        backgrounded = on
        presentView.setPresenting(presenting && !on)
    }

    private func openSwitcher() {
        guard presentedViewController == nil else { return }
        let nav = UINavigationController(rootViewController: SwitcherViewController(presentView: presentView))
        nav.overrideUserInterfaceStyle = .dark
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }
}
