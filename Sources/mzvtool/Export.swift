// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaPlayback

/// mzvtool export FILE.ts OUT.mp4 [--service 9.1|0x2600] [--deinterlace MODE]
func export(_ args: [String]) {
    var paths: [String] = []
    var what = "1"
    var deinterlace = DeinterlaceMode.auto
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--service": i += 1; what = args[i]
        case "--deinterlace": i += 1; deinterlace = DeinterlaceMode(rawValue: args[i]) ?? .auto
        default: paths.append(args[i])
        }
        i += 1
    }
    guard paths.count == 2, let data = try? Data(contentsOf: URL(fileURLWithPath: paths[0]), options: .alwaysMapped) else {
        FileHandle.standardError.write("usage: mzvtool export FILE.ts OUT.mp4 [--service 9.1|0x2600] [--deinterlace auto|yadif|bob|decoder|off]\n".data(using: .utf8)!)
        exit(2)
    }
    let svc = services(in: data)
    guard let sid = UInt16(what.hasPrefix("0x") ? String(what.dropFirst(2)) : "", radix: 16)
        ?? svc.first(where: { $0.virtual == what })?.sid ?? svc.first?.sid
        ?? Exporter.firstServiceID(in: URL(fileURLWithPath: paths[0])) else {
        FileHandle.standardError.write("no such service; have \(svc.map(\.virtual))\n".data(using: .utf8)!)
        exit(1)
    }
    let exporter = Exporter(source: URL(fileURLWithPath: paths[0]), serviceID: sid,
                            destination: URL(fileURLWithPath: paths[1]), deinterlace: deinterlace)
    let started = Date()
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Result<Exporter.Summary, Error>?
    Task.detached {
        do {
            outcome = .success(try await exporter.run { p in
                FileHandle.standardError.write(String(format: "\r%3.0f%%", p * 100).data(using: .utf8)!)
            })
        } catch {
            outcome = .failure(error)
        }
        done.signal()
    }
    done.wait()
    FileHandle.standardError.write("\n".data(using: .utf8)!)
    switch outcome! {
    case .success(let s):
        let took = Date().timeIntervalSince(started)
        print(String(format: "%@: %.1f s of video in %.1f s (%.1f×), %d frames, %d audio buffers, %d skipped, %d decode errors, %.1f s of silence filled, %d captions",
                     paths[1], s.duration, took, s.duration / took, s.videoFrames, s.audioBuffers, s.skipped, s.decodeErrors, s.silence,
                     s.captions))
    case .failure(let e):
        FileHandle.standardError.write("export failed: \(e.localizedDescription)\n".data(using: .utf8)!)
        exit(1)
    }
}
