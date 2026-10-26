import UIKit

/// The pasteboard bridge for one desktop: UIPasteboard <-> the compositor's
/// wl_data_device selection over its clipboard socket. Owned by the presented
/// connection only, so a hidden desktop never sees the iOS pasteboard.
///
/// Threading (invariants 48, 49): connect and writes run on `queue`; everything
/// that touches the C handle's receive side, and the adopt, runs on main. Work that
/// leaves main carries the epoch it started under and is dropped if the link was
/// closed or replaced meanwhile.
final class ClipboardLink {
    private static let queue = DispatchQueue(label: "com.max.xios.clipboard",
                                             qos: .userInitiated)
    private static let kText: UInt32 = 1, kURI: UInt32 = 2, kPNG: UInt32 = 3, kHTML: UInt32 = 4

    /// Echo guards: what we last wrote to or read from the desktop. Touched only
    /// on `queue`, where every push is decided, so each push sees every earlier
    /// push and receive in order even though its PNG encode runs there.
    private final class Echo {
        var text: String?
        var png: Data?
    }

    private let socketPath: String
    private var handle: OpaquePointer?              // iosc_clipboard_t*, main only
    private var connectInFlight = false
    private var epoch = 0
    private let echo = Echo()
    private var rxGeneration: UInt32 = 0
    private var rxItems: [UInt32: Data] = [:]
    private var pasteboardChangeCount = UIPasteboard.general.changeCount
    /// After a (re)connect the desktop replays its clipboard if it has one. Push
    /// ours only if it stays silent for this many ticks: a fresh desktop inherits
    /// the iOS pasteboard, but a reattach mid-session does not clobber the
    /// desktop's clipboard with a stale one.
    private var deferredPushTicks = 0
    private static let deferredPushDelay = 30
    private var closed = false

    init(socket: String) { socketPath = socket }

    var isOpen: Bool { handle != nil && iosc_clipboard_is_open(handle) }

