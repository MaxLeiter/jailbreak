import UIKit

/// Open an app in one desktop. ioscd's APPS_LIST is the only catalog: the same
/// launchers that get home-screen icons, with names and commands. The launch goes
/// to `connection`'s slot (ioscd takes the slot field for `app`).
final class AppPickerViewController: UITableViewController, UISearchResultsUpdating {
    private let connection: SessionConnection
    private var all: [LauncherApp] = []
    private var shown: [LauncherApp] = []
    private var status: String? = "Loading apps..."
    private let search = UISearchController(searchResultsController: nil)

    init(connection: SessionConnection) {
        self.connection = connection
        super.init(style: .plain)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        tableView.backgroundColor = Style.background
        title = "Open App in \(connection.info.title)"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction {
            [weak self] _ in self?.dismiss(animated: true)
        })
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search apps"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "app")
        load()
    }

    private func load() {
        IOSCDClient.shared.appsList { [weak self] list in
            guard let self else { return }
            self.all = list.apps.filter(\.enabled)
            self.status = list.error ?? (self.all.isEmpty ? "ioscd reported no launchable apps." : nil)
            self.updateSearchResults(for: self.search)
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let needle = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        shown = needle.isEmpty ? all : all.filter {
            $0.name.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
            $0.exec.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
            $0.id.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        shown.isEmpty ? (status == nil ? 0 : 1) : shown.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.backgroundColor = Style.card
        cell.textLabel?.textColor = .white
        cell.detailTextLabel?.textColor = Style.secondaryText
        if shown.isEmpty {
            cell.textLabel?.text = status
            cell.textLabel?.numberOfLines = 0
            cell.selectionStyle = .none
            return cell
        }
        let app = shown[indexPath.row]
        cell.textLabel?.text = app.name
        cell.detailTextLabel?.text = app.exec
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !shown.isEmpty else { return }
        let app = shown[indexPath.row]
        SessionManager.shared.openApp(app, in: connection) { [weak self] accepted in
            // Keep the sheet open on a rejected request so the daemon's error (shown
            // by the launcher's toast) stays in view.
            if accepted { self?.dismiss(animated: true) }
        }
    }
}
