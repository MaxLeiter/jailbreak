import UIKit

/// Host half of the AT-SPI -> VoiceOver bridge for the native flavor
/// (docs/native-ipados-a11y.md; bridge design in docs/a11y-plan.md). One client
/// per host process: connects to xios-a11yd, binds this host's app_id, and
/// publishes each window's mirrored subtree as UIAccessibilityElements on that
/// window's HostScreenView.
///
/// INERT until xios-a11yd ships: it only connects while VoiceOver is running,
/// and retries quietly if the socket is absent. Wire format is the authoritative
/// a11y-plan.md NDJSON schema: "t" discriminator, ids helper-assigned uint32
/// unique per generation.
final class HostA11yClient {
    static let shared = HostA11yClient()

    /// Fixed path, one listener for desktop and native clients. Never derive
    /// from $XDG_RUNTIME_DIR — ioscd points that at per-app private bus dirs.
    private let sockPath = "/var/jb/tmp/xios-a11y.sock"
    private let forcePath = "/var/jb/tmp/xios-a11y-force"
    private let logPath = "/var/jb/tmp/iosc-a11y-host.log"

    private var appID = ""
    private var exec = ""
    private var fd: Int32 = -1
    private var reader: Thread?
    private var running = false
    private let writeQueue = DispatchQueue(label: "iosc-a11y-write")

    /// helper window id -> store (main actor only).
    private var stores: [Int: HostA11yWindowStore] = [:]

    // MARK: lifecycle

    /// Called once from NativeManager.startup(). Arms the VoiceOver gate; the
    /// socket opens only while VoiceOver is on.
    func startup(appID: String, exec: String) {
        self.appID = appID
        self.exec = exec
        log("startup appid=\(appID) exec=\(exec)")
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncVoiceOver),
            name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        syncVoiceOver()
    }

    @objc private func syncVoiceOver() {
        let forced = FileManager.default.fileExists(atPath: forcePath)
        if UIAccessibility.isVoiceOverRunning || forced {
            log("enable gate voiceover=\(UIAccessibility.isVoiceOverRunning) forced=\(forced)")
            start()
        } else {
            log("disable gate voiceover=false forced=false")
            stop()
        }
    }

    private func start() {
        guard reader == nil else { return }
        running = true
        log("reader start")
        let t = Thread { [weak self] in self?.readerLoop() }
        t.name = "iosc-a11y-reader"
        t.stackSize = 256 * 1024
        reader = t
        t.start()
    }

    private func stop() {
        running = false
        if fd >= 0 { close(fd); fd = -1 }
        reader = nil
        stores.values.forEach { $0.unpublish() }
        stores.removeAll()
        log("reader stop")
    }

    // MARK: socket

    private func readerLoop() {
        var failures = 0
        while running {
            let s = connectUnixSocket(sockPath)
            if s < 0 {
                failures += 1
                if failures == 1 || failures % 10 == 0 {
                    log("connect pending path=\(sockPath) failures=\(failures)")
                }
                Thread.sleep(forTimeInterval: 2.0)
                continue
            }
            failures = 0
            fd = s
            log("connected path=\(sockPath); bind appid=\(appID) exec=\(exec)")
            send(["t": "bind", "appid": appID, "exec": exec])
            send(["t": "enable", "on": true])
            pump(s)
            log("socket closed")
            if fd >= 0 { close(fd); fd = -1 }
            DispatchQueue.main.async { [weak self] in
                self?.stores.values.forEach { $0.unpublish() }
                self?.stores.removeAll()
            }
        }
    }

    /// Read NDJSON lines until EOF/error; hop each decoded message to main.
    private func pump(_ s: Int32) {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while running {
            let n = read(s, &chunk, chunk.count)
            if n <= 0 { return }
            buf.append(contentsOf: chunk[0..<n])
            while let nl = buf.firstIndex(of: 0x0a) {
                let line = buf.subdata(in: buf.startIndex..<nl)
                buf.removeSubrange(buf.startIndex...nl)
                guard !line.isEmpty,
                      let m = try? JSONDecoder().decode(A11yMsg.self, from: line) else {
                    log("decode skip bytes=\(line.count)")
                    continue
                }
                DispatchQueue.main.async { [weak self] in self?.apply(m) }
            }
        }
    }

    fileprivate func log(_ message: String) {
        let line = "HostA11y \(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logPath),
           let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
        }
    }

    fileprivate func send(_ obj: [String: Any]) {
        writeQueue.async { [weak self] in
            guard let self, self.fd >= 0,
                  var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0a)
            data.withUnsafeBytes { _ = write(self.fd, $0.baseAddress, $0.count) }
        }
    }

    // MARK: element callbacks (main)

    fileprivate func activate(_ id: Int)            { send(["t": "activate", "id": id]) }
    fileprivate func action(_ id: Int, idx: Int)    { send(["t": "action", "id": id, "idx": idx]) }
    fileprivate func adjust(_ id: Int, dir: Int)    { send(["t": "adjust", "id": id, "dir": dir]) }
    fileprivate func scroll(_ id: Int, dir: String) { send(["t": "scroll", "id": id, "dir": dir]) }
    fileprivate func voFocus(_ id: Int)             { send(["t": "vo-focus", "id": id]) }

    // MARK: apply (main)

    private func apply(_ m: A11yMsg) {
        switch m.t {
        case "hello":
            log("hello gen=\(m.gen ?? -1)")
            break
        case "reset":
            log("reset gen=\(m.gen ?? -1)")
            stores.values.forEach { $0.unpublish() }
            stores.removeAll()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        case "window":
            guard let win = m.id else { break }
            log("window id=\(win) appid=\(m.appid ?? "") title=\(m.title ?? "")")
            let store = stores[win] ?? HostA11yWindowStore(winID: win, client: self)
            stores[win] = store
            store.title = m.title ?? store.title
            if let f = m.frame, f.count == 4 { store.size = CGSize(width: f[2], height: f[3]) }
            matchView(store)
        case "remove":
            guard let id = m.id else { break }
            if let store = stores[id] {          // a whole window went away
                store.unpublish()
                stores[id] = nil
                send(["t": "detach", "win": id])
            } else {
                for s in stores.values where s.remove(id) { break }
            }
        case "upsert":
            guard let id = m.id, let win = m.win, let store = stores[win] else { break }
            store.upsert(id: id, m: m)
        case "focus":
            guard let id = m.id else { break }
            for s in stores.values {
                if let el = s.element(id) {
                    UIAccessibility.post(notification: .layoutChanged, argument: el)
                    break
                }
            }
        case "announce":
            if let text = m.text {
                log("announce \(text)")
                UIAccessibility.post(notification: .announcement, argument: text)
            }
        case "tap":
            guard let x = m.x, let y = m.y else { break }
            let store = m.win.flatMap { stores[$0] } ?? stores.values.first { $0.view != nil }
            store?.view?.a11ySynthTap(x: Int32(x), y: Int32(y))
        default:
            log("unknown message type \(m.t)")
            print("iosc-a11y: unknown message type \(m.t)")
        }
    }

    /// Bind a helper window to a scene's view: title match first, then canvas
    /// size, then creation order (docs/native-ipados-a11y.md "Correlation").
    private func matchView(_ store: HostA11yWindowStore) {
        let taken = Set(stores.values.compactMap { $0 === store ? nil : $0.view.map(ObjectIdentifier.init) })
        let candidates = NativeManager.shared.a11yCandidates()
            .filter { !taken.contains(ObjectIdentifier($0.view)) }
        guard !candidates.isEmpty else { return }
        let pick = candidates.first { $0.title == store.title && !store.title.isEmpty }
            ?? candidates.first { $0.view.canvasSize == store.size }
            ?? candidates.first!
        if store.view !== pick.view {
            store.view = pick.view
            store.publish()
            log("attach win=\(store.winID) scene=\(pick.id) title=\(pick.title)")
            send(["t": "attach", "win": store.winID])
        }
    }
}

