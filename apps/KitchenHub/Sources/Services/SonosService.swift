import Foundation
import Darwin

/// Best-effort SSDP discovery of a Sonos player on the LAN. Blocking — call from
/// a detached task. We only need to reach ONE speaker; ZoneGroupTopology then
/// reveals the whole system.
enum SonosDiscovery {
    static func find(timeoutSec: Int32 = 2) -> [String] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return [] }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeoutSec), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var ttl: UInt8 = 2
        setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr)

        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n" +
                  "MAN: \"ssdp:discover\"\r\nMX: 1\r\n" +
                  "ST: urn:schemas-upnp-org:device:ZonePlayer:1\r\n\r\n"
        let sent = msg.withCString { cstr -> Int in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, cstr, strlen(cstr), 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 { return [] }

        var found = Set<String>()
        var buf = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<16 {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { break }
            if let resp = String(bytes: buf[0..<n], encoding: .utf8), let ip = host(resp) { found.insert(ip) }
        }
        return Array(found)
    }

    private static func host(_ resp: String) -> String? {
        for line in resp.split(separator: "\r\n") where line.uppercased().hasPrefix("LOCATION:") {
            let v = line.dropFirst("LOCATION:".count).trimmingCharacters(in: .whitespaces)
            if let url = URL(string: v), let h = url.host { return h }
        }
        return nil
    }
}

struct SonosRoom: Identifiable, Equatable {
    let uuid: String     // RINCON_…
    let name: String     // "Living Room"
    let ip: String
    var id: String { uuid }
}

/// A browsable/playable Sonos favorite (station, playlist, album…) or queue track.
struct SonosItem: Identifiable, Equatable {
    let id: String
    let title: String
    let uri: String        // <res> content (plain)
    let metadata: String   // <r:resMD> content (kept XML-escaped, for SetAVTransportURI)
    let artURL: URL?
    let isContainer: Bool
    var artist: String = ""   // dc:creator, when present (queue rows). Defaulted to keep memberwise init source-compatible.
}

/// Controls a Sonos system: discovers all rooms + current grouping via
/// ZoneGroupTopology, controls a selected room (transport via its group
/// coordinator, volume per-room), and groups/ungroups rooms like the Sonos app.
@MainActor
final class SonosController: ObservableObject {
    enum Status { case searching, connected, noSpeaker, error }
    struct NowPlaying: Equatable { var title = ""; var artist = ""; var album = ""; var artURL: URL? }

    @Published var status: Status = .searching
    @Published var rooms: [SonosRoom] = []
    @Published var groupOf: [String: String] = [:]   // memberUUID -> coordinatorUUID
    @Published var selectedUUID: String?
    @Published var transport = "STOPPED"
    @Published var volume = 0
    @Published var now: NowPlaying?
    @Published var favorites: [SonosItem] = []
    @Published var browseLoading = false

    // Live position + queue (from the coordinator's GetPositionInfo / queue Browse).
    @Published var position: TimeInterval = 0   // current play position, seconds
    @Published var duration: TimeInterval = 0   // current track length, seconds (0 = unknown/stream)
    @Published var trackNo: Int = 0             // 1-based index of the current track in the queue
    @Published var queue: [SonosItem] = []      // the coordinator's "Up Next" queue (Q:0)

    /// Fallback seed if SSDP is blocked and no manual IP is set (this network's
    /// Living Room Play:1). Topology discovery corrects everything from here.
    private let fallbackSeed = "10.0.0.3"

    private var poll: Timer?
    private var seedIP: String?
    private var manualIP: String?
    private var refreshTick = 0   // throttles periodic queue reloads inside refresh()

    var isPlaying: Bool { transport == "PLAYING" || transport == "TRANSITIONING" }
    var selectedRoom: SonosRoom? { rooms.first { $0.uuid == selectedUUID } }

