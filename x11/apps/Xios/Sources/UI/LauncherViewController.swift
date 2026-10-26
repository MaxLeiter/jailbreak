import UIKit

/// What the app opens to: a grid of desktop cards plus "+ New Desktop", and one
/// Settings row. Tap a card to go full screen into it; long-press for Stop, Open
/// app in it, Change size (or Restart for a desktop that failed or was killed).
final class LauncherViewController: UIViewController, UICollectionViewDelegate {
    private enum Item: Hashable {
        case session(String)
        case new
        case settings
    }
    private enum Section: Int { case desktops, settings }

    private let manager = SessionManager.shared
    private var collection: UICollectionView!
    private var data: UICollectionViewDiffableDataSource<Section, Item>!
    private var refreshScheduled = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Style.background
        overrideUserInterfaceStyle = .dark
        title = "Desktops"
        navigationItem.largeTitleDisplayMode = .always

        let layout = UICollectionViewCompositionalLayout { [weak self] index, env in
            self?.layoutSection(index, env) ?? NSCollectionLayoutSection(group: NSCollectionLayoutGroup(
                layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(1))))
        }
        collection = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.backgroundColor = .clear
        collection.delegate = self
        collection.alwaysBounceVertical = true
        view.addSubview(collection)

        let card = UICollectionView.CellRegistration<DesktopCardCell, String> { [weak self] cell, _, slot in
            guard let self, let conn = self.manager.session(slot: slot) else { return }
            cell.configure(with: conn, isPresented: conn === self.manager.presented)
            cell.onRestart = { [weak self] in self?.manager.restart(conn) }
        }
        let newCard = UICollectionView.CellRegistration<NewDesktopCell, Item> { cell, _, _ in
            cell.configure()
        }
        let settingsRow = UICollectionView.CellRegistration<SettingsRowCell, Item> { cell, _, _ in
            cell.configure()
        }
        data = UICollectionViewDiffableDataSource(collectionView: collection) {
            collectionView, indexPath, item in
            switch item {
            case .session(let slot):
                return collectionView.dequeueConfiguredReusableCell(using: card, for: indexPath, item: slot)
            case .new:
                return collectionView.dequeueConfiguredReusableCell(using: newCard, for: indexPath, item: item)
            case .settings:
                return collectionView.dequeueConfiguredReusableCell(using: settingsRow, for: indexPath, item: item)
            }
        }

        manager.onSessionsChanged = { [weak self] in self?.scheduleRefresh() }
        manager.onMessage = { [weak self] text in
            guard let self else { return }
            if self.manager.presented != nil {
                // The launcher is hidden under a desktop: speak through its pill.
                (self.manager.presenter as? PresentView)?.showMessage(text)
            } else if self.view.window != nil {
                Toast.show(text, in: self.view)
            }
        }
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        manager.registry.refreshNow()
    }

    // MARK: layout

    private func layoutSection(_ index: Int, _ env: NSCollectionLayoutEnvironment) -> NSCollectionLayoutSection {
        let width = env.container.effectiveContentSize.width
        if Section(rawValue: index) == .settings {
            let item = NSCollectionLayoutItem(layoutSize: .init(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(56)))
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(56)), subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 20, bottom: 24, trailing: 20)
            return section
        }
        let columns = width >= 1000 ? 3 : (width >= 620 ? 2 : 1)
        let item = NSCollectionLayoutItem(layoutSize: .init(
            widthDimension: .fractionalWidth(1.0 / CGFloat(columns)), heightDimension: .estimated(250)))
        item.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(
            widthDimension: .fractionalWidth(1), heightDimension: .estimated(250)),
            repeatingSubitem: item, count: columns)
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 0, trailing: 12)
        return section
    }

    // MARK: data

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    /// Apply the current sessions. Cards are reconfigured in place (never reloaded)
    /// so an open context menu survives a state change underneath it.
    private func refresh() {
        guard isViewLoaded else { return }
        let slots = manager.sessions.map(\.slot)
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.desktops, .settings])
        snapshot.appendItems(slots.map { .session($0) } + [.new], toSection: .desktops)
        snapshot.appendItems([.settings], toSection: .settings)
        let existing = Set(data.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
        data.apply(snapshot, animatingDifferences: false)
    }

    // MARK: actions

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = data.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .session(let slot):
            guard let conn = manager.session(slot: slot) else { return }
            // A dead desktop has nothing to show: its card carries Restart.
            if conn.info.state.isTerminal {
                Toast.show(conn.info.message.isEmpty ? conn.info.state.title : conn.info.message, in: view)
                return
            }
            manager.present(conn)
        case .new:
            let nav = UINavigationController(rootViewController: NewDesktopViewController())
            nav.modalPresentationStyle = .formSheet
            present(nav, animated: true)
        case .settings:
            navigationController?.pushViewController(SettingsViewController(), animated: true)
        }
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemAt indexPath: IndexPath,
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .session(let slot)? = data.itemIdentifier(for: indexPath),
              let conn = manager.session(slot: slot) else { return nil }
        return UIContextMenuConfiguration(identifier: slot as NSString, previewProvider: nil) {
            [weak self] _ in self?.menu(for: conn)
        }
    }

    private func menu(for conn: SessionConnection) -> UIMenu {
        var actions: [UIMenuElement] = []
        let state = conn.info.state
        if state.isTerminal {
            actions.append(UIAction(title: "Restart", image: UIImage(systemName: "arrow.clockwise"),
                                    attributes: manager.canRestart(conn) ? [] : [.disabled]) {
                [manager] _ in manager.restart(conn)
            })
            actions.append(UIAction(title: "Dismiss", image: UIImage(systemName: "xmark.circle"),
                                    attributes: [.destructive]) { [manager] _ in manager.dismiss(conn) })
            return UIMenu(children: actions)
        }
        actions.append(UIAction(title: "Open", image: UIImage(systemName: "arrow.up.forward.app")) {
            [manager] _ in manager.present(conn)
        })
        let runnable = state == .running
        actions.append(UIAction(title: "Open App in It...", image: UIImage(systemName: "square.grid.2x2"),
                                attributes: runnable ? [] : [.disabled]) { [weak self] _ in
            self?.presentAppPicker(for: conn)
        })
        let sizes = DisplayProfile.standard.map { profile in
            UIAction(title: "\(profile.name) \(profile.detail)") { [manager] _ in
                manager.resize(conn, to: profile)
            }
        } + [UIAction(title: "Custom...") { [weak self] _ in self?.presentChangeSize(for: conn) }]
        let sizeMenu = UIMenu(title: "Change Size", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"),
                              children: sizes)
        // An unknown desktop type cannot be restarted safely, so no size change either.
        if manager.canRestart(conn) {
            actions.append(sizeMenu)
        } else {
            actions.append(UIAction(title: "Change Size", image: sizeMenu.image,
                                    attributes: [.disabled]) { _ in })
        }
        let stopTitle = conn.info.isLegacyMain ? "Stop Main" : "Stop"
        actions.append(UIAction(title: stopTitle, image: UIImage(systemName: "stop.circle"),
                                attributes: [.destructive]) { [weak self] _ in self?.confirmStop(conn) })
        return UIMenu(children: actions)
    }

    private func presentAppPicker(for conn: SessionConnection) {
        let nav = UINavigationController(rootViewController: AppPickerViewController(connection: conn))
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func presentChangeSize(for conn: SessionConnection) {
        let nav = UINavigationController(rootViewController: ChangeSizeViewController(connection: conn))
        nav.modalPresentationStyle = .formSheet
        present(nav, animated: true)
    }

    private func confirmStop(_ conn: SessionConnection) {
        StopConfirmation.present(for: conn, from: self)
    }
}