// MARK: - wire message (helper -> app)

private struct A11yMsg: Decodable {
    let t: String
    let id: Int?
    let win: Int?
    let parent: Int?
    let idx: Int?
    let role: String?
    let label: String?
    let value: String?
    let hint: String?
    let traits: [String]?
    let actions: [String]?
    let frame: [Double]?      // [x, y, w, h]; window-relative px on bound conns
    let title: String?
    let appid: String?
    let focused: Bool?
    let text: String?
    let x: Double?
    let y: Double?
    let gen: Int?
}

// MARK: - per-window element store

final class HostA11yWindowStore {
    let winID: Int
    var title = ""
    var size = CGSize.zero
    weak var view: HostScreenView?
    private unowned let client: HostA11yClient

    private struct Node { var parent: Int; var idx: Int; let el: HostA11yElement }
    private var nodes: [Int: Node] = [:]
    private var flattenScheduled = false

    init(winID: Int, client: HostA11yClient) {
        self.winID = winID
        self.client = client
    }

    func element(_ id: Int) -> HostA11yElement? { nodes[id]?.el }

    fileprivate func upsert(id: Int, m: A11yMsg) {
        let el: HostA11yElement
        if let n = nodes[id] {
            el = n.el
            nodes[id] = Node(parent: m.parent ?? n.parent, idx: m.idx ?? n.idx, el: el)
        } else {
            el = HostA11yElement(nodeID: id, client: client,
                                 container: view ?? NSObject())
            // parent:0 = window root; flatten already treats any absent
            // parent id as a root, so the sentinel needs no special case.
            nodes[id] = Node(parent: m.parent ?? 0, idx: m.idx ?? 0, el: el)
        }
        if let l = m.label { el.accessibilityLabel = l }
        if let v = m.value { el.accessibilityValue = v }
        if let h = m.hint { el.accessibilityHint = h }
        if let tr = m.traits {
            el.accessibilityTraits = HostA11yElement.traits(from: tr)
            el.accessibilityViewIsModal = tr.contains("modal")
        }
        if let f = m.frame, f.count == 4 {
            el.canvasFrame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        if let names = m.actions { el.setCustomActions(names) }
        scheduleFlatten()
    }

    /// Removes the node AND its subtree. Returns true if the node belonged to
    /// this store.
    func remove(_ id: Int) -> Bool {
        guard nodes[id] != nil else { return false }
        var doomed = [id]
        while let victim = doomed.popLast() {
            nodes.removeValue(forKey: victim)
            doomed.append(contentsOf: nodes.filter { $0.value.parent == victim }.map(\.key))
        }
        scheduleFlatten()
        return true
    }

    /// Coalesce bursts within a runloop turn; the helper already debounces.
    private func scheduleFlatten() {
        guard !flattenScheduled else { return }
        flattenScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flattenScheduled = false
            self?.publish()
        }
    }

