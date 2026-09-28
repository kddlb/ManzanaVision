// SPDX-License-Identifier: GPL-2.0-only
// AAC framing for ISDB-T: ADTS (stream_type 0x0f) and LOAS/LATM (0x11),
// plus the AudioSpecificConfig both carry.

public let aacSampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050,
                             16000, 12000, 11025, 8000, 7350]

public struct AudioSpecificConfig: Sendable, Equatable {
    public var objectType: Int          // 2 = AAC-LC, 5 = SBR (explicit HE-AAC), 29 = PS
    public var sampleRate: Int          // core rate
    public var channelConfig: Int
    public var frameLengthFlag = false  // 960-sample frames
    public var sbr = false              // explicitly signalled
    public var ps = false
    public var extensionSampleRate: Int?
    public var coreObjectType: Int      // object type under SBR/PS

    /// Output rate after SBR (explicit, or implicit for low-rate AAC-LC)
    public var outputSampleRate: Int { extensionSampleRate ?? sampleRate }
    public var channels: Int { channelConfig == 7 ? 8 : channelConfig }
    public var samplesPerFrame: Int { frameLengthFlag ? 960 : 1024 }  // core samples

    public init(objectType: Int, sampleRate: Int, channelConfig: Int, frameLengthFlag: Bool = false,
                sbr: Bool = false, ps: Bool = false, extensionSampleRate: Int? = nil, coreObjectType: Int? = nil) {
        self.objectType = objectType
        self.sampleRate = sampleRate
        self.channelConfig = channelConfig
        self.frameLengthFlag = frameLengthFlag
        self.sbr = sbr
        self.ps = ps
        self.extensionSampleRate = extensionSampleRate
        self.coreObjectType = coreObjectType ?? objectType
    }

    private static func readObjectType(_ r: inout BitReader) throws -> Int {
        let t = try r.u(5)
        return t == 31 ? 32 + (try r.u(6)) : t
    }

    private static func readRate(_ r: inout BitReader) throws -> Int {
        let i = try r.u(4)
        if i == 15 { return try r.u(24) }
        guard i < aacSampleRates.count else { throw BitstreamError.invalid("sampling_frequency_index \(i)") }
        return aacSampleRates[i]
    }

    /// Parses an AudioSpecificConfig. bitLimit bounds the sync-extension probe
    /// (unknown inside LATM version 0, where it isn't attempted).
    public static func parse(_ r: inout BitReader, bitLimit: Int? = nil) throws -> AudioSpecificConfig {
        let start = r.position
        var aot = try readObjectType(&r)
        let rate = try readRate(&r)
        let chan = try r.u(4)
        var cfg = AudioSpecificConfig(objectType: aot, sampleRate: rate, channelConfig: chan)
        if aot == 5 || aot == 29 {
            cfg.sbr = true
            cfg.ps = aot == 29
            cfg.extensionSampleRate = try readRate(&r)
            aot = try readObjectType(&r)
        }
        cfg.coreObjectType = aot
        switch aot {
        case 1, 2, 3, 4, 6, 7, 17, 19, 20, 21, 22, 23:
            cfg.frameLengthFlag = try r.bit()
            if try r.bit() { try r.skip(14) }  // dependsOnCoreCoder → coreCoderDelay
            let ext = try r.bit()
            if chan == 0 { throw BitstreamError.invalid("program_config_element not supported") }
            if aot == 6 || aot == 20 { try r.skip(3) }
            if ext {
                if aot == 22 { try r.skip(16) }
                if [17, 19, 20, 23].contains(aot) { try r.skip(3) }
                try r.skip(1)  // extensionFlag3
            }
        default:
            throw BitstreamError.invalid("audio object type \(aot) not supported")
        }
        // backward-compatible explicit SBR/PS signalling after the core config
        if let limit = bitLimit, !cfg.sbr, limit - (r.position - start) >= 16 {
            var probe = r
            if try probe.u(11) == 0x2b7, try readObjectType(&probe) == 5, try probe.bit() {
                cfg.sbr = true
                cfg.extensionSampleRate = try readRate(&probe)
                if limit - (probe.position - start) >= 12, try probe.u(11) == 0x548 {
                    cfg.ps = try probe.bit()
                }
                r = probe
            }
        }
        return cfg
    }

