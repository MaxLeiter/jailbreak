import UIKit
import PhotosUI

/// Settings and Debug behind the one launcher row: render scale, diagnostics, home
/// screen app sync, the key pad, the Shell desktop's background and the developer
/// presets. Reachable from the launcher and from a desktop's switcher.
final class SettingsViewController: FormViewController, PHPickerViewControllerDelegate {
    private let manager = SessionManager.shared
    private weak var presentView: PresentView?
    private var debugView: UITextView?

    private static let wallpaperConfigPath = "/var/mobile/Library/Preferences/com.max.iosc-wallpaper"
    private static let wallpaperImagePath = "/var/mobile/Library/Preferences/com.max.iosc-wallpaper.jpg"

    init(presentView: PresentView? = nil) {
        self.presentView = presentView ?? (SessionManager.shared.presenter as? PresentView)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings & Debug"
        build()
    }

    private func build() {
        clearForm()

        section("Render Scale")
        if let renderer = manager.renderer {
            let chips = XiosUpscaleMode.selectable.map { mode in
                pill(mode.title, selected: renderer.upscaleMode == mode) { [weak self] in
                    // Choosing Off explicitly still records a preference, so it pins
                    // the app against a compositor that starts advertising a hint later.
                    renderer.setUpscalePreference(mode)
                    self?.build()
                }
            }
            buttonRow(chips)
            note(renderer.upscaleSummary)
            if renderer.hasUpscalePreference {
                _ = row(title: "Follow Session Setting") { [weak self] in
                    renderer.setUpscalePreference(nil)
                    self?.build()
                }
            }
        } else {
            note("The GPU is not available yet.")
        }

        section("Apps")
        _ = row(title: "Home Screen Apps", detail: "Choose which desktop apps get an iOS icon",
                symbol: "square.grid.3x3") { [weak self] in
            self?.navigationController?.pushViewController(HomeScreenAppsViewController(), animated: true)
        }

        section("Keyboard & Mouse")
        let canPad = presentView != nil && manager.presented != nil
        _ = row(title: "Keyboard Pad", detail: canPad ? "Esc, Tab, arrows, clicks and scroll"
                                                      : "Open a desktop first",
                symbol: "keyboard", enabled: canPad) { [weak self] in
            guard let self, let view = self.presentView else { return }
            self.navigationController?.pushViewController(KeyPadViewController(target: view), animated: true)
        }

        section("Shell Desktop Background")
        buttonRow([
            pill("Set Background...") { [weak self] in self?.pickWallpaper() },
            pill("Reset") { [weak self] in self?.resetWallpaper() },
        ])
        note("Applies to the Shell desktop. A running Shell restarts to pick it up.")

        section("Diagnostics")
        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = UIColor(white: 0.04, alpha: 1)
        text.textColor = UIColor(white: 0.86, alpha: 1)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.layer.cornerRadius = 10
        text.text = DebugReport.make(manager: manager, renderer: manager.renderer)
        text.heightAnchor.constraint(equalToConstant: 260).isActive = true
        debugView = text
        stack.addArrangedSubview(text)
        buttonRow([
            pill("Refresh") { [weak self] in
                guard let self else { return }
                self.debugView?.text = DebugReport.make(manager: self.manager, renderer: self.manager.renderer)
            },
            pill("Copy") { [weak self] in
                UIPasteboard.general.string = self?.debugView?.text
                self.map { Toast.show("Copied", in: $0.view) }
            },
            pill("Save File") { [weak self] in
                guard let self else { return }
                StatusWriter.shared.overwrite("xios-debug.txt", self.debugView?.text ?? "")
                Toast.show("Wrote xios-debug.txt", in: self.view)
            },
        ])

        section("Developer")
        note("Extra presets. Each starts in its own slot like any other desktop.")
        for p in DesktopCatalog.developer {
            let live = manager.liveSession(preset: p.preset)
            let installed = live != nil || manager.presetAvailability.isInstalled(p.preset)
            let detail = live != nil ? "Running. Opens it."
                : (installed ? p.detail : PresetProbe.installHint(for: p.preset))
            _ = row(title: p.title, detail: detail, symbol: p.symbol, enabled: installed) { [weak self] in
                if let live {
                    self?.dismissToLauncherThen { SessionManager.shared.present(live) }
                } else {
                    SessionManager.shared.startDesktop(preset: p.preset, display: nil)
                    self?.navigationController?.popViewController(animated: true)
                }
            }
        }
    }

