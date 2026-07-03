import Darwin
import UIKit

/// Desktop Xios half of the AT-SPI -> VoiceOver bridge. This is the unbound
/// client described in docs/a11y-plan.md: xios-a11yd sends desktop-pixel frames
/// for every visible AT-SPI node, and the app publishes them as
/// UIAccessibilityElements on the single Metal framebuffer view.
final class XiosA11yClient {
    static let shared = XiosA11yClient()

    private let sockPath = "/var/jb/tmp/xios-a11y.sock"
    private let forcePath = "/var/jb/tmp/xios-a11y-force"
    private let logPath = "/var/jb/tmp/xios-a11y-app.log"

    private weak var view: XScreenView?
    private var fd: Int32 = -1
    private var reader: Thread?
    private var running = false
    private var observerInstalled = false
    private let writeQueue = DispatchQueue(label: "xios-a11y-write")
    private let store = XiosA11yStore()

    private init() {
        store.client = self
    }

    func startup(view: XScreenView) {
        self.view = view
        store.view = view
        if !observerInstalled {
            observerInstalled = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(syncVoiceOver),
                name: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil)
        }
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
        let t = Thread { [weak self] in self?.readerLoop() }
        t.name = "xios-a11y-reader"
        t.stackSize = 256 * 1024
        reader = t
        t.start()
    }

    private func stop() {
        running = false
        if fd >= 0 { close(fd); fd = -1 }
        reader = nil
        store.unpublish()
        log("reader stop")
    }

    private func readerLoop() {
        var failures = 0
        while running {
            let s = xiosConnectUnixSocket(sockPath)
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
            log("connected path=\(sockPath)")
            send(["t": "enable", "on": true])
            pump(s)
            log("socket closed")
            if fd >= 0 { close(fd); fd = -1 }
            DispatchQueue.main.async { [weak self] in self?.store.unpublish() }
        }
    }

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
                      let m = try? JSONDecoder().decode(XiosA11yMsg.self, from: line) else {
                    log("decode skip bytes=\(line.count)")
                    continue
                }
                DispatchQueue.main.async { [weak self] in self?.apply(m) }
            }
        }
    }

    fileprivate func send(_ obj: [String: Any]) {
        writeQueue.async { [weak self] in
            guard let self, self.fd >= 0,
                  var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
            data.append(0x0a)
            _ = data.withUnsafeBytes { xiosWriteAll(self.fd, bytes: $0) }
        }
    }

    fileprivate func log(_ message: String) {
        let line = "XiosA11y \(Date()) \(message)\n"
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

    fileprivate func activate(_ id: Int)            { send(["t": "activate", "id": id]) }
    fileprivate func action(_ id: Int, idx: Int)    { send(["t": "action", "id": id, "idx": idx]) }
    fileprivate func adjust(_ id: Int, dir: Int)    { send(["t": "adjust", "id": id, "dir": dir]) }
    fileprivate func scroll(_ id: Int, dir: String) { send(["t": "scroll", "id": id, "dir": dir]) }
    fileprivate func voFocus(_ id: Int)             { send(["t": "vo-focus", "id": id]) }

    private func apply(_ m: XiosA11yMsg) {
        switch m.t {
        case "hello":
            log("hello gen=\(m.gen ?? -1)")
        case "reset":
            log("reset gen=\(m.gen ?? -1)")
            store.unpublish()
            UIAccessibility.post(notification: .screenChanged, argument: view)
        case "window":
            guard let id = m.id else { break }
            store.upsertWindow(id: id, m: m)
        case "remove":
            if let id = m.id { store.remove(id) }
        case "upsert":
            guard let id = m.id else { break }
            store.upsertNode(id: id, m: m)
        case "focus":
            guard let id = m.id, let el = store.element(id) else { break }
            UIAccessibility.post(notification: .layoutChanged, argument: el)
        case "announce":
            if let text = m.text {
                log("announce \(text)")
                UIAccessibility.post(notification: .announcement, argument: text)
            }
        case "tap":
            guard let x = m.x, let y = m.y else { break }
            view?.a11ySynthTap(x: Int32(x), y: Int32(y))
        default:
            log("unknown message type \(m.t)")
        }
    }
}

private struct XiosA11yMsg: Decodable {
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
    let frame: [Double]?
    let title: String?
    let appid: String?
    let focused: Bool?
    let text: String?
    let x: Double?
    let y: Double?
    let gen: Int?
}

final class XiosA11yStore {
    weak var view: XScreenView?
    weak var client: XiosA11yClient?

    private struct Window {
        var idx: Int
        var title: String
        var appid: String
        var frame: CGRect
    }
    private struct Node {
        var win: Int
        var parent: Int
        var idx: Int
        let el: XiosA11yElement
    }

    private var windows: [Int: Window] = [:]
    private var nodes: [Int: Node] = [:]
    private var nextWindowIdx = 0
    private var flattenScheduled = false

    func element(_ id: Int) -> XiosA11yElement? { nodes[id]?.el }