    public static func parse(_ bytes: [UInt8]) throws -> AudioSpecificConfig {
        var r = BitReader(bytes)
        return try parse(&r, bitLimit: bytes.count * 8)
    }

    /// Implicit SBR: AAC-LC at ≤24 kHz in broadcast is HE-AAC with a doubled output rate
    public var withImplicitSBR: AudioSpecificConfig {
        guard !sbr, objectType == 2, sampleRate <= 24000 else { return self }
        var c = self
        c.sbr = true
        c.extensionSampleRate = sampleRate * 2
        return c
    }

    /// Serialises the config; SBR/PS are written explicitly (hierarchical)
    public func serialize() -> [UInt8] {
        var w = BitWriter()
        func rate(_ hz: Int) {
            if let i = aacSampleRates.firstIndex(of: hz) { w.write(i, bits: 4) } else {
                w.write(15, bits: 4)
                w.write(hz, bits: 24)
            }
        }
        w.write(ps ? 29 : (sbr ? 5 : coreObjectType), bits: 5)
        rate(sampleRate)
        w.write(channelConfig, bits: 4)
        if sbr {
            rate(outputSampleRate)
            w.write(coreObjectType, bits: 5)
        }
        w.write(frameLengthFlag ? 1 : 0, bits: 1)
        w.write(0, bits: 1)  // dependsOnCoreCoder
        w.write(0, bits: 1)  // extensionFlag
        return w.bytes
    }
}

/// Frame timestamps from the last PES anchor plus an exact frame count, so
/// rates like 44.1 kHz (2089.8 ticks per frame) don't accumulate truncation
struct FrameClock {
    private var anchor: Int64?
    private var framesSinceAnchor: Int64 = 0

    mutating func reset() {
        anchor = nil
        framesSinceAnchor = 0
    }

    /// Timestamp for the next frame; pesPTS (if any) re-anchors
    mutating func next(pesPTS: Int64?, samplesPerFrame: Int, sampleRate: Int) -> Int64? {
        if let p = pesPTS {
            anchor = p
            framesSinceAnchor = 0
        }
        guard let a = anchor else { return nil }
        let pts = a + framesSinceAnchor * Int64(samplesPerFrame) * 90000 / Int64(sampleRate)
        framesSinceAnchor += 1
        return pts
    }
}

public struct AACFrame: Sendable {
    public var data: [UInt8]         // raw_data_block(s)
    public var pts: Int64?           // unwrapped 90 kHz
    public var config: AudioSpecificConfig
    public var damaged: Bool
}

/// ADTS frames out of audio PES (frames may straddle PES boundaries)
public struct ADTSParser {
    private var carry: [UInt8] = []
    private var ptsUnwrap = TimestampUnwrapper()
    private var clock = FrameClock()
    public private(set) var frames = 0
    public private(set) var syncLosses = 0

    public init() {}

    public mutating func reset() {
        carry.removeAll()
        ptsUnwrap.reset()
        clock.reset()
    }

