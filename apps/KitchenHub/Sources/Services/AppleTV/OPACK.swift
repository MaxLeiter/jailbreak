import Foundation

/// OPACK serialization (Apple's binary format used by the Companion protocol).
/// Port of pyatv's `support/opack.py`, including the object-list back-reference
/// dedup so encoded bytes match what a real device produces.
indirect enum OPACK {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case data(Data)
    case array([OPACK])
    case dict([(OPACK, OPACK)])   // ordered to match the wire

    /// Convenience for the common string-keyed dict.
    static func obj(_ pairs: [(String, OPACK)]) -> OPACK {
        .dict(pairs.map { (.string($0.0), $0.1) })
    }
}

// MARK: - Encoding

extension OPACK {
    func encoded() -> Data {
        var objectList: [Data] = []
        return Self.pack(self, &objectList)
    }

    private static func pack(_ value: OPACK, _ objectList: inout [Data]) -> Data {
        var packed = Data()
        switch value {
        case .null:
            packed = Data([0x04])
        case .bool(let b):
            packed = Data([b ? 0x01 : 0x02])
        case .int(let i):
            packed = packInt(i)
        case .double(let d):
            var le = d.bitPattern.littleEndian
            packed = Data([0x36]) + Data(bytes: &le, count: 8)
        case .string(let s):
            let e = Data(s.utf8)
            let n = e.count
            if n <= 0x20 { packed = Data([UInt8(0x40 + n)]) + e }
            else if n <= 0xFF { packed = Data([0x61]) + lenBytes(n, 1) + e }
            else if n <= 0xFFFF { packed = Data([0x62]) + lenBytes(n, 2) + e }
            else if n <= 0xFFFFFF { packed = Data([0x63]) + lenBytes(n, 3) + e }
            else { packed = Data([0x64]) + lenBytes(n, 4) + e }
        case .data(let d):
            let n = d.count
            if n <= 0x20 { packed = Data([UInt8(0x70 + n)]) + d }
            else if n <= 0xFF { packed = Data([0x91]) + lenBytes(n, 1) + d }
            else if n <= 0xFFFF { packed = Data([0x92]) + lenBytes(n, 2) + d }
            else if n <= 0xFFFFFFFF { packed = Data([0x93]) + lenBytes(n, 4) + d }
            else { packed = Data([0x94]) + lenBytes(n, 8) + d }
        case .array(let arr):
            packed = Data([UInt8(0xD0 + min(arr.count, 0xF))])
            for x in arr { packed += pack(x, &objectList) }
            if arr.count >= 0xF { packed += Data([0x03]) }
        case .dict(let pairs):
            packed = Data([UInt8(0xE0 + min(pairs.count, 0xF))])
            for (k, v) in pairs {
                packed += pack(k, &objectList)
                packed += pack(v, &objectList)
            }
            if pairs.count >= 0xF { packed += Data([0x03]) }
        }

        // Back-reference dedup (mirrors opack.py exactly).
        if let idx = objectList.firstIndex(of: packed) {
            if idx < 0x21 { return Data([UInt8(0xA0 + idx)]) }
            else if idx <= 0xFF { return Data([0xC1]) + lenBytes(idx, 1) }
            else if idx <= 0xFFFF { return Data([0xC2]) + lenBytes(idx, 2) }
            else if idx <= 0xFFFFFFFF { return Data([0xC3]) + lenBytes(idx, 4) }
            else { return Data([0xC4]) + lenBytes(idx, 8) }
        } else if packed.count > 1 {
            objectList.append(packed)
        }
        return packed
    }

    private static func packInt(_ i: Int) -> Data {
        if i < 0x28 && i >= 0 { return Data([UInt8(i + 8)]) }
        if i <= 0xFF { return Data([0x30]) + lenBytes(i, 1) }
        if i <= 0xFFFF { return Data([0x31]) + lenBytes(i, 2) }
        if i <= 0xFFFFFFFF { return Data([0x32]) + lenBytes(i, 4) }
        return Data([0x33]) + lenBytes(i, 8)
    }

    private static func lenBytes(_ value: Int, _ count: Int) -> Data {
        var v = UInt64(value).littleEndian
        return Data(bytes: &v, count: 8).prefix(count)
    }
}

// MARK: - Decoding

extension OPACK {
    static func decode(_ data: Data) throws -> (OPACK, Data) {
        var objectList: [OPACK] = []
        return try unpack(Array(data), &objectList)
    }

    enum DecodeError: Error { case truncated, badTag(UInt8) }