/// The one confirmation every Stop goes through (launcher menu and switcher).
enum StopConfirmation {
    static func title(for conn: SessionConnection) -> String {
        conn.info.isLegacyMain ? "Stop Main" : "Stop \(conn.info.title)"
    }

    static func present(for conn: SessionConnection, from vc: UIViewController) {
        let manager = SessionManager.shared
        // Main has no slot: an unqualified stop ends the non-slot session. Since M0
        // the desktops in their own slots keep running, and the Xios app and shared
        // services only go with it when no slot is alive.
        let others = manager.sessions.filter { $0 !== conn && $0.info.state != .stopped }.count
        let message = conn.info.isLegacyMain
            ? (others > 0 ? "Desktops in their own slots keep running. Open windows in Main are lost."
                          : "Nothing else is running, so the shared desktop services stop too. Open windows are lost.")
            : "Open windows in it are lost."
        let alert = UIAlertController(title: "\(title(for: conn))?", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Stop", style: .destructive) { _ in manager.stop(conn) })
        vc.present(alert, animated: true)
    }
}

// MARK: - cells

final class DesktopCardCell: UICollectionViewCell {
    var onRestart: (() -> Void)?

    private let thumb = UIImageView()
    private let placeholder = UIImageView()
    private let dim = UIView()
    private let dot = UIView()
    private let title = UILabel()
    private let detail = UILabel()
    private let reason = UILabel()
    private let restart = UIButton(type: .system)
    private let badge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Style.card
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.clipsToBounds = true

