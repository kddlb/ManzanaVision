// SPDX-License-Identifier: GPL-2.0-only

public enum BitstreamError: Error, Sendable, Equatable {
    case overrun
    case invalid(String)
}

/// MSB-first bit reader over a byte buffer, with the Exp-Golomb codes H.264 uses.
public struct BitReader {
    public let bytes: [UInt8]
    public private(set) var position = 0  // in bits

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public init<C: Collection>(_ bytes: C) where C.Element == UInt8 {
        self.bytes = Array(bytes)
    }

    public var bitsLeft: Int { bytes.count * 8 - position }
    public var isByteAligned: Bool { position % 8 == 0 }

    public mutating func bit() throws -> Bool {
        guard position < bytes.count * 8 else { throw BitstreamError.overrun }
        let b = bytes[position >> 3] >> (7 - UInt8(position & 7)) & 1
        position += 1
        return b == 1
    }

    /// Up to 64 bits, MSB first
    public mutating func bits(_ n: Int) throws -> UInt64 {
        precondition(n >= 0 && n <= 64)
        guard n <= bitsLeft else { throw BitstreamError.overrun }
        var v: UInt64 = 0
        for _ in 0..<n {
            v = v << 1 | (try bit() ? 1 : 0)
        }
        return v
    }

    public mutating func u(_ n: Int) throws -> Int { Int(try bits(n)) }

    public mutating func skip(_ n: Int) throws {
        guard n <= bitsLeft else { throw BitstreamError.overrun }
        position += n
    }

    public mutating func byteAlign() {
        position = (position + 7) & ~7
    }

    /// Unsigned Exp-Golomb, ue(v)
    public mutating func ue() throws -> Int {
        var zeros = 0
        while try !bit() {
            zeros += 1
            if zeros > 31 { throw BitstreamError.invalid("ue(v) too long") }
        }
        return (1 << zeros) - 1 + (try u(zeros))
    }

    /// Signed Exp-Golomb, se(v)
    public mutating func se() throws -> Int {
        let k = try ue()
        return k & 1 == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

/// Bit writer, MSB first (for building AudioSpecificConfigs and the like)
public struct BitWriter {
    public private(set) var bytes: [UInt8] = []
    private var used = 0  // bits used in the last byte

    public init() {}

    public mutating func write(_ value: UInt64, bits n: Int) {
        for i in stride(from: n - 1, through: 0, by: -1) {
            if used == 0 { bytes.append(0) }
            if value >> UInt64(i) & 1 == 1 {
                bytes[bytes.count - 1] |= 1 << (7 - UInt8(used))
            }
            used = (used + 1) & 7
        }
    }

    public mutating func write(_ value: Int, bits n: Int) { write(UInt64(value), bits: n) }
}

/// Removes H.264 emulation-prevention bytes (00 00 03 → 00 00)
public func unescapeRBSP<C: Collection>(_ data: C) -> [UInt8] where C.Element == UInt8 {
    var out: [UInt8] = []
    out.reserveCapacity(data.count)
    var zeros = 0
    for b in data {
        if zeros >= 2 && b == 0x03 {
            zeros = 0
            continue
        }
        out.append(b)
        zeros = b == 0 ? zeros + 1 : 0
    }
    return out
}