    private func dismissToLauncherThen(_ work: @escaping () -> Void) {
        if presentingViewController != nil || navigationController?.presentingViewController != nil {
            dismiss(animated: true, completion: work)
        } else {
            work()
        }
    }

    // MARK: wallpaper (the Shell desktop's)

    private func pickWallpaper() {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        guard provider.canLoadObject(ofClass: UIImage.self) else {
            Toast.show("Selected item is not an image", in: view)
            return
        }
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, error in
            // The JPEG encode and the writes are file I/O: not on main.
            DispatchQueue.global(qos: .userInitiated).async {
                let result: String
                if let error {
                    result = "Wallpaper failed: \(error.localizedDescription)"
                } else if let image = object as? UIImage {
                    result = Self.saveWallpaper(image)
                } else {
                    result = "Selected item is not an image"
                }
                DispatchQueue.main.async { self?.wallpaperChanged(result) }
            }
        }
    }

    private static func saveWallpaper(_ image: UIImage) -> String {
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: (wallpaperImagePath as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
            guard let data = image.jpegData(compressionQuality: 0.92) else { return "Could not encode wallpaper" }
            try data.write(to: URL(fileURLWithPath: wallpaperImagePath), options: .atomic)
            try (wallpaperImagePath + "\n").write(toFile: wallpaperConfigPath, atomically: true, encoding: .utf8)
            return "Wallpaper set"
        } catch {
            return "Wallpaper failed: \(error.localizedDescription)"
        }
    }

    private func resetWallpaper() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: String
            do {
                try FileManager.default.removeItem(atPath: Self.wallpaperConfigPath)
                result = "Wallpaper reset"
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                        && error.code == NSFileNoSuchFileError {
                result = "Wallpaper reset"   // already the default
            } catch {
                result = "Reset wallpaper failed: \(error.localizedDescription)"
            }
            DispatchQueue.main.async { [weak self] in self?.wallpaperChanged(result) }
        }
    }

    private func wallpaperChanged(_ message: String) {
        Toast.show(message, in: view)
        guard message.hasPrefix("Wallpaper set") || message == "Wallpaper reset",
              let shell = manager.liveSession(preset: "iosc") else { return }
        manager.restart(shell)   // the Shell reads its background at start
    }
}

/// Which ioscd launcher apps get a home-screen icon, and the launcher sync itself.
final class HomeScreenAppsViewController: FormViewController {
    private var apps: [LauncherApp] = []
    private var error: String?
    private var query = ""
    private var loaded = false

