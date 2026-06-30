import Foundation
import Network

/// HID button codes (from pyatv's HidCommand enum).
enum HidCommand: Int {
    case up = 1, down = 2, left = 3, right = 4, menu = 5, select = 6, home = 7
    case volumeUp = 8, volumeDown = 9, siri = 10, screensaver = 11, sleep = 12
    case wake = 13, playPause = 14, channelUp = 15, channelDown = 16, guide = 17
    case pageUp = 18, pageDown = 19
}

enum ClientError: Error { case timeout, badResponse, notConnected, commandFailed(String) }

/// High-level Companion client: connect, pair-verify with stored credentials,
/// then send commands over the encrypted session.
final class CompanionClient {
    private let conn: CompanionConnection
    private let creds: CompanionCredentials
    private let pv = CompanionPairVerify()

    private let lock = NSLock()
    private var xid = Int.random(in: 0..<60000)
    private var pending: [ResponseKey: CheckedContinuation<OPACK, Error>] = [:]
    private let timeoutQueue = DispatchQueue(label: "atv.timeout")

    private(set) var sid: UInt64 = 0
    var verbose = false

    private enum ResponseKey: Hashable { case xid(Int); case auth(FrameType) }

    init(connection: CompanionConnection, credentials: CompanionCredentials) {
        conn = connection
        creds = credentials
        conn.onFrame = { [weak self] ft, data in self?.handleFrame(ft, data) }
    }

    convenience init(host: String, port: UInt16, credentials: CompanionCredentials) {
        self.init(connection: CompanionConnection(host: host, port: port), credentials: credentials)
    }

    /// Connect via a Bonjour service endpoint (auto-resolves IP from the name).
    convenience init(endpoint: NWEndpoint, credentials: CompanionCredentials) {
        self.init(connection: CompanionConnection(endpoint: endpoint), credentials: credentials)
    }

    // MARK: Lifecycle

    func start() async throws {
        try await conn.connect()
        try await pairVerify()
        let keys = pv.sessionKeys()
        conn.enableEncryption(output: keys.output, input: keys.input)
        if verbose { print("  [encryption enabled]") }
        try await systemInfo()
        try await sessionStart()
        try await touchStart()
        if verbose { print("  [session 0x\(String(sid, radix: 16))]") }
    }

    func close() { conn.close() }

    // MARK: Pair-verify

    private func pairVerify() async throws {
        let m1 = TLV.write([(.seqNo, Data([0x01])), (.publicKey, pv.verifyPublic)])
        let m2 = try await exchange(.pvStart,
                                    [("_pd", .data(m1)), ("_auTy", .int(4))],
                                    awaitFrame: .pvNext)
        guard let pd = m2["_pd"]?.dataValue else { throw ClientError.badResponse }
        let tlv = TLV.read(pd)
        guard let serverPub = tlv[TLV.Tag.publicKey.rawValue],
              let enc = tlv[TLV.Tag.encryptedData.rawValue] else { throw ClientError.badResponse }

        let reply = try pv.step2(serverPub: serverPub, encrypted: enc, creds: creds)
        let m3 = TLV.write([(.seqNo, Data([0x03])), (.encryptedData, reply)])
        _ = try await exchange(.pvNext, [("_pd", .data(m3))], awaitFrame: .pvNext)
    }

    // MARK: Commands

    private func systemInfo() async throws {
        _ = try await exchange(.eOPACK, [
            ("_i", .string("_systemInfo")),
            ("_t", .int(2)),
            ("_c", .obj([
                ("_bf", .int(0)),
                ("_cf", .int(512)),
                ("_clFl", .int(128)),
                ("_i", .string("aabbccddeeff")),
                ("_idsID", .data(creds.clientId)),
                ("_pubID", .string("AA:BB:CC:DD:EE:FF")),
                ("_sf", .int(256)),
                ("_sv", .string("170.18")),
                ("model", .string("KitchenHub")),
                ("name", .string("KitchenHub")),
            ])),
        ])
    }

    private func sessionStart() async throws {
        let localSid = Int(UInt32.random(in: 0..<UInt32.max))
        let resp = try await exchange(.eOPACK, [
            ("_i", .string("_sessionStart")),
            ("_t", .int(2)),
            ("_c", .obj([("_srvT", .string("com.apple.tvremoteservices")), ("_sid", .int(localSid))])),
        ])
        guard let remoteSid = resp["_c"]?["_sid"]?.intValue else { throw ClientError.badResponse }
        sid = (UInt64(UInt32(truncatingIfNeeded: remoteSid)) << 32) | UInt64(UInt32(truncatingIfNeeded: localSid))
    }