    public mutating func feed(_ pes: PESPacket) -> [AACFrame] {
        if pes.damaged { carry.removeAll() }
        // the PES timestamp belongs to the first frame starting in it
        var pesPTS = pes.pts.map { ptsUnwrap.unwrap($0) }
        let b = carry + pes.payload
        var i = 0
        var out: [AACFrame] = []
        while i + 7 <= b.count {
            guard b[i] == 0xff, b[i + 1] & 0xf6 == 0xf0 else {
                i += 1
                syncLosses += 1
                continue
            }
            let protectionAbsent = b[i + 1] & 1 == 1
            let profile = Int(b[i + 2] >> 6)
            let rateIndex = Int(b[i + 2] >> 2 & 0x0f)
            let chan = Int(b[i + 2] & 1) << 2 | Int(b[i + 3] >> 6)
            let length = Int(b[i + 3] & 3) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
            let blocks = Int(b[i + 6] & 3) + 1
            let header = protectionAbsent ? 7 : 9
            guard rateIndex < aacSampleRates.count, length > header else {
                i += 1
                syncLosses += 1
                continue
            }
            guard i + length <= b.count else { break }
            let cfg = AudioSpecificConfig(objectType: profile + 1, sampleRate: aacSampleRates[rateIndex],
                                          channelConfig: chan)
            let pts = clock.next(pesPTS: pesPTS, samplesPerFrame: 1024 * blocks, sampleRate: cfg.sampleRate)
            out.append(AACFrame(data: Array(b[(i + header)..<(i + length)]), pts: pts, config: cfg,
                                damaged: pes.damaged))
            pesPTS = nil
            frames += 1
            i += length
        }
        carry = Array(b[i...])
        return out
    }
}

/// LOAS/LATM (AudioSyncStream + AudioMuxElement(1)) as used by ISDB-T
public struct LATMParser {
    private var carry: [UInt8] = []
    private var ptsUnwrap = TimestampUnwrapper()
    private var clock = FrameClock()
    public private(set) var config: AudioSpecificConfig?
    private var frameLengthType = 0
    private var otherDataPresent = false
    private var otherDataLenBits = 0
    private var crcPresent = false
    private var audioMuxVersion = 0
    private var audioMuxVersionA = 0
    public private(set) var frames = 0
    public private(set) var configs = 0
    public private(set) var skippedWithoutConfig = 0
    public private(set) var errors = 0

    public init() {}

    public mutating func reset() {
        carry.removeAll()
        ptsUnwrap.reset()
        clock.reset()
    }

    public mutating func feed(_ pes: PESPacket) -> [AACFrame] {
        if pes.damaged { carry.removeAll() }
        var pesPTS = pes.pts.map { ptsUnwrap.unwrap($0) }
        let b = carry + pes.payload
        var i = 0
        var out: [AACFrame] = []
        while i + 3 <= b.count {
            guard b[i] == 0x56, b[i + 1] & 0xe0 == 0xe0 else {
                i += 1
                continue
            }
            let length = Int(b[i + 1] & 0x1f) << 8 | Int(b[i + 2])
            guard i + 3 + length <= b.count else { break }
            let element = Array(b[(i + 3)..<(i + 3 + length)])
            i += 3 + length
            do {
                guard let payload = try audioMuxElement(element), let cfg = config else {
                    skippedWithoutConfig += 1
                    continue
                }
                let pts = clock.next(pesPTS: pesPTS, samplesPerFrame: cfg.samplesPerFrame, sampleRate: cfg.sampleRate)
                out.append(AACFrame(data: payload, pts: pts, config: cfg, damaged: pes.damaged))
                pesPTS = nil
                frames += 1
            } catch {
                errors += 1
            }
        }
        carry = Array(b[i...])
        return out
    }

    private static func latmValue(_ r: inout BitReader) throws -> Int {
        let bytes = try r.u(2) + 1
        return try r.u(8 * bytes)
    }

    /// Returns the frame's payload, or nil if no StreamMuxConfig has been seen yet
    private mutating func audioMuxElement(_ bytes: [UInt8]) throws -> [UInt8]? {
        var r = BitReader(bytes)
        if try !r.bit() {  // useSameStreamMux == 0
            try streamMuxConfig(&r)
        }
        guard config != nil else { return nil }
        guard audioMuxVersionA == 0 else { throw BitstreamError.invalid("audioMuxVersionA") }
        guard frameLengthType == 0 else { throw BitstreamError.invalid("frameLengthType \(frameLengthType)") }
        // PayloadLengthInfo: 255-escaped byte count
        var length = 0
        while true {
            let v = try r.u(8)
            length += v
            if v != 255 { break }
        }
        var payload = [UInt8](repeating: 0, count: length)
        for k in 0..<length { payload[k] = UInt8(try r.u(8)) }
        return payload
    }

