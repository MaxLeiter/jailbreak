import Foundation

/// HomeKit-style TLV8 used inside Companion pair-verify frames.
/// Port of pyatv's `auth/hap_tlv8.py` (single-level only).
enum TLV {
    enum Tag: UInt8 {
        case method = 0x00
        case identifier = 0x01
        case salt = 0x02
        case publicKey = 0x03
        case proof = 0x04
        case encryptedData = 0x05
        case seqNo = 0x06
        case error = 0x07
        case signature = 0x0A
    }

    /// Encode ordered (tag, value) pairs. Values > 255 bytes are split into
    /// multiple chunks under the same tag (concatenated on read).
    static func write(_ items: [(Tag, Data)]) -> Data {
        var out = Data()
        for (tag, value) in items {
            var pos = 0
            if value.isEmpty {
                out.append(tag.rawValue); out.append(0)
                continue
            }
            while pos < value.count {
                let size = min(value.count - pos, 255)
                out.append(tag.rawValue)
                out.append(UInt8(size))
                out.append(value.subdata(in: (value.startIndex + pos)..<(value.startIndex + pos + size)))
                pos += size
            }
        }
        return out
    }

    /// Parse TLV8 into a tag→value map, concatenating repeated tags.
    static func read(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        let bytes = Array(data)
        var pos = 0
        while pos + 1 < bytes.count {
            let tag = bytes[pos]
            let len = Int(bytes[pos + 1])
            guard pos + 2 + len <= bytes.count else { break }
            let value = Data(bytes[(pos + 2)..<(pos + 2 + len)])
            result[tag, default: Data()].append(value)
            pos += 2 + len
        }
        return result
    }
}