    /// Pre-order flatten (VoiceOver swipe order = array order) onto the view.
    func publish() {
        guard let view else { return }
        var children: [Int: [(Int, Int)]] = [:]   // parent -> [(idx, id)]
        var roots: [(Int, Int)] = []
        for (id, n) in nodes {
            if nodes[n.parent] == nil { roots.append((n.idx, id)) }
            else { children[n.parent, default: []].append((n.idx, id)) }
        }
        var ordered: [HostA11yElement] = []
        func walk(_ list: [(Int, Int)]) {
            for (_, id) in list.sorted(by: { $0.0 < $1.0 }) {
                guard let n = nodes[id] else { continue }
                n.el.accessibilityContainer = view
                ordered.append(n.el)
                if let kids = children[id] { walk(kids) }
            }
        }
        walk(roots)
        view.accessibilityElements = ordered.isEmpty ? nil : ordered
        client.log("publish win=\(winID) elements=\(ordered.count) view=\(ObjectIdentifier(view))")
    }

    func unpublish() {
        view?.accessibilityElements = nil
        nodes.removeAll()
        client.log("unpublish win=\(winID)")
    }
}

// MARK: - element

final class HostA11yElement: UIAccessibilityElement {
    let nodeID: Int
    var canvasFrame = CGRect.zero
    private unowned let client: HostA11yClient

    init(nodeID: Int, client: HostA11yClient, container: Any) {
        self.nodeID = nodeID
        self.client = client
        super.init(accessibilityContainer: container)
    }

    /// Lazy: canvas px -> view points -> screen, so rotation/Split View drags
    /// need no re-push from the helper.
    override var accessibilityFrame: CGRect {
        get {
            guard let view = accessibilityContainer as? HostScreenView else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(
                view.viewRect(fromCanvas: canvasFrame), in: view)
        }
        set { super.accessibilityFrame = newValue }
    }

    override func accessibilityActivate() -> Bool {
        client.activate(nodeID)
        return true
    }
    override func accessibilityIncrement() { client.adjust(nodeID, dir: +1) }
    override func accessibilityDecrement() { client.adjust(nodeID, dir: -1) }

    /// 2-finger Z: Esc straight down this window's own input connection.
    override func accessibilityPerformEscape() -> Bool {
        guard let view = accessibilityContainer as? HostScreenView else { return false }
        view.a11yEscape()
        return true
    }

    override func accessibilityElementDidBecomeFocused() {
        client.voFocus(nodeID)   // logging/metrics only; never GrabFocus
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let dir: String
        switch direction {
        case .up: dir = "up"
        case .down: dir = "down"
        case .left: dir = "left"
        case .right: dir = "right"
        default: return false
        }
        client.scroll(nodeID, dir: dir)
        return true
    }

    func setCustomActions(_ names: [String]) {
        guard !names.isEmpty else { accessibilityCustomActions = nil; return }
        accessibilityCustomActions = names.enumerated().map { (i, name) in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self else { return false }
                self.client.action(self.nodeID, idx: i)
                return true
            }
        }
    }

    /// Helper trait strings -> UIAccessibilityTraits. iOS 16 floor: checked
    /// state rides accessibilityValue (no .toggleButton), per a11y-plan.md.
    static func traits(from names: [String]) -> UIAccessibilityTraits {
        var t: UIAccessibilityTraits = []
        for n in names {
            switch n {
            case "button":             t.insert(.button)
            case "link":               t.insert(.link)
            case "header":             t.insert(.header)
            case "static-text":        t.insert(.staticText)
            case "image":              t.insert(.image)
            case "adjustable":         t.insert(.adjustable)
            case "selected":           t.insert(.selected)
            case "not-enabled":        t.insert(.notEnabled)
            case "updates-frequently": t.insert(.updatesFrequently)
            case "tab-bar":            t.insert(.tabBar)
            case "search-field":       t.insert(.searchField)
            case "keyboard-key":       t.insert(.keyboardKey)
            default:                   break
            }
        }
        return t
    }
}
