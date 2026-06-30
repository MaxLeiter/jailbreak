import Foundation
import Network
import CryptoKit

enum FrameType: UInt8 {
    case unknown = 0, noOp = 1
    case psStart = 3, psNext = 4, pvStart = 5, pvNext = 6
    case uOPACK = 7, eOPACK = 8, pOPACK = 9
    case paReq = 10, paRsp = 11
    case sessionStartReq = 16, sessionStartResp = 17, sessionData = 18
}

/// ChaCha20-Poly1305 session layer for E_OPACK frames. 12-byte little-endian
/// counter nonces, separate out/in counters, 4-byte frame header as AAD.
final class ChaChaSession {
    private let outKey: SymmetricKey
    private let inKey: SymmetricKey
    private var outCounter: UInt64 = 0
    private var inCounter: UInt64 = 0

    init(out: Data, input: Data) {
        outKey = SymmetricKey(data: out)
        inKey = SymmetricKey(data: input)
    }

    private func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var c = counter.littleEndian
        let n = Data(bytes: &c, count: 8) + Data(repeating: 0, count: 4)  // 12-byte LE
        return try! ChaChaPoly.Nonce(data: n)
    }

    func encrypt(_ data: Data, aad: Data) -> Data {
        let box = try! ChaChaPoly.seal(data, using: outKey, nonce: nonce(outCounter), authenticating: aad)
        outCounter += 1
        return box.ciphertext + box.tag
    }

    func decrypt(_ data: Data, aad: Data) throws -> Data {
        let ct = data.prefix(data.count - 16)
        let tag = data.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce(inCounter), ciphertext: ct, tag: tag)
        let out = try ChaChaPoly.open(box, using: inKey, authenticating: aad)
        inCounter += 1
        return out
    }
}

/// Low-level Companion TCP connection: framing + optional encryption.
final class CompanionConnection {
    private let conn: NWConnection
    private let queue = DispatchQueue(label: "atv.companion")
    private var buffer = Data()
    private var session: ChaChaSession?
    private var connectCont: CheckedContinuation<Void, Error>?

    var onFrame: ((FrameType, Data) -> Void)?

    init(host: String, port: UInt16) {
        conn = NWConnection(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: port)!,
                            using: .tcp)
    }

    /// Connect via a Bonjour service endpoint (auto-resolves the IP).
    init(endpoint: NWEndpoint) {
        conn = NWConnection(to: endpoint, using: .tcp)
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connectCont = cont
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let c = self.connectCont { self.connectCont = nil; c.resume() }
                    self.receiveLoop()
                case .failed(let e), .waiting(let e):
                    if let c = self.connectCont { self.connectCont = nil; c.resume(throwing: e) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    func enableEncryption(output: Data, input: Data) {
        session = ChaChaSession(out: output, input: input)
    }

    func close() { conn.cancel() }

    func send(_ frameType: FrameType, _ payload: Data) {
        var payloadLen = payload.count
        if session != nil && payload.count > 0 { payloadLen += 16 }
        var header = Data([frameType.rawValue])
        header.append(UInt8((payloadLen >> 16) & 0xFF))
        header.append(UInt8((payloadLen >> 8) & 0xFF))
        header.append(UInt8(payloadLen & 0xFF))

        var body = payload
        if let s = session, payload.count > 0 {
            body = s.encrypt(payload, aad: header)
        }
        conn.send(content: header + body, completion: .contentProcessed { _ in })
    }

    private func receiveLoop() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drain()
            }
            if error != nil || isComplete { return }
            self.receiveLoop()
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let arr = [UInt8](buffer)
            let len = (Int(arr[1]) << 16) | (Int(arr[2]) << 8) | Int(arr[3])
            let total = 4 + len
            if arr.count < total { break }
            let header = Data(arr[0..<4])
            var payload = Data(arr[4..<total])
            buffer = Data(arr[total...])
            if let s = session, payload.count > 0 {
                do { payload = try s.decrypt(payload, aad: header) }
                catch { continue }
            }
            if let ft = FrameType(rawValue: header[0]) {
                onFrame?(ft, payload)
            }
        }
    }
}