    /// The controlling room plus any synced rooms, e.g. "Kitchen +2" — or nil
    /// when nothing is selected. Callers supply their own no-selection fallback.
    var groupedRoomName: String? {
        guard let sel = selectedUUID, let r = selectedRoom else { return nil }
        let extra = groupMembers(of: sel).count - 1
        return extra > 0 ? "\(r.name) +\(extra)" : r.name
    }
    func room(_ uuid: String) -> SonosRoom? { rooms.first { $0.uuid == uuid } }
    func coordinator(of uuid: String) -> String { groupOf[uuid] ?? uuid }
    func groupMembers(of uuid: String) -> [SonosRoom] {
        let coord = coordinator(of: uuid)
        return rooms.filter { coordinator(of: $0.uuid) == coord }
    }

    // MARK: Lifecycle

    func start(manualIP: String?) {
        self.manualIP = (manualIP?.isEmpty == false) ? manualIP : nil
        Task { await connect() }
        if poll == nil {
            let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            RunLoop.main.add(t, forMode: .common)
            poll = t
        }
    }

    func stop() { poll?.invalidate(); poll = nil }

    private func connect() async {
        status = .searching
        var seed = manualIP
        if seed == nil {
            let ips = await Task.detached { SonosDiscovery.find() }.value
            seed = ips.first ?? fallbackSeed
        }
        seedIP = seed
        await loadTopology()
    }

    func loadTopology() async {
        guard let ip = seedIP else { status = .noSpeaker; return }
        do {
            let xml = try await soap(ip, "ZoneGroupTopology", "/ZoneGroupTopology/Control",
                                     "GetZoneGroupState", "")
            parseTopology(xml)
            if rooms.isEmpty { status = .noSpeaker; return }
            if selectedUUID == nil || room(selectedUUID!) == nil { selectedUUID = rooms.first?.uuid }
            status = .connected
            await refresh()
        } catch {
            status = .error
        }
    }

    func refresh() async {
        guard status == .connected, let sel = selectedUUID,
              let selIP = room(sel)?.ip, let coordIP = room(coordinator(of: sel))?.ip else { return }
        do {
            let ti = try await soap(coordIP, "AVTransport", avPath, "GetTransportInfo", inst)
            if let s = value("CurrentTransportState", ti) { transport = s }
            let pi = try await soap(coordIP, "AVTransport", avPath, "GetPositionInfo", inst)
            parseMeta(pi, ip: coordIP)
            // Live scrubber state from the same GetPositionInfo response.
            if let rel = value("RelTime", pi) { position = secondsFrom(rel) }
            if let dur = value("TrackDuration", pi) { duration = secondsFrom(dur) }
            let prevTrack = trackNo
            if let t = value("Track", pi).flatMap({ Int($0) }) { trackNo = t }
            let v = try await soap(selIP, "RenderingControl", rcPath, "GetVolume",
                                   inst + "<Channel>Master</Channel>")
            if let n = value("CurrentVolume", v).flatMap({ Int($0) }) { volume = n }

            // Keep the queue fresh without spamming: on track change (incl. the
            // first 0→N after connecting) or roughly every ~30s (refresh runs every 3s).
            refreshTick &+= 1
            if trackNo != prevTrack || refreshTick % 10 == 0 {
                await loadQueue()
            }
        } catch { /* keep last known */ }
    }

    func select(_ uuid: String) {
        selectedUUID = uuid
        Task { await refresh() }
    }

    // MARK: Transport (acts on the group coordinator)

    func toggle() { isPlaying ? pause() : play() }

    /// Resume / start playback. If the system is idle with a loaded queue but no
    /// resolved current track, kick the queue off from its current (or first)
    /// track so the Play button always does something useful.
    func play() {
        if !isPlaying, now == nil, !queue.isEmpty {
            playFromQueue(trackNo > 0 ? trackNo : 1)
            return
        }
        coordAV("Play", inst + "<Speed>1</Speed>")
    }
    func pause()     { coordAV("Pause", inst) }
    func next()      { coordAV("Next", inst) }
    func previous()  { coordAV("Previous", inst) }