    fileprivate func upsertWindow(id: Int, m: XiosA11yMsg) {
        var win = windows[id] ?? Window(idx: nextWindowIdx, title: "", appid: "", frame: .zero)
        if windows[id] == nil { nextWindowIdx += 1 }
        win.title = m.title ?? win.title
        win.appid = m.appid ?? win.appid
        if let f = m.frame, f.count == 4 {
            win.frame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        windows[id] = win
        if m.focused == true {
            UIAccessibility.post(notification: .screenChanged, argument: view)
        }
    }

    fileprivate func upsertNode(id: Int, m: XiosA11yMsg) {
        guard let view, let client else { return }
        let el: XiosA11yElement
        if let n = nodes[id] {
            el = n.el
            nodes[id] = Node(win: m.win ?? n.win, parent: m.parent ?? n.parent,
                             idx: m.idx ?? n.idx, el: el)
        } else {
            el = XiosA11yElement(nodeID: id, client: client, container: view)
            nodes[id] = Node(win: m.win ?? 0, parent: m.parent ?? 0, idx: m.idx ?? 0, el: el)
        }
        if let l = m.label { el.accessibilityLabel = l }
        if let v = m.value { el.accessibilityValue = v }
        if let h = m.hint { el.accessibilityHint = h }
        if let tr = m.traits {
            el.accessibilityTraits = XiosA11yElement.traits(from: tr)
            el.accessibilityViewIsModal = tr.contains("modal")
        }
        if let f = m.frame, f.count == 4 {
            el.framebufferFrame = CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
        }
        if let names = m.actions { el.setCustomActions(names) }
        scheduleFlatten()
    }

    func remove(_ id: Int) {
        if windows[id] != nil {
            windows[id] = nil
            for nodeID in nodes.filter({ $0.value.win == id }).map(\.key) {
                removeNode(nodeID)
            }
            scheduleFlatten()
            return
        }
        if removeNode(id) { scheduleFlatten() }
    }

    @discardableResult
    private func removeNode(_ id: Int) -> Bool {
        guard nodes[id] != nil else { return false }
        var doomed = [id]
        while let victim = doomed.popLast() {
            nodes.removeValue(forKey: victim)
            doomed.append(contentsOf: nodes.filter { $0.value.parent == victim }.map(\.key))
        }
        return true
    }

    private func scheduleFlatten() {
        guard !flattenScheduled else { return }
        flattenScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flattenScheduled = false
            self?.publish()
        }
    }

    func publish() {
        guard let view else { return }
        var children: [Int: [(Int, Int)]] = [:]
        var roots: [(Int, Int, Int)] = []   // window order, node idx, node id
        for (id, n) in nodes {
            if nodes[n.parent] == nil {
                roots.append((windows[n.win]?.idx ?? Int.max, n.idx, id))
            } else {
                children[n.parent, default: []].append((n.idx, id))
            }
        }

        var ordered: [XiosA11yElement] = []
        func walk(_ list: [(Int, Int)]) {
            for (_, id) in list.sorted(by: { $0.0 < $1.0 }) {
                guard let n = nodes[id] else { continue }
                n.el.accessibilityContainer = view
                ordered.append(n.el)
                if let kids = children[id] { walk(kids) }
            }
        }
        for (_, _, id) in roots.sorted(by: {
            $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
        }) {
            guard let n = nodes[id] else { continue }
            n.el.accessibilityContainer = view
            ordered.append(n.el)
            if let kids = children[id] { walk(kids) }
        }
        view.accessibilityElements = ordered.isEmpty ? nil : ordered
        client?.log("publish elements=\(ordered.count) windows=\(windows.count)")
    }

    func unpublish() {
        view?.accessibilityElements = nil
        windows.removeAll()
        nodes.removeAll()
        nextWindowIdx = 0
        client?.log("unpublish")
    }
}

final class XiosA11yElement: UIAccessibilityElement {
    let nodeID: Int
    var framebufferFrame = CGRect.zero
    private unowned let client: XiosA11yClient

    init(nodeID: Int, client: XiosA11yClient, container: Any) {
        self.nodeID = nodeID
        self.client = client
        super.init(accessibilityContainer: container)
    }

    override var accessibilityFrame: CGRect {
        get {
            guard let view = accessibilityContainer as? XScreenView else { return .zero }
            return UIAccessibility.convertToScreenCoordinates(
                view.viewRect(fromFramebuffer: framebufferFrame), in: view)
        }
        set { super.accessibilityFrame = newValue }
    }

    override func accessibilityActivate() -> Bool {
        client.activate(nodeID)
        return true
    }

    override func accessibilityIncrement() { client.adjust(nodeID, dir: +1) }
    override func accessibilityDecrement() { client.adjust(nodeID, dir: -1) }

    override func accessibilityPerformEscape() -> Bool {
        guard let view = accessibilityContainer as? XScreenView else { return false }
        view.a11yEscape()
        return true
    }

    override func accessibilityElementDidBecomeFocused() {
        client.voFocus(nodeID)
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
        accessibilityCustomActions = names.enumerated().map { i, name in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                guard let self else { return false }
                self.client.action(self.nodeID, idx: i)
                return true
            }
        }
    }

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