        thumb.contentMode = .scaleAspectFill
        thumb.clipsToBounds = true
        thumb.backgroundColor = .black
        placeholder.tintColor = UIColor(white: 0.35, alpha: 1)
        placeholder.contentMode = .center
        placeholder.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 38)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        dot.layer.cornerRadius = 5
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        title.textColor = .white
        detail.font = .systemFont(ofSize: 13)
        detail.textColor = Style.secondaryText
        reason.font = .systemFont(ofSize: 12)
        reason.textColor = .systemRed
        reason.numberOfLines = 3
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = Style.accent
        badge.layer.cornerRadius = 8
        badge.layer.masksToBounds = true
        badge.textAlignment = .center
        badge.text = "  ON SCREEN  "

        var config = UIButton.Configuration.filled()
        config.title = "Restart"
        config.cornerStyle = .capsule
        config.baseBackgroundColor = .systemRed.withAlphaComponent(0.6)
        config.baseForegroundColor = .white
        restart.configuration = config
        restart.addAction(UIAction { [weak self] _ in self?.onRestart?() }, for: .touchUpInside)

        let text = UIStackView(arrangedSubviews: [title, detail, reason, restart])
        text.axis = .vertical
        text.spacing = 4
        text.alignment = .leading
        text.setCustomSpacing(8, after: reason)
        // The dot sits in a box as tall as the title line so the stack can align it.
        let dotBox = UIView()
        dotBox.addSubview(dot)
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dotBox.widthAnchor.constraint(equalToConstant: 10),
            dotBox.heightAnchor.constraint(equalToConstant: 22),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),
            dot.leadingAnchor.constraint(equalTo: dotBox.leadingAnchor),
            dot.centerYAnchor.constraint(equalTo: dotBox.centerYAnchor),
        ])
        let stateRow = UIStackView(arrangedSubviews: [dotBox, text])
        stateRow.axis = .horizontal
        stateRow.alignment = .top
        stateRow.spacing = 10

        for v in [thumb, placeholder, dim, badge, stateRow] as [UIView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(v)
        }
        let aspect = thumb.heightAnchor.constraint(equalTo: thumb.widthAnchor, multiplier: 0.625)
        aspect.priority = .required
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: contentView.topAnchor),
            thumb.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            thumb.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            aspect,
            placeholder.centerXAnchor.constraint(equalTo: thumb.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: thumb.centerYAnchor),
            dim.topAnchor.constraint(equalTo: thumb.topAnchor),
            dim.bottomAnchor.constraint(equalTo: thumb.bottomAnchor),
            dim.leadingAnchor.constraint(equalTo: thumb.leadingAnchor),
            dim.trailingAnchor.constraint(equalTo: thumb.trailingAnchor),
            badge.topAnchor.constraint(equalTo: thumb.topAnchor, constant: 10),
            badge.trailingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: -10),
            badge.heightAnchor.constraint(equalToConstant: 18),
            stateRow.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 12),
            stateRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            stateRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            stateRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRestart = nil
    }

    func configure(with conn: SessionConnection, isPresented: Bool) {
        let info = conn.info
        thumb.image = conn.thumbnail
        placeholder.image = conn.thumbnail == nil ? UIImage(systemName: "display") : nil
        dim.isHidden = conn.thumbnail != nil && info.state == .running
        title.text = info.title
        dot.backgroundColor = Style.stateColor(info.state)
        badge.isHidden = !isPresented

        var parts = [info.state.title]
        if let size = info.requestedLogical ?? info.size.map({ "\($0.width)x\($0.height)" }) {
            parts.append(size.replacingOccurrences(of: "x", with: "\u{00d7}"))
        }
        if !info.isLegacyMain { parts.append(info.slot) } else { parts.append(info.subtitle) }
        detail.text = parts.joined(separator: " \u{00b7} ")

        let failed = info.state == .failed || info.state == .killed
        reason.isHidden = !failed
        restart.isHidden = !failed
        if failed {
            reason.text = info.message.isEmpty ? info.state.title : info.message
        }
    }
}

final class NewDesktopCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 16
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderWidth = 1.5
        contentView.layer.borderColor = UIColor.white.withAlphaComponent(0.22).cgColor
        contentView.backgroundColor = UIColor.white.withAlphaComponent(0.04)

        let icon = UIImageView(image: UIImage(systemName: "plus.circle.fill"))
        icon.tintColor = Style.accent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44)
        let label = UILabel()
        label.text = "New Desktop"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .white
        let stack = UIStackView(arrangedSubviews: [icon, label])
        stack.axis = .vertical
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure() {}
}

final class SettingsRowCell: UICollectionViewCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = Style.card
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        let icon = UIImageView(image: UIImage(systemName: "gearshape"))
        icon.tintColor = Style.secondaryText
        let label = UILabel()
        label.text = "Settings & Debug"
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .white
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = Style.secondaryText
        let row = UIStackView(arrangedSubviews: [icon, label, UIView(), chevron])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure() {}
}