    /// Press and release a button.
    func press(_ command: HidCommand) async throws {
        try await hid(down: true, command)
        try await hid(down: false, command)
    }

    private func hid(down: Bool, _ command: HidCommand) async throws {
        _ = try await exchange(.eOPACK, [
            ("_i", .string("_hidC")),
            ("_t", .int(2)),
            ("_c", .obj([("_hBtS", .int(down ? 1 : 2)), ("_hidC", .int(command.rawValue))])),
        ])
    }

    // MARK: Touch / trackpad

    private var touchBase: UInt64 = 0

    private func touchStart() async throws {
        _ = try await exchange(.eOPACK, [
            ("_i", .string("_touchStart")), ("_t", .int(2)),
            ("_c", .obj([("_height", .double(1000)), ("_tFl", .int(0)), ("_width", .double(1000))])),
        ])
        touchBase = DispatchTime.now().uptimeNanoseconds
    }

    /// Send one touch sample. phase: 1=press, 3=move/hold, 4=release. x,y in [0,1000].
    func touch(x: Int, y: Int, phase: Int) {
        let now = DispatchTime.now().uptimeNanoseconds
        let ns = Int(now >= touchBase ? now &- touchBase : 0)
        fire(.eOPACK, [
            ("_i", .string("_hidT")), ("_t", .int(1)),
            ("_c", .obj([
                ("_ns", .int(ns)), ("_tFg", .int(1)),
                ("_cx", .int(clampCoord(x))), ("_tPh", .int(phase)), ("_cy", .int(clampCoord(y))),
            ])),
        ])
    }

    /// Linear swipe (testing helper).
    func swipe(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, durationMs: Int = 240) async {
        let steps = max(2, durationMs / 16)
        touch(x: x0, y: y0, phase: 1)
        for i in 1..<steps {
            let t = Double(i) / Double(steps)
            touch(x: Int(Double(x0) + Double(x1 - x0) * t),
                  y: Int(Double(y0) + Double(y1 - y0) * t), phase: 3)
            try? await Task.sleep(nanoseconds: 16_000_000)
        }
        touch(x: x1, y: y1, phase: 4)
    }

    private func clampCoord(_ v: Int) -> Int { min(max(v, 0), 1000) }

    private func fire(_ frameType: FrameType, _ pairs: [(String, OPACK)]) {
        lock.lock(); let x = xid; xid += 1; lock.unlock()
        var all = pairs; all.append(("_x", .int(x)))
        conn.send(frameType, OPACK.obj(all).encoded())
    }

    // MARK: Exchange plumbing

    private func exchange(_ frameType: FrameType,
                          _ pairs: [(String, OPACK)],
                          awaitFrame: FrameType? = nil,
                          timeout: Double = 5.0) async throws -> OPACK {
        lock.lock(); let x = xid; xid += 1; lock.unlock()
        var all = pairs
        all.append(("_x", .int(x)))
        let key: ResponseKey = awaitFrame.map { .auth($0) } ?? .xid(x)
        let encoded = OPACK.obj(all).encoded()

        return try await withCheckedThrowingContinuation { cont in
            lock.lock(); pending[key] = cont; lock.unlock()
            conn.send(frameType, encoded)
            timeoutQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let c = self.pending.removeValue(forKey: key)
                self.lock.unlock()
                c?.resume(throwing: ClientError.timeout)
            }
        }
    }

    private func handleFrame(_ ft: FrameType, _ data: Data) {
        guard let (obj, _) = try? OPACK.decode(data) else { return }
        if verbose { print("  << \(ft): \(obj)") }

        let key: ResponseKey
        switch ft {
        case .pvStart, .pvNext, .psStart, .psNext:
            key = .auth(.pvNext)   // device replies always arrive as *_Next
        default:
            // Regular OPACK: events have _t==1; responses _t==3 matched by _x.
            if obj["_t"]?.intValue == 1 { return }
            guard let x = obj["_x"]?.intValue else { return }
            key = .xid(x)
        }
        lock.lock(); let c = pending.removeValue(forKey: key); lock.unlock()
        c?.resume(returning: obj)
    }
}