    override var maxContentWidth: CGFloat { 720 }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Home Screen Apps"
        reload()
    }

    private func reload() {
        IOSCDClient.shared.appsList { [weak self] list in
            self?.apps = list.apps
            self?.error = list.error
            self?.loaded = true
            self?.build()
        }
    }

    private func build() {
        clearForm()
        if !loaded { note("Asking ioscd for the installed launcher set..."); return }
        if let error { note(error, color: .systemRed) }

        let search = UISearchTextField()
        search.placeholder = "Search launchers"
        search.text = query
        search.autocorrectionType = .no
        search.autocapitalizationType = .none
        search.addAction(UIAction { [weak self, weak search] _ in
            self?.query = search?.text ?? ""
            self?.buildList()
        }, for: .editingChanged)
        stack.addArrangedSubview(search)
        listAnchor = stack.arrangedSubviews.count
        buildList()

        section("Sync")
        buttonRow([
            pill("Dry Native") { [weak self] in self?.sync(native: true, dry: true, title: "Native Dry Run") },
            pill("Dry Classic") { [weak self] in self?.sync(native: false, dry: true, title: "Classic Dry Run") },
        ])
        buttonRow([
            pill("Apply Native") { [weak self] in self?.sync(native: true, dry: false, title: "Native Sync") },
            pill("Apply Classic") { [weak self] in self?.sync(native: false, dry: false, title: "Classic Sync") },
        ])
        buttonRow([pill("Refresh") { [weak self] in self?.loaded = false; self?.build(); self?.reload() }])
    }

    private var listAnchor = 0
    private var listViews: [UIView] = []

    private func buildList() {
        for v in listViews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        listViews = []
        let needle = query.trimmingCharacters(in: .whitespaces)
        let shown = needle.isEmpty ? apps : apps.filter {
            $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
            $0.exec.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
            $0.id.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        var insertAt = min(listAnchor, stack.arrangedSubviews.count)
        if shown.isEmpty {
            let l = label(apps.isEmpty ? "No launcher candidates were reported by ioscd."
                                       : "No launchers match \"\(needle)\".",
                          size: 13, color: Style.secondaryText)
            stack.insertArrangedSubview(l, at: insertAt)
            listViews.append(l)
            return
        }
        for app in shown {
            let v = appRow(app)
            stack.insertArrangedSubview(v, at: insertAt)
            insertAt += 1
            listViews.append(v)
        }
    }

    private func appRow(_ app: LauncherApp) -> UIView {
        let name = label(app.name, size: 15, weight: .semibold)
        let detail = label("\(app.exec)\n\(app.id)", size: 11, color: Style.secondaryText)
        detail.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        let text = UIStackView(arrangedSubviews: [name, detail])
        text.axis = .vertical
        text.spacing = 3
        let toggle = UISwitch()
        toggle.isOn = app.enabled
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            let requested = toggle.isOn
            toggle.isEnabled = false
            IOSCDClient.shared.setAppEnabled(app, enabled: requested) { failure in
                if let failure {
                    toggle.isEnabled = true
                    toggle.isOn = app.enabled
                    Toast.show("Launcher update failed: \(failure)", in: self.view)
                } else {
                    self.reload()
                }
            }
        }, for: .valueChanged)
        let row = UIStackView(arrangedSubviews: [text, toggle])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
        row.backgroundColor = app.enabled ? Style.card : UIColor(white: 0.10, alpha: 1)
        row.layer.cornerRadius = 12
        return row
    }

    private func sync(native: Bool, dry: Bool, title: String) {
        Toast.show("\(dry ? "Checking" : "Syncing") \(native ? "native" : "classic") launchers...", in: view)
        IOSCDClient.shared.syncLaunchers(native: native, dryRun: dry) { [weak self] result in
            guard let self else { return }
            let lines: [String]
            switch result {
            case .success(let reply): lines = reply
            case .failure(let failure):
                Toast.show("Launcher sync failed: \(failure)", in: self.view)
                return
            }
            let report = SyncReportViewController(title: title, lines: lines,
                                                  ok: lines.last == "APPS_END\t0")
            self.navigationController?.pushViewController(report, animated: true)
        }
    }
}

final class SyncReportViewController: FormViewController {
    private let report: String
    private let ok: Bool
    private let heading: String

    init(title: String, lines: [String], ok: Bool) {
        heading = title
        report = lines.joined(separator: "\n")
        self.ok = ok
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = heading
        note(ok ? "Finished." : "Finished with errors.", color: ok ? Style.secondaryText : .systemRed)
        let text = UITextView()
        text.isEditable = false
        text.backgroundColor = UIColor(white: 0.04, alpha: 1)
        text.textColor = UIColor(white: 0.86, alpha: 1)
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.layer.cornerRadius = 10
        text.text = report
        text.heightAnchor.constraint(equalToConstant: 360).isActive = true
        stack.addArrangedSubview(text)
    }
}