    /// Called every display tick on main.
    func service(tick: Int) {
        guard !closed else { return }
        guard let h = handle, iosc_clipboard_is_open(h) else {
            if handle != nil { dropHandle() }
            if tick % 30 == 0, !connectInFlight { connect() }
            return
        }
        var gotAny = false
        while true {
            var kind: UInt32 = 0, gen: UInt32 = 0, len: UInt32 = 0
            var buf: UnsafeMutablePointer<UInt8>? = nil
            let r = iosc_clipboard_poll_item(h, &kind, &gen, &buf, &len)
            if r < 0 { deferredPushTicks = 0; dropHandle(); return }
            if r == 0 { break }
            deferredPushTicks = 0
            if gen != rxGeneration { rxGeneration = gen; rxItems.removeAll() }
            if kind == 0 { free(buf); rxItems.removeAll() }
            else if let b = buf {
                rxItems[kind] = Data(bytesNoCopy: b, count: Int(len), deallocator: .free)
            }
            gotAny = true
        }
        if gotAny { commitReceived() }
        if deferredPushTicks > 0 {
            deferredPushTicks -= 1
            if deferredPushTicks == 0 { push(onConnect: true) }
        }
        if UIPasteboard.general.changeCount != pasteboardChangeCount {
            push(onConnect: false)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        epoch += 1
        dropHandle()
    }

    /// Free the C handle on the clipboard queue, after any push already queued
    /// against it (a push dup()s the fd on main and never touches the handle, but
    /// ordering the free behind it keeps the contract simple).
    private func dropHandle() {
        guard let h = handle else { return }
        handle = nil
        epoch += 1
        Self.queue.async { iosc_clipboard_close(h) }
    }

    /// connect() plus the HELLO reply can take up to 2 s against a compositor that
    /// accepted but is busy (KDE start-up), so it runs on the queue and only the
    /// adopt happens on main.
    private func connect() {
        connectInFlight = true
        let started = epoch
        let path = socketPath
        Self.queue.async { [weak self] in
            let fd = iosc_clipboard_connect(path)
            DispatchQueue.main.async {
                guard let self else { if fd >= 0 { Darwin.close(fd) }; return }
                self.connectInFlight = false
                guard fd >= 0 else { return }
                guard !self.closed, started == self.epoch, self.handle == nil else {
                    Darwin.close(fd); return
                }
                guard let h = iosc_clipboard_adopt(fd) else { return }
                self.handle = h
                self.epoch += 1
                self.pasteboardChangeCount = UIPasteboard.general.changeCount
                self.deferredPushTicks = Self.deferredPushDelay
            }
        }
    }

    private func commitReceived() {
        let pb = UIPasteboard.general
        var item: [String: Any] = [:]
        var echoText: String?, echoPNG: Data?
        if let t = rxItems[Self.kText], let s = String(data: t, encoding: .utf8) {
            item["public.utf8-plain-text"] = s
            echoText = s
        }
        if let png = rxItems[Self.kPNG] {
            item["public.png"] = png
            echoPNG = png
        }
        let echo = self.echo
        Self.queue.async { echo.text = echoText; echo.png = echoPNG }
        if let u = rxItems[Self.kURI], let s = String(data: u, encoding: .utf8) {
            let uris = s.split(whereSeparator: { $0 == "\r" || $0 == "\n" })
                        .filter { !$0.hasPrefix("#") }
            // A single http(s) link pastes as a link; file:// paths from Linux mean
            // nothing to iOS apps, so those only ride along as text (invariant 50).
            if uris.count == 1, let url = URL(string: String(uris[0])),
               url.scheme == "http" || url.scheme == "https" {
                item["public.url"] = url.absoluteString
            }
            if item["public.utf8-plain-text"] == nil {
                item["public.utf8-plain-text"] = s
            }
        }
        if let h = rxItems[Self.kHTML], let s = String(data: h, encoding: .utf8) {
            item["public.html"] = s
        }
        pb.items = item.isEmpty ? [] : [item]
        pasteboardChangeCount = pb.changeCount   // our own write, not an iOS copy
    }

    /// Main only reads the pasteboard. Everything after that runs on the serial
    /// queue, so pushes keep their order: re-encoding a non-PNG image (a camera
    /// photo is real CPU), the echo check, and the writes.
    private func push(onConnect: Bool) {
        let pb = UIPasteboard.general
        pasteboardChangeCount = pb.changeCount
        let text = pb.hasStrings ? pb.string : nil
        let rawPNG = pb.hasImages ? pb.data(forPasteboardType: "public.png") : nil
        let image = pb.hasImages && rawPNG == nil ? pb.image : nil
        let urls = pb.hasURLs ? (pb.urls ?? []) : []
        let fd = iosc_clipboard_writer_fd(handle)
        let started = epoch
        let echo = self.echo
        let kText = Self.kText, kPNG = Self.kPNG, kURI = Self.kURI
        Self.queue.async { [weak self] in
            let png = rawPNG ?? image?.pngData()
            var items: [(kind: UInt32, data: Data)]?   // nil: nothing to send
            if text == nil && png == nil && urls.isEmpty {
                // An empty pasteboard on connect is "nothing to contribute", not
                // "clear the desktop clipboard" (invariant 48).
                if !onConnect { items = [] }
                echo.text = nil; echo.png = nil
            } else if onConnect || text != echo.text || png != echo.png {
                // (Otherwise it is an echo of our own commitReceived write.)
                // Text goes out as its C string did: the UTF-8 up to any NUL.
                func cText(_ s: String) -> Data { Data(s.utf8.prefix { $0 != 0 }) }
                var records: [(kind: UInt32, data: Data)] = []
                if let t = text { records.append((kText, cText(t))) }
                if let p = png { records.append((kPNG, p)) }
                if !urls.isEmpty {
                    let list = urls.map(\.absoluteString).joined(separator: "\r\n") + "\r\n"
                    records.append((kURI, cText(list)))
                    if text == nil { records.append((kText, cText(list))) }
                }
                items = records
                echo.text = text; echo.png = png
            }
            guard fd >= 0 else { return }
            guard let items else { Darwin.close(fd); return }
            Self.write(fd: fd, items, generation: iosc_clipboard_send_begin(),
                       epoch: started, owner: self)
        }
    }

    /// On the queue: write one copy event's records (no items: a clear). A PNG can
    /// be 16 MB and SO_SNDTIMEO bounds each write() call, not the record, so this
    /// never runs on the display link. A failed write may have cut a record
    /// short: shut that socket down so writes still queued for it fail instead of
    /// following a torn record, and drop the link on main, which reconnects.
    private static func write(fd: Int32, _ items: [(kind: UInt32, data: Data)],
                              generation: UInt32, epoch: Int, owner: ClipboardLink?) {
        var failed = items.isEmpty && iosc_clipboard_write_clear(fd, generation) < 0
        for item in items where !failed {
            failed = item.data.withUnsafeBytes {
                iosc_clipboard_write_item(fd, generation, item.kind,
                                          $0.baseAddress, $0.count) < 0
            }
        }
        if failed { Darwin.shutdown(fd, SHUT_RDWR) }
        Darwin.close(fd)
        guard failed else { return }
        DispatchQueue.main.async { [weak owner] in
            guard let owner, !owner.closed, owner.epoch == epoch else { return }
            owner.dropHandle()
        }
    }
}
