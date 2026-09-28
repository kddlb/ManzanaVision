// SPDX-License-Identifier: GPL-2.0-only
import Foundation
@testable import ManzanaStream
import Testing

enum Fixtures {
    static let dir: URL? = ProcessInfo.processInfo.environment["MANZANA_FIXTURES"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    static let clips = ["rf27-5min-20s", "rf32-5min-20s"]

    static var available: Bool {
        guard let dir else { return false }
        return clips.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent("\($0).ts").path) }
    }

    struct Expected: Decodable {
        struct Stream: Decodable {
            let id: String
            let codec_name: String?
            let codec_type: String?
            let nb_read_packets: String?
            let nb_read_frames: String?
            var pid: UInt16 { UInt16(id.dropFirst(2), radix: 16)! }
        }
        let streams: [Stream]
    }

    static func load(_ clip: String) throws -> (ts: Data, expected: [Expected.Stream]) {
        let ts = try Data(contentsOf: dir!.appendingPathComponent("\(clip).ts"))
        let json = try Data(contentsOf: dir!.appendingPathComponent("\(clip).expect.json"))
        var seen = Set<String>()
        // ffprobe lists streams once per program and again at the end
        let streams = try JSONDecoder().decode(Expected.self, from: json).streams.filter { seen.insert($0.id).inserted }
        return (ts, streams)
    }
}

/// Runs every audio/video stream of a clip through the parsers
struct ClipResult {
    var fields: [UInt16: Int] = [:]        // H.264 access units (pictures)
    var frames: [UInt16: Int] = [:]        // decodable samples after field pairing
    var interlaced: [UInt16: Bool] = [:]
    var syncPoints: [UInt16: Int] = [:]
    var audio: [UInt16: Int] = [:]
    var audioConfig: [UInt16: AudioSpecificConfig] = [:]
    var framing: [UInt16: AACStreamParser.Framing] = [:]
    var monotonicVideoDTS: [UInt16: Bool] = [:]
    var stats = DemuxStats()
}

func run(_ ts: Data, streams: [Fixtures.Expected.Stream], dropEvery: Int? = nil) -> ClipResult {
    var video: [UInt16: H264Assembler] = [:]
    var audio: [UInt16: AACStreamParser] = [:]
    var lastDTS: [UInt16: Int64] = [:]
    var result = ClipResult()
    for s in streams {
        switch s.codec_name {
        case "h264": video[s.pid] = H264Assembler(); result.monotonicVideoDTS[s.pid] = true
        case "aac_latm", "aac": audio[s.pid] = AACStreamParser()
        default: break
        }
    }
    var demux = TSDemuxer(pids: Array(video.keys) + Array(audio.keys))

    func handle(_ e: DemuxEvent) {
        guard case .pes(let pes) = e else { return }
        if video[pes.pid] != nil {
            for f in video[pes.pid]!.feed(pes) {
                result.frames[pes.pid, default: 0] += 1
                result.interlaced[pes.pid] = f.interlaced
                if f.isSyncPoint { result.syncPoints[pes.pid, default: 0] += 1 }
                if let d = f.dts {
                    if let last = lastDTS[pes.pid], d <= last { result.monotonicVideoDTS[pes.pid] = false }
                    lastDTS[pes.pid] = d
                }
            }
        } else if audio[pes.pid] != nil {
            let frames = audio[pes.pid]!.feed(pes)
            result.audio[pes.pid, default: 0] += frames.count
            if let c = frames.last?.config { result.audioConfig[pes.pid] = c }
        }
    }

    ts.withUnsafeBytes { raw in
        var off = 0
        var n = 0
        while off + tsPacketSize <= raw.count {
            n += 1
            if let k = dropEvery, n % k == 0 { off += tsPacketSize; continue }
            demux.feed(UnsafeRawBufferPointer(rebasing: raw[off..<off + tsPacketSize]), emit: handle)
            off += tsPacketSize
        }
    }
    demux.flush(emit: handle)
    for (pid, a) in video { result.fields[pid] = a.accessUnits }
    for (pid, a) in audio { result.framing[pid] = a.framing }
    result.stats = demux.stats
    return result
}

@Suite struct Bits {
    @Test func expGolomb() throws {
        // 1 | 010 | 011 | 00100 → ue: 0, 1, 2, 3
        var r = BitReader([0b1010_0110, 0b0100_0000])
        #expect(try r.ue() == 0)
        #expect(try r.ue() == 1)
        #expect(try r.ue() == 2)
        #expect(try r.ue() == 3)
        var s = BitReader([0b0100_1100])  // se: +1, -1
        #expect(try s.se() == 1)
        #expect(try s.se() == -1)
    }

    @Test func emulationPrevention() {
        #expect(unescapeRBSP([0, 0, 3, 1, 0, 0, 3, 0, 0, 3]) == [0, 0, 1, 0, 0, 0, 0])
    }

    @Test func timestampUnwrap() {
        var u = TimestampUnwrapper()
        let near = UInt64(1 << 33) - 1000
        #expect(u.unwrap(near) == Int64(near))
        #expect(u.unwrap(500) == Int64(1 << 33) + 500)  // wrapped forward
        #expect(u.unwrap(near) == Int64(near))           // small step back across the wrap
    }