    private static func unpack(_ data: [UInt8], _ objectList: inout [OPACK]) throws -> (OPACK, Data) {
        guard let tag = data.first else { throw DecodeError.truncated }
        var value: OPACK
        var rest: [UInt8]
        var addToList = true

        func slice(_ from: Int) -> [UInt8] { Array(data[from...]) }
        func le(_ bytes: ArraySlice<UInt8>) -> Int {
            var r = 0; for (i, b) in bytes.enumerated() { r |= Int(b) << (8 * i) }; return r
        }

        switch tag {
        case 0x01: value = .bool(true); rest = slice(1); addToList = false
        case 0x02: value = .bool(false); rest = slice(1); addToList = false
        case 0x04: value = .null; rest = slice(1); addToList = false
        case 0x05:
            guard data.count >= 17 else { throw DecodeError.truncated }
            value = .data(Data(data[1..<17])); rest = slice(17)   // UUID as 16 raw bytes
        case 0x06:
            guard data.count >= 9 else { throw DecodeError.truncated }
            value = .int(le(data[1..<9])); rest = slice(9)
        case 0x08...0x2F:
            value = .int(Int(tag) - 8); rest = slice(1); addToList = false
        case 0x35:
            guard data.count >= 5 else { throw DecodeError.truncated }
            let bits = UInt32(le(data[1..<5])); value = .double(Double(Float(bitPattern: bits))); rest = slice(5)
        case 0x36:
            guard data.count >= 9 else { throw DecodeError.truncated }
            let bits = UInt64(UInt(bitPattern: le(data[1..<9]))); value = .double(Double(bitPattern: bits)); rest = slice(9)
        case let t where (t & 0xF0) == 0x30:
            let n = 1 << Int(t & 0xF)
            guard data.count >= 1 + n else { throw DecodeError.truncated }
            value = .int(le(data[1..<(1 + n)])); rest = slice(1 + n)
        case 0x40...0x60:
            let n = Int(tag) - 0x40
            guard data.count >= 1 + n else { throw DecodeError.truncated }
            value = .string(String(decoding: data[1..<(1 + n)], as: UTF8.self)); rest = slice(1 + n)
        case 0x61...0x64:
            let nb = Int(tag) & 0xF
            guard data.count >= 1 + nb else { throw DecodeError.truncated }
            let len = le(data[1..<(1 + nb)])
            guard data.count >= 1 + nb + len else { throw DecodeError.truncated }
            value = .string(String(decoding: data[(1 + nb)..<(1 + nb + len)], as: UTF8.self)); rest = slice(1 + nb + len)
        case 0x70...0x90:
            let n = Int(tag) - 0x70
            guard data.count >= 1 + n else { throw DecodeError.truncated }
            value = .data(Data(data[1..<(1 + n)])); rest = slice(1 + n)
        case 0x91...0x94:
            let nb = 1 << ((Int(tag) & 0xF) - 1)
            guard data.count >= 1 + nb else { throw DecodeError.truncated }
            let len = le(data[1..<(1 + nb)])
            guard data.count >= 1 + nb + len else { throw DecodeError.truncated }
            value = .data(Data(data[(1 + nb)..<(1 + nb + len)])); rest = slice(1 + nb + len)
        case let t where (t & 0xF0) == 0xD0:
            let count = Int(tag & 0xF)
            var out: [OPACK] = []
            var ptr = slice(1)
            if count == 0xF {
                while let f = ptr.first, f != 0x03 { let (v, r) = try unpack(ptr, &objectList); out.append(v); ptr = Array(r) }
                ptr = Array(ptr.dropFirst())
            } else {
                for _ in 0..<count { let (v, r) = try unpack(ptr, &objectList); out.append(v); ptr = Array(r) }
            }
            value = .array(out); rest = ptr; addToList = false
        case let t where (t & 0xE0) == 0xE0 && tag >= 0xE0 && tag <= 0xEF:
            let count = Int(tag & 0xF)
            var out: [(OPACK, OPACK)] = []
            var ptr = slice(1)
            if count == 0xF {
                while let f = ptr.first, f != 0x03 {
                    let (k, r1) = try unpack(ptr, &objectList)
                    let (v, r2) = try unpack(Array(r1), &objectList)
                    out.append((k, v)); ptr = Array(r2)
                }
                ptr = Array(ptr.dropFirst())
            } else {
                for _ in 0..<count {
                    let (k, r1) = try unpack(ptr, &objectList)
                    let (v, r2) = try unpack(Array(r1), &objectList)
                    out.append((k, v)); ptr = Array(r2)
                }
            }
            value = .dict(out); rest = ptr; addToList = false
        case 0xA0...0xC0:
            value = objectList[Int(tag) - 0xA0]; rest = slice(1); addToList = false
        case 0xC1...0xC4:
            let nb = Int(tag) - 0xC0
            guard data.count >= 1 + nb else { throw DecodeError.truncated }
            value = objectList[le(data[1..<(1 + nb)])]; rest = slice(1 + nb); addToList = false
        default:
            throw DecodeError.badTag(tag)
        }

        if addToList { objectList.append(value) }
        return (value, Data(rest))
    }
}

// MARK: - Response accessors

extension OPACK {
    /// Look up a string key in a dict value.
    subscript(_ key: String) -> OPACK? {
        if case .dict(let pairs) = self {
            for (k, v) in pairs { if case .string(let s) = k, s == key { return v } }
        }
        return nil
    }
    var intValue: Int? { if case .int(let i) = self { return i }; return nil }
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var dataValue: Data? { if case .data(let d) = self { return d }; return nil }
    var dictPairs: [(OPACK, OPACK)]? { if case .dict(let p) = self { return p }; return nil }
}
