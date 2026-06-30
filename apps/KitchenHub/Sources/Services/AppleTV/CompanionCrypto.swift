import Foundation
import CryptoKit

extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var d = Data(); d.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            d.append(b); i += 2
        }
        self = d
    }
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// HAP credentials parsed from pyatv's `ltpk:ltsk:atv_id:client_id` string.
struct CompanionCredentials {
    let ltpk: Data      // ATV Ed25519 public key (32 bytes)
    let ltsk: Data      // our Ed25519 private seed (32 bytes)
    let atvId: Data     // ATV identifier (ASCII UUID bytes)
    let clientId: Data  // our identifier (ASCII UUID bytes)

    init?(string: String) {
        let parts = string.split(separator: ":").map(String.init)
        guard parts.count == 4,
              let a = Data(hexString: parts[0]), let b = Data(hexString: parts[1]),
              let c = Data(hexString: parts[2]), let d = Data(hexString: parts[3])
        else { return nil }
        ltpk = a; ltsk = b; atvId = c; clientId = d
    }
}

enum CompanionAuthError: Error { case decryptFailed, identifierMismatch, badSignature, missingField }

/// ChaCha20-Poly1305 with the HAP pair-verify static string nonces (8 ASCII
/// bytes padded to 12 with 4 leading zeros). No AAD.
enum PVCipher {
    static func nonce(_ label: String) -> ChaChaPoly.Nonce {
        var n = Data(repeating: 0, count: 4)
        n.append(Data(label.utf8))           // e.g. "PV-Msg02"
        return try! ChaChaPoly.Nonce(data: n)
    }
    static func seal(_ plaintext: Data, key: Data, label: String) -> Data {
        let box = try! ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce(label))
        return box.ciphertext + box.tag
    }
    static func open(_ data: Data, key: Data, label: String) throws -> Data {
        guard data.count >= 16 else { throw CompanionAuthError.decryptFailed }
        let ct = data.prefix(data.count - 16)
        let tag = data.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: nonce(label), ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key))
    }
}

func hkdfSHA512(ikm: Data, salt: String, info: String, length: Int = 32) -> Data {
    let key = HKDF<SHA512>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: ikm),
        salt: Data(salt.utf8),
        info: Data(info.utf8),
        outputByteCount: length
    )
    return key.withUnsafeBytes { Data($0) }
}

/// Drives the Companion pair-verify exchange and derives session keys, reusing
/// stored long-term credentials. Mirrors pyatv's SRPAuthHandler verify path.
final class CompanionPairVerify {
    private let verifyPrivate = Curve25519.KeyAgreement.PrivateKey()
    let verifyPublic: Data
    private var shared: Data?

    init() { verifyPublic = verifyPrivate.publicKey.rawRepresentation }

    /// Given the device's PV_Start response (server public + encrypted TLV),
    /// validate the device and return our encrypted reply TLV for PV_Next.
    func step2(serverPub: Data, encrypted: Data, creds: CompanionCredentials) throws -> Data {
        let serverKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: serverPub)
        let secret = try verifyPrivate.sharedSecretFromKeyAgreement(with: serverKey)
        let sharedBytes = secret.withUnsafeBytes { Data($0) }
        shared = sharedBytes

        let sessionKey = hkdfSHA512(ikm: sharedBytes,
                                    salt: "Pair-Verify-Encrypt-Salt",
                                    info: "Pair-Verify-Encrypt-Info")

        let decrypted = try PVCipher.open(encrypted, key: sessionKey, label: "PV-Msg02")
        let tlv = TLV.read(decrypted)
        guard let identifier = tlv[TLV.Tag.identifier.rawValue],
              let signature = tlv[TLV.Tag.signature.rawValue] else {
            throw CompanionAuthError.missingField
        }
        guard identifier == creds.atvId else { throw CompanionAuthError.identifierMismatch }

        // Verify the device's signature over (serverPub + atvId + ourPub) using its LTPK.
        let info = serverPub + identifier + verifyPublic
        let ltpk = try Curve25519.Signing.PublicKey(rawRepresentation: creds.ltpk)
        guard ltpk.isValidSignature(signature, for: info) else { throw CompanionAuthError.badSignature }

        // Sign (ourPub + clientId + serverPub) with our LTSK.
        let deviceInfo = verifyPublic + creds.clientId + serverPub
        let ltsk = try Curve25519.Signing.PrivateKey(rawRepresentation: creds.ltsk)
        let deviceSignature = try ltsk.signature(for: deviceInfo)

        let replyTLV = TLV.write([
            (.identifier, creds.clientId),
            (.signature, deviceSignature),
        ])
        return PVCipher.seal(replyTLV, key: sessionKey, label: "PV-Msg03")
    }

    /// Session encryption keys derived after a successful verify.
    func sessionKeys() -> (output: Data, input: Data) {
        let s = shared!
        return (hkdfSHA512(ikm: s, salt: "", info: "ClientEncrypt-main"),
                hkdfSHA512(ikm: s, salt: "", info: "ServerEncrypt-main"))
    }
}