    /// Jump to a specific track in the "Up Next" queue (1-based) and play it.
    /// Points the transport at the queue first (no-op if it already is), seeks by
    /// track number, then plays. Optimistically bumps `trackNo` for snappy UI.
    func playFromQueue(_ index: Int) {
        guard let sel = selectedUUID,
              let coordIP = room(coordinator(of: sel))?.ip,
              let coordUUID = room(coordinator(of: sel))?.uuid else { return }
        let track = max(1, index)
        trackNo = track
        Task {
            _ = try? await soap(coordIP, "AVTransport", avPath, "SetAVTransportURI",
                inst + "<CurrentURI>x-rincon-queue:\(coordUUID)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
            _ = try? await soap(coordIP, "AVTransport", avPath, "Seek",
                inst + "<Unit>TRACK_NR</Unit><Target>\(track)</Target>")
            _ = try? await soap(coordIP, "AVTransport", avPath, "Play", inst + "<Speed>1</Speed>")
            await refresh()
        }
    }

    func setVolume(_ v: Int) {
        volume = v
        guard let ip = selectedRoom?.ip else { return }
        Task { _ = try? await soap(ip, "RenderingControl", rcPath, "SetVolume",
                                   inst + "<Channel>Master</Channel><DesiredVolume>\(v)</DesiredVolume>") }
    }

    /// Seek the current track to an absolute position (seconds), acting on the
    /// group coordinator. Optimistically updates `position`, then refreshes.
    func seek(to seconds: TimeInterval) {
        guard let sel = selectedUUID, let coordIP = room(coordinator(of: sel))?.ip else { return }
        let target = hmsFrom(seconds)
        position = max(0, seconds)
        Task {
            _ = try? await soap(coordIP, "AVTransport", avPath, "Seek",
                                inst + "<Unit>REL_TIME</Unit><Target>\(target)</Target>")
            await refresh()
        }
    }

    // MARK: Grouping (join uses the selected room's group coordinator)

    func setGrouped(_ uuid: String, _ grouped: Bool) {
        guard let sel = selectedUUID else { return }
        if grouped {
            join(uuid, toCoordinator: coordinator(of: sel))
        } else {
            ungroup(uuid)
        }
    }

    private func join(_ uuid: String, toCoordinator coord: String) {
        guard let ip = room(uuid)?.ip else { return }
        Task {
            _ = try? await soap(ip, "AVTransport", avPath, "SetAVTransportURI",
                                inst + "<CurrentURI>x-rincon:\(coord)</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
            await loadTopology()
        }
    }

    private func ungroup(_ uuid: String) {
        guard let ip = room(uuid)?.ip else { return }
        Task {
            _ = try? await soap(ip, "AVTransport", avPath, "BecomeCoordinatorOfStandaloneGroup", inst)
            await loadTopology()
        }
    }

    private func coordAV(_ action: String, _ body: String) {
        guard let sel = selectedUUID, let ip = room(coordinator(of: sel))?.ip else { return }
        Task { _ = try? await soap(ip, "AVTransport", avPath, action, body); await refresh() }
    }

    // MARK: Browse favorites + play

    /// Browse "Sonos Favorites" (FV:2) — stations, playlists, albums the user saved
    /// (including Spotify content). Queried from any reachable speaker.
    func loadFavorites() async {
        guard let ip = selectedRoom?.ip ?? seedIP else { return }
        browseLoading = true
        defer { browseLoading = false }
        let body = "<ObjectID>FV:2</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
                   "<Filter>*</Filter><StartingIndex>0</StartingIndex>" +
                   "<RequestedCount>200</RequestedCount><SortCriteria></SortCriteria>"
        guard let xml = try? await soap(ip, "ContentDirectory",
                                        "/MediaServer/ContentDirectory/Control", "Browse", body),
              let result = value("Result", xml) else { favorites = []; return }
        favorites = parseItems(unescape(result), seedIP: ip)
    }

    /// Browse the group coordinator's live playback queue (Q:0) into `queue`.
    /// Titles/artists/art come from the DIDL via the shared `parseItems` helper.
    func loadQueue() async {
        guard status == .connected, let sel = selectedUUID,
              let coordIP = room(coordinator(of: sel))?.ip else { return }
        let body = "<ObjectID>Q:0</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag>" +
                   "<Filter>*</Filter><StartingIndex>0</StartingIndex>" +
                   "<RequestedCount>50</RequestedCount><SortCriteria></SortCriteria>"
        guard let xml = try? await soap(coordIP, "ContentDirectory",
                                        "/MediaServer/ContentDirectory/Control", "Browse", body),
              let result = value("Result", xml) else { return }
        queue = parseItems(unescape(result), seedIP: coordIP)
    }

    /// Start a favorite on the selected room's group coordinator. Container-type
    /// favorites (playlists) are enqueued; single items are set directly.
    func play(_ item: SonosItem) {
        guard let sel = selectedUUID,
              let coordIP = room(coordinator(of: sel))?.ip,
              let coordUUID = room(coordinator(of: sel))?.uuid else { return }
        let uri = xmlEscape(item.uri)
        let md = item.metadata
        let enqueue = item.isContainer
            || item.uri.hasPrefix("x-rincon-cpcontainer")
            || item.uri.contains(":playlist")
        Task {
            if enqueue {
                _ = try? await soap(coordIP, "AVTransport", avPath, "RemoveAllTracksFromQueue", inst)
                _ = try? await soap(coordIP, "AVTransport", avPath, "AddURIToQueue",
                    inst + "<EnqueuedURI>\(uri)</EnqueuedURI><EnqueuedURIMetaData>\(md)</EnqueuedURIMetaData>" +
                    "<DesiredFirstTrackNumberEnqueued>0</DesiredFirstTrackNumberEnqueued><EnqueueAsNext>0</EnqueueAsNext>")
                _ = try? await soap(coordIP, "AVTransport", avPath, "SetAVTransportURI",
                    inst + "<CurrentURI>x-rincon-queue:\(coordUUID)#0</CurrentURI><CurrentURIMetaData></CurrentURIMetaData>")
            } else {
                _ = try? await soap(coordIP, "AVTransport", avPath, "SetAVTransportURI",
                    inst + "<CurrentURI>\(uri)</CurrentURI><CurrentURIMetaData>\(md)</CurrentURIMetaData>")
            }
            _ = try? await soap(coordIP, "AVTransport", avPath, "Play", inst + "<Speed>1</Speed>")
            await refresh()
        }
    }

    // MARK: SOAP

    private let inst = "<InstanceID>0</InstanceID>"
    private let avPath = "/MediaRenderer/AVTransport/Control"
    private let rcPath = "/MediaRenderer/RenderingControl/Control"

    private func soap(_ ip: String, _ service: String, _ path: String,
                      _ action: String, _ body: String) async throws -> String {
        guard let url = URL(string: "http://\(ip):1400\(path)") else { throw URLError(.badURL) }
        var req = URLRequest(url: url, timeoutInterval: 4)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"urn:schemas-upnp-org:service:\(service):1#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        req.httpBody = ("<?xml version=\"1.0\"?>" +
            "<s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" " +
            "s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body>" +
            "<u:\(action) xmlns:u=\"urn:schemas-upnp-org:service:\(service):1\">\(body)</u:\(action)>" +
            "</s:Body></s:Envelope>").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Parsing

    private func parseTopology(_ xml: String) {
        guard let raw = value("ZoneGroupState", xml) else { return }
        let didl = unescape(raw)
        var newRooms: [SonosRoom] = []
        var grouping: [String: String] = [:]

        var gSearch = didl.startIndex
        while let gs = didl.range(of: "<ZoneGroup ", range: gSearch..<didl.endIndex),
              let ge = didl.range(of: "</ZoneGroup>", range: gs.upperBound..<didl.endIndex) {
            let block = String(didl[gs.lowerBound..<ge.upperBound])
            let coord = attr("Coordinator", block) ?? ""
            var mSearch = block.startIndex
            while let ms = block.range(of: "<ZoneGroupMember ", range: mSearch..<block.endIndex),
                  let me = block.range(of: "/>", range: ms.upperBound..<block.endIndex) {
                let m = String(block[ms.lowerBound..<me.upperBound])
                if attr("Invisible", m) != "1",
                   let uuid = attr("UUID", m), let name = attr("ZoneName", m),
                   let loc = attr("Location", m), let ip = URL(string: loc)?.host {
                    newRooms.append(SonosRoom(uuid: uuid, name: name, ip: ip))
                    grouping[uuid] = coord.isEmpty ? uuid : coord
                }
                mSearch = me.upperBound
            }
            gSearch = ge.upperBound
        }

        var seen = Set<String>()
        rooms = newRooms.filter { seen.insert($0.uuid).inserted }.sorted { $0.name < $1.name }
        groupOf = grouping
    }

    private func parseMeta(_ xml: String, ip: String) {
        guard let meta = value("TrackMetaData", xml) else { now = nil; return }
        let didl = unescape(meta)
        let title = value("dc:title", didl) ?? ""
        let artist = value("dc:creator", didl) ?? value("r:albumArtist", didl) ?? ""
        let album = value("upnp:album", didl) ?? ""
        var art: URL?
        if let raw = value("upnp:albumArtURI", didl) {
            let u = unescape(raw)
            art = u.hasPrefix("http") ? URL(string: u) : URL(string: "http://\(ip):1400\(u)")
        }
        now = (title.isEmpty && artist.isEmpty) ? nil
            : NowPlaying(title: title, artist: artist, album: album, artURL: art)
    }

    private func value(_ tag: String, _ xml: String) -> String? {
        guard let a = xml.range(of: "<\(tag)>"),
              let b = xml.range(of: "</\(tag)>", range: a.upperBound..<xml.endIndex) else { return nil }
        return String(xml[a.upperBound..<b.lowerBound])
    }

    /// Like value() but tolerates attributes: `<res protocolInfo="…">URI</res>`.
    private func tagValue(_ tag: String, _ xml: String) -> String? {
        guard let open = xml.range(of: "<\(tag)"),
              let gt = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
              let close = xml.range(of: "</\(tag)>", range: gt.upperBound..<xml.endIndex) else { return nil }
        return String(xml[gt.upperBound..<close.lowerBound])
    }

    private func parseItems(_ didl: String, seedIP: String) -> [SonosItem] {
        var out: [SonosItem] = []
        for tag in ["item", "container"] {
            var s = didl.startIndex
            while let os = didl.range(of: "<\(tag) ", range: s..<didl.endIndex),
                  let oe = didl.range(of: "</\(tag)>", range: os.upperBound..<didl.endIndex) {
                let block = String(didl[os.lowerBound..<oe.upperBound])
                let title = (tagValue("dc:title", block).map(unescape)) ?? "Untitled"
                let artist = (tagValue("dc:creator", block).map(unescape)) ?? ""
                let uri = (tagValue("res", block).map(unescape)) ?? ""
                let md = tagValue("r:resMD", block) ?? ""   // keep escaped for re-embedding
                var art: URL?
                if let a = tagValue("upnp:albumArtURI", block) {
                    let u = unescape(a)
                    art = u.hasPrefix("http") ? URL(string: u) : URL(string: "http://\(seedIP):1400\(u)")
                }
                let idv = attr("id", block) ?? title
                if !uri.isEmpty {
                    out.append(SonosItem(id: idv, title: title, uri: uri, metadata: md,
                                         artURL: art, isContainer: tag == "container", artist: artist))
                }
                s = oe.upperBound
            }
        }
        return out
    }

    /// "H:MM:SS" or "M:SS" → seconds. Tolerates "NOT_IMPLEMENTED"/garbage → 0.
    private func secondsFrom(_ s: String) -> TimeInterval {
        let parts = s.split(separator: ":")
        guard !parts.isEmpty, parts.allSatisfy({ Int($0) != nil }) else { return 0 }
        return parts.reduce(0) { $0 * 60 + (TimeInterval(Int($1) ?? 0)) }
    }

    /// seconds → "H:MM:SS" for AVTransport Seek REL_TIME targets.
    private func hmsFrom(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded()))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func attr(_ name: String, _ s: String) -> String? {
        guard let r = s.range(of: "\(name)=\""),
              let e = s.range(of: "\"", range: r.upperBound..<s.endIndex) else { return nil }
        return String(s[r.upperBound..<e.lowerBound])
    }

    private func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
         .replacingOccurrences(of: "&gt;", with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&apos;", with: "'")
         .replacingOccurrences(of: "&amp;", with: "&")
    }
}