    private mutating func streamMuxConfig(_ r: inout BitReader) throws {
        audioMuxVersion = try r.u(1)
        audioMuxVersionA = audioMuxVersion == 1 ? try r.u(1) : 0
        guard audioMuxVersionA == 0 else { throw BitstreamError.invalid("audioMuxVersionA") }
        if audioMuxVersion == 1 { _ = try Self.latmValue(&r) }  // taraBufferFullness
        guard try r.bit() else { throw BitstreamError.invalid("allStreamsSameTimeFraming = 0") }
        guard try r.u(6) == 0 else { throw BitstreamError.invalid("numSubFrames > 0") }
        guard try r.u(4) == 0 else { throw BitstreamError.invalid("numProgram > 0") }
        guard try r.u(3) == 0 else { throw BitstreamError.invalid("numLayer > 0") }
        let asc: AudioSpecificConfig
        if audioMuxVersion == 0 {
            asc = try AudioSpecificConfig.parse(&r)
        } else {
            let ascLen = try Self.latmValue(&r)
            let start = r.position
            asc = try AudioSpecificConfig.parse(&r, bitLimit: ascLen)
            try r.skip(max(0, ascLen - (r.position - start)))  // fillBits
        }
        frameLengthType = try r.u(3)
        guard frameLengthType == 0 else { throw BitstreamError.invalid("frameLengthType \(frameLengthType)") }
        try r.skip(8)  // latmBufferFullness
        otherDataPresent = try r.bit()
        if otherDataPresent {
            if audioMuxVersion == 1 {
                otherDataLenBits = try Self.latmValue(&r)
            } else {
                var len = 0
                var esc = true
                while esc {
                    esc = try r.bit()
                    len = len << 8 + (try r.u(8))
                }
                otherDataLenBits = len
            }
        }
        crcPresent = try r.bit()
        if crcPresent { try r.skip(8) }
        if config != asc { configs += 1 }
        config = asc
    }
}

/// AAC with the framing detected from the data. Broadcasters mislabel it:
/// Mega 9.2 declares LATM (stream_type 0x11) but sends ADTS.
public struct AACStreamParser {
    public enum Framing: Sendable, Equatable { case unknown, adts, loas }

    public private(set) var framing: Framing = .unknown
    private var adts = ADTSParser()
    private var latm = LATMParser()

    public init() {}

    public var frames: Int { framing == .adts ? adts.frames : latm.frames }
    public var latmParser: LATMParser? { framing == .loas ? latm : nil }
    public var adtsParser: ADTSParser? { framing == .adts ? adts : nil }

    public mutating func reset() {
        adts.reset()
        latm.reset()
    }

    public mutating func feed(_ pes: PESPacket) -> [AACFrame] {
        if framing == .unknown {
            framing = Self.detect(pes.payload)
        }
        switch framing {
        case .adts: return adts.feed(pes)
        case .loas: return latm.feed(pes)
        case .unknown: return []
        }
    }

    /// Looks for two consecutive syncs of either kind
    static func detect(_ b: [UInt8]) -> Framing {
        var i = 0
        while i + 6 < b.count {
            if b[i] == 0xff, b[i + 1] & 0xf6 == 0xf0 {
                let len = Int(b[i + 3] & 3) << 11 | Int(b[i + 4]) << 3 | Int(b[i + 5] >> 5)
                if len > 7, i + len + 1 < b.count, b[i + len] == 0xff, b[i + len + 1] & 0xf6 == 0xf0 { return .adts }
            }
            if b[i] == 0x56, b[i + 1] & 0xe0 == 0xe0 {
                let len = Int(b[i + 1] & 0x1f) << 8 | Int(b[i + 2])
                if i + 3 + len + 1 < b.count, b[i + 3 + len] == 0x56, b[i + 4 + len] & 0xe0 == 0xe0 { return .loas }
            }
            i += 1
        }
        return .unknown
    }
}
