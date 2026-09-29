// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaCore
import ManzanaPlayback
import ManzanaStream

/// mzvtool captions FILE.ts [--service 9.1|0x2600] [--layout]
/// Prints each caption screen with its time from the first one; --layout adds
/// the position, size and colours of every line.
func captions(_ args: [String]) {
    var paths: [String] = []
    var what = "1"
    var layout = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--service": i += 1; what = args[i]
        case "--layout": layout = true
        default: paths.append(args[i])
        }
        i += 1
    }
    guard paths.count == 1, let data = try? Data(contentsOf: URL(fileURLWithPath: paths[0]), options: .alwaysMapped) else {
        FileHandle.standardError.write("usage: mzvtool captions FILE.ts [--service 9.1|0x2600] [--layout]\n".data(using: .utf8)!)
        exit(2)
    }
    let svc = services(in: data)
    guard let sid = UInt16(what.hasPrefix("0x") ? String(what.dropFirst(2)) : "", radix: 16)
        ?? svc.first(where: { $0.virtual == what })?.sid ?? svc.first?.sid,
        let prog = program(of: sid, in: data) else {
        FileHandle.standardError.write("no such service; have \(svc.map(\.virtual))\n".data(using: .utf8)!)
        exit(1)
    }
    let streams = withUnsafeBytes(of: prog.es) { raw in
        raw.bindMemory(to: mzv_es.self).prefix(Int(prog.nes)).map(ProgramStream.init)
    }
    guard let pid = streams.first(where: \.isCaption)?.pid else {
        print("service 0x\(String(sid, radix: 16)) has no caption stream")
        return
    }

    var demux = TSDemuxer(pids: [pid])
    var decoder = ARIBCaptionDecoder()
    var unwrap = TimestampUnwrapper()
    var first: Int64?
    var screens = 0
    func handle(_ ev: DemuxEvent) {
        guard case .pes(let pes) = ev, let page = decoder.decode(pes.payload) else { return }
        screens += 1
        let t = pes.pts.map { unwrap.unwrap($0) } ?? 0
        if first == nil { first = t }
        let at = String(format: "%8.3f", Double(t - first!) / 90000)
        if page.isEmpty {
            print("\(at)  (clear)")
            return
        }
        let text = page.text.split(separator: "\n", omittingEmptySubsequences: false)
        print("\(at)  " + text.joined(separator: "\n          "))
        if layout {
            for l in page.lines {
                let runs = l.runs.map { r in
                    "\"\(r.text)\" \(r.fontSize)px fg \(r.foreground.hex) bg \(r.background.hex)"
                }
                print("          @\(l.x),\(l.y) h\(l.height) on \(page.width)x\(page.height): " + runs.joined(separator: ", "))
            }
        }
    }
    data.withUnsafeBytes { demux.feed($0, emit: handle) }
    demux.flush(emit: handle)
    print("\(screens) caption screens, language \(decoder.page.language ?? "?"), \(decoder.encoding)")
}

extension CaptionColor {
    var hex: String { String(format: "#%02x%02x%02x%02x", red, green, blue, alpha) }
}