    @Test func annexBSplit() {
        let nals = splitAnnexB([0, 0, 0, 1, 0x09, 0xf0, 0, 0, 1, 0x67, 0x64, 0, 0, 0, 1, 0x68, 0xee])
        #expect(nals.map(\.type) == [9, 7, 8])
        #expect(nals[1].bytes == [0x67, 0x64])
    }
}

@Suite struct AudioConfigs {
    @Test func isdbtLATMConfig() throws {
        // StreamMuxConfig ASC seen on Mega 9.1: AAC-LC, 24 kHz, stereo
        let c = try AudioSpecificConfig.parse([0x13, 0x10])
        #expect(c.objectType == 2 && c.sampleRate == 24000 && c.channelConfig == 2 && !c.sbr)
        let he = c.withImplicitSBR
        #expect(he.sbr && he.outputSampleRate == 48000)
        let back = try AudioSpecificConfig.parse(he.serialize())
        #expect(back.objectType == 5 && back.coreObjectType == 2)
        #expect(back.sampleRate == 24000 && back.outputSampleRate == 48000 && back.channelConfig == 2)
    }

    @Test func lcRoundTrip() throws {
        let c = AudioSpecificConfig(objectType: 2, sampleRate: 48000, channelConfig: 2)
        #expect(c.serialize() == [0x11, 0x90])
        #expect(try AudioSpecificConfig.parse(c.serialize()) == c)
    }

    @Test func backwardCompatibleSBRSignal() throws {
        // AAC-LC 24 kHz stereo + sync extension 0x2b7 → SBR at 48 kHz
        var w = BitWriter()
        w.write(2, bits: 5); w.write(6, bits: 4); w.write(2, bits: 4); w.write(0, bits: 3)
        w.write(0x2b7, bits: 11); w.write(5, bits: 5); w.write(1, bits: 1); w.write(3, bits: 4)
        let c = try AudioSpecificConfig.parse(w.bytes)
        #expect(c.sbr && c.outputSampleRate == 48000 && c.objectType == 2)
    }
}

@Suite(.enabled(if: Fixtures.available, "set MANZANA_FIXTURES (scripts/make-fixtures.sh)"))
struct RecordedStreams {
    @Test(arguments: Fixtures.clips)
    func matchesFFprobe(clip: String) throws {
        let (ts, expected) = try Fixtures.load(clip)
        let r = run(ts, streams: expected)
        #expect(r.stats.continuityErrors >= 0)
        for s in expected {
            guard let packets = s.nb_read_packets.flatMap(Int.init) else { continue }
            switch s.codec_name {
            case "h264":
                // ffprobe's packets include pictures before the first SPS/PPS, which
                // can't be decoded; its decoded frames (×2 for PAFF fields) are the floor
                let got = r.fields[s.pid] ?? 0
                let decoded = s.nb_read_frames.flatMap(Int.init) ?? 0
                let pictures = packets > decoded * 3 / 2 ? decoded * 2 : decoded
                #expect(got >= pictures - 4 && got <= packets + 2,
                        "video \(s.id): \(got) pictures, ffprobe \(pictures) decodable of \(packets)")
                #expect(r.monotonicVideoDTS[s.pid] == true, "video \(s.id): DTS went backwards")
                #expect((r.syncPoints[s.pid] ?? 0) > 0, "video \(s.id): no IDR or recovery point")
            case "aac_latm", "aac":
                // LATM frames before the first StreamMuxConfig (sent every ~10 frames) and
                // ADTS frames split by a continuity error are dropped on purpose
                let got = r.audio[s.pid] ?? 0
                #expect(got <= packets && packets - got <= 12,
                        "audio \(s.id) \(s.codec_name!): \(got) frames, ffprobe \(packets)")
                // detected from the data, whatever the PMT claims (Mega 9.2 mislabels ADTS as LATM)
                #expect(r.framing[s.pid] == (s.codec_name == "aac_latm" ? .loas : .adts))
            default:
                break
            }
        }
    }

    @Test func megaFieldPairing() throws {
        let (ts, expected) = try Fixtures.load("rf27-5min-20s")
        let r = run(ts, streams: expected)
        // 9.1 is PAFF: every picture a field, so frames ≈ fields / 2
        let fields = try #require(r.fields[0x66])
        let frames = try #require(r.frames[0x66])
        #expect(r.interlaced[0x66] == true)
        #expect(abs(frames * 2 - fields) <= 2)
        // one-seg 9.31 is progressive
        #expect(r.interlaced[0x401] == false)
        #expect(r.frames[0x401] == r.fields[0x401])
        // HE-AAC via implicit SBR on the LATM streams
        let c = try #require(r.audioConfig[0x67])
        #expect(c.objectType == 2 && c.sampleRate == 24000 && c.withImplicitSBR.outputSampleRate == 48000)
    }

    @Test func survivesPacketLoss() throws {
        let (ts, expected) = try Fixtures.load("rf27-5min-20s")
        let clean = run(ts, streams: expected)
        let lossy = run(ts, streams: expected, dropEvery: 97)
        #expect(lossy.stats.continuityErrors > 100)
        // fewer, but still plenty of, parsed units; nothing crashes
        #expect((lossy.fields[0x66] ?? 0) > (clean.fields[0x66] ?? 0) / 2)
        #expect((lossy.audio[0x67] ?? 0) > 0)
    }
}
