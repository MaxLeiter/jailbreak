import UIKit

/// The + New Desktop sheet: pick KDE, GNOME or Shell and a screen size, with the
/// memory estimate in front of you. One desktop per preset: when one is already up
/// the primary action opens it instead of starting a second. Only installed
/// flavors can be picked; the others are listed underneath with the package that
/// provides them (SessionManager.presetAvailability).
final class NewDesktopViewController: FormViewController {
    private let manager = SessionManager.shared
    private var preset = DesktopCatalog.primary[0]
    private var display: DisplayProfile? = .landscape
    private var sizePicker: SizePickerView?
    private var start: UIButton?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "New Desktop"
        navigationItem.rightBarButtonItem = closeButtonItem()
        manager.onPresetAvailabilityChanged = { [weak self] in self?.rebuild() }
        manager.refreshPresetAvailability()
        rebuild()
    }

    /// Installed, or already running (a desktop whose package went away while it
    /// ran can still be opened).
    private func offered(_ p: DesktopPreset) -> Bool {
        manager.presetAvailability.isInstalled(p.preset) || manager.liveSession(preset: p.preset) != nil
    }

    private func rebuild() {
        clearForm()
        let available = DesktopCatalog.primary.filter(offered)
        let missing = DesktopCatalog.primary.filter { !offered($0) }
        if !offered(preset), let first = available.first { preset = first }
        defer { listMissing(missing) }
        guard !available.isEmpty else {
            section("Desktop")
            note("No desktop flavor is installed. Install xios-kde, xios-gnome or xios-core from the package manager.",
                 color: .systemOrange)
            start = nil
            return
        }
        section("Desktop")
        for p in available {
            let live = manager.liveSession(preset: p.preset)
            let starting = live == nil && manager.isStarting(preset: p.preset)
            let memory = p.memory.map { "Memory: \($0)" } ?? "Memory: not measured yet"
            let detail = live != nil ? "Already running. Opening it instead of starting another."
                : (starting ? "Starting now..." : "\(p.detail). \(memory)")
            _ = row(title: p.title, detail: detail, symbol: p.symbol,
                    selected: p.preset == preset.preset) { [weak self] in
                self?.preset = p
                self?.rebuild()
            }
        }

        let existing = manager.liveSession(preset: preset.preset)
        if existing == nil {
            section("Screen Size")
            let picker = SizePickerView(initial: display)
            picker.onChange = { [weak self] profile in
                self?.display = profile
                self?.start?.isEnabled = self?.sizePicker?.isValid ?? true
            }
            sizePicker = picker
            stack.addArrangedSubview(picker)
            note("Default lets the desktop pick its own size.")
        } else {
            sizePicker = nil
        }

        let title = existing != nil ? "Open \(preset.title)" : "Start \(preset.title)"
        let go = pill(title, selected: true) { [weak self] in self?.go() }
        start = go
        if existing == nil, manager.isStarting(preset: preset.preset) { go.isEnabled = false }
        stack.setCustomSpacing(18, after: stack.arrangedSubviews.last ?? go)
        stack.addArrangedSubview(go)
    }

    /// The flavors that cannot start, and what to install for each. Not tappable.
    private func listMissing(_ missing: [DesktopPreset]) {
        guard !missing.isEmpty else { return }
        if let last = stack.arrangedSubviews.last { stack.setCustomSpacing(24, after: last) }
        section("Not Installed")
        for p in missing {
            _ = row(title: p.title, detail: PresetProbe.installHint(for: p.preset), symbol: p.symbol,
                    enabled: false) {}
        }
    }

    private func go() {
        if let existing = manager.liveSession(preset: preset.preset) {
            dismiss(animated: true) { [manager] in manager.present(existing) }
            return
        }
        guard sizePicker?.isValid ?? true else { return }
        let chosen = display, preset = preset.preset
        dismiss(animated: true) { [manager] in
            manager.startDesktop(preset: preset, display: chosen)
        }
    }
}

/// Change a running desktop's size (restarts that desktop at the new size).
final class ChangeSizeViewController: FormViewController {
    private let connection: SessionConnection
    private var display: DisplayProfile?
    private var picker: SizePickerView?

    init(connection: SessionConnection) {
        self.connection = connection
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Change Size"
        navigationItem.rightBarButtonItem = closeButtonItem()
        display = connection.info.requestedProfile
        section(connection.info.title)
        let p = SizePickerView(initial: display)
        p.onChange = { [weak self] in self?.display = $0 }
        picker = p
        stack.addArrangedSubview(p)
        note("The desktop restarts at the new size. Open windows are lost.")
        stack.addArrangedSubview(pill("Restart at This Size", selected: true) { [weak self] in
            guard let self, self.picker?.isValid ?? true, let display = self.display else {
                self?.note("Pick a size first.", color: .systemOrange)
                return
            }
            let connection = self.connection
            self.dismiss(animated: true) { SessionManager.shared.resize(connection, to: display) }
        })
    }
}
