// SPDX-License-Identifier: GPL-2.0-only
// mzvtool: developer tool for the app's media pipeline.
//   mzvtool version
//   mzvtool probe FILE.ts      per-service stream analysis of a recording
//   mzvtool play FILE.ts ...   plays a service in a window, paced like live
import Foundation
import ManzanaCore
import ManzanaStream

struct Service {
    var virtual: String
    var name: String
    var sid: UInt16
}

func cString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

func services(in data: Data) -> [Service] {
    var mux = mzv_mux()
    data.withUnsafeBytes { raw in
        mzv_mux_from_packets(raw.bindMemory(to: UInt8.self).baseAddress, min(data.count, 16 << 20) / 188, 0, &mux)
    }
    return withUnsafeBytes(of: mux.services) { raw in
        raw.bindMemory(to: mzv_service.self).prefix(Int(mux.nservices)).filter(\.listed).map {
            Service(virtual: "\($0.major).\($0.minor)", name: cString($0.name), sid: $0.service_id)
        }
    }
}

/// The service's PMT, via the core's program filter
func program(of sid: UInt16, in data: Data) -> mzv_program? {
    let f = mzv_filter_new(sid, false)
    defer { mzv_filter_free(f) }
    let n = min(data.count, 16 << 20) / 188
    var out = [UInt8](repeating: 0, count: n * 188)
    data.withUnsafeBytes { raw in
        _ = mzv_filter_feed(f, raw.bindMemory(to: UInt8.self).baseAddress, n, &out)
    }
    var prog = mzv_program()
    return mzv_filter_program(f, &prog) ? prog : nil
}

func streamTypeName(_ t: UInt8) -> String {
    switch t {
    case 0x1b: "H.264"
    case 0x0f: "AAC (ADTS)"
    case 0x11: "AAC (LATM)"
    case 0x06: "private (captions?)"
    case 0x0d: "DSM-CC"
    default: String(format: "0x%02x", t)
    }
}

func probe(_ path: String) throws {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let seconds = Double(data.count) * 8 / 17.3e6
    print("\(path): \(data.count / 188) packets (~\(Int(seconds)) s of full mux)")

    for svc in services(in: data) {
        guard let prog = program(of: svc.sid, in: data) else {
            print("\n\(svc.virtual) \(svc.name): no PMT")
            continue
        }
        let es = withUnsafeBytes(of: prog.es) { raw in Array(raw.bindMemory(to: mzv_es.self).prefix(Int(prog.nes))) }
        print("\n\(svc.virtual) \(svc.name)  sid 0x\(String(svc.sid, radix: 16))  PMT 0x\(String(prog.pmt_pid, radix: 16))  PCR 0x\(String(prog.pcr_pid, radix: 16))")

        var demux = TSDemuxer(pids: es.map(\.pid))
        var video: [UInt16: H264Assembler] = [:]
        var audio: [UInt16: AACStreamParser] = [:]
        var frames: [UInt16: [H264Frame]] = [:]
        var audioFrames: [UInt16: [AACFrame]] = [:]
        for e in es {
            switch e.stream_type {
            case 0x1b: video[e.pid] = H264Assembler()
            case 0x11, 0x0f: audio[e.pid] = AACStreamParser()
            default: break
            }
        }
        func handle(_ ev: DemuxEvent) {
            guard case .pes(let pes) = ev else { return }
            if video[pes.pid] != nil {
                // keep only what the report needs, not the NAL payloads
                frames[pes.pid, default: []] += video[pes.pid]!.feed(pes).map {
                    var f = $0
                    f.nalus = []
                    return f
                }
            } else if audio[pes.pid] != nil {
                audioFrames[pes.pid, default: []] += audio[pes.pid]!.feed(pes)
            }
        }
        data.withUnsafeBytes { demux.feed($0, emit: handle) }
        demux.flush(emit: handle)

        for e in es {
            var line = "  0x\(String(e.pid, radix: 16)) \(streamTypeName(e.stream_type))"
            if let a = video[e.pid] {
                let fs = frames[e.pid] ?? []
                let sync = fs.enumerated().filter(\.element.isSyncPoint).map(\.offset)
                let gaps = zip(sync.dropFirst(), sync).map { $0 - $1 }
                if let f = fs.first {
                    let sps = f.sps
                    let coding = sps.frameMbsOnly ? "progressive"
                        : (fs.contains(where: \.fieldPair) ? "interlaced, field pictures (PAFF)"
                           : (sps.mbAdaptiveFrameField ? "interlaced, MBAFF" : "interlaced, frame pictures"))
                    let fps = sps.timeScale > 0 ? String(format: " %.2f Hz timing", Double(sps.timeScale) / Double(sps.numUnitsInTick)) : ""
                    line += "  \(sps.width)x\(sps.height) profile \(sps.profileIDC) level \(sps.levelIDC), \(coding)\(fps)"
                    line += "\n      \(a.accessUnits) pictures → \(fs.count) samples; \(fs.filter(\.damaged).count) damaged; "
                    line += "\(a.unpairedFields) unpaired fields; parse errors \(a.parseErrors)"
                    line += "\n      sync points: \(sync.count) (\(fs.filter(\.hasIDR).count) IDR, the rest recovery points)"
                    if !gaps.isEmpty {
                        line += ", every \(gaps.min()!)–\(gaps.max()!) samples"
                    }
                    line += "; TFF \(fs.filter { $0.fieldPair && $0.topFieldFirst }.count)/\(fs.filter(\.fieldPair).count)"
                } else {
                    line += "  no decodable pictures (\(a.accessUnits) pictures, \(a.parseErrors) parse errors)"
                }
            } else if let af = audioFrames[e.pid] {
                if let c = af.first?.config {
                    let he = c.withImplicitSBR
                    let kind = he.ps ? "HE-AACv2" : (he.sbr ? "HE-AAC" : "AAC-LC")
                    line += "  \(kind), core AOT \(c.coreObjectType) @ \(c.sampleRate) Hz → \(he.outputSampleRate) Hz, \(c.channels) ch"
                    line += c.sbr ? " (explicit SBR)" : (he.sbr ? " (implicit SBR)" : "")
                    line += "\n      \(af.count) frames, \(af.filter(\.damaged).count) damaged"
                    let declared = e.stream_type == 0x11 ? AACStreamParser.Framing.loas : .adts
                    if let p = audio[e.pid] {
                        if p.framing != declared { line += "; PMT says \(declared), data is \(p.framing)" }
                        if let l = p.latmParser {
                            line += "; LATM: \(l.configs) config(s), \(l.skippedWithoutConfig) frames before the first, \(l.errors) errors"
                        }
                        if let a = p.adtsParser { line += "; ADTS sync losses \(a.syncLosses)" }
                    }
                } else {
                    line += "  no frames"
                }
            }
            print(line)
        }
        let st = demux.stats
        print("  demux: \(st.continuityErrors) continuity errors, \(st.transportErrors) TEI, \(st.droppedPES) dropped PES")
    }
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "version":
    print("ManzanaCore \(String(cString: mzv_version()))")
case "play":
    MainActor.assumeIsolated { play(Array(args.dropFirst(2))) }
case "probe" where args.count > 2:
    do { try probe(args[2]) } catch {
        FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        exit(1)
    }
default:
    FileHandle.standardError.write("usage: mzvtool version | probe FILE.ts | play FILE.ts [--service 9.1] [--seconds N] [--snapshots DIR]\n".data(using: .utf8)!)
    exit(2)
}
