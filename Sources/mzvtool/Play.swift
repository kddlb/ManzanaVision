// SPDX-License-Identifier: GPL-2.0-only
// mzvtool play: plays one service of a recording in a window, as if live.
import AppKit
@preconcurrency import AVFoundation
import CoreImage
import ManzanaPlayback
import UniformTypeIdentifiers

@MainActor
final class Player: NSObject, NSApplicationDelegate {
    let url: URL
    let serviceID: UInt16
    let seconds: Double?
    let snapshotDir: URL?
    let deinterlace: DeinterlaceMode
    let layer = AVSampleBufferDisplayLayer()
    var engine: PlaybackEngine!
    var source: FileSource!
    var window: NSWindow!
    var started = Date()
    var snapshots = 0

    init(url: URL, serviceID: UInt16, seconds: Double?, snapshotDir: URL?, deinterlace: DeinterlaceMode) {
        self.deinterlace = deinterlace
        self.url = url
        self.serviceID = serviceID
        self.seconds = seconds
        self.snapshotDir = snapshotDir
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "\(url.lastPathComponent) · service 0x\(String(serviceID, radix: 16))"
        let view = NSView()
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.black.cgColor
        layer.videoGravity = .resizeAspect
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(layer)
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        engine = PlaybackEngine(videoRenderer: layer.sampleBufferRenderer, deinterlace: deinterlace)
        source = FileSource(url: url, serviceID: serviceID)
        let engine = self.engine!
        source.start(packets: { data, epoch in engine.feed(data, epoch: epoch) },
                     program: { streams in engine.setProgram(streams) })

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    var debugVideo: (() -> String)?

    func tick() {
        let t = Date().timeIntervalSince(started)
        let s = engine.currentStats()
        let size = s.videoSize == .zero ? "-" : "\(Int(s.videoSize.width))x\(Int(s.videoSize.height))\(s.interlaced ? "i" : "p")"
        print(String(format: "%5.1fs %@ epoch %u  decoded %d → out %d (%@ %.2f ms, errs %d)  video %d (%@, buf %.2fs)  audio %d (%@, buf %.2fs)  skipped %d  cc %d  errs %d  conceal %d  reanchor %d  restarts %d  vr %@",
                     t, s.state.rawValue, s.epoch, s.decodedFrames, s.outputFrames, s.deinterlace.rawValue,
                     s.deinterlaceGPUms, s.decodeErrors, s.videoFrames, size, s.videoBuffer, s.audioFrames,
                     s.audioDescription, s.audioBuffer, s.videoSkippedBeforeSync, s.continuityErrors,
                     s.videoErrors, s.audioConcealed, s.audioReanchors, s.restarts,
                     layer.sampleBufferRenderer.status == .failed ? "FAILED \(layer.sampleBufferRenderer.error?.localizedDescription ?? "")" : "ok"))
        print(String(format: "  output: %d backwards, %d late, min lead %.3fs", s.outputBackwards, s.outputLate, s.outputMinLead))
        fflush(stdout)
        if let dir = snapshotDir, s.state == .playing, Int(t) % 3 == 0 { snapshot(to: dir) }
        let renderer = layer.sampleBufferRenderer
        Task { @MainActor in
            if let m = await renderer.videoPerformanceMetrics {
                print("  renderer: \(m.totalNumberOfFrames) frames, \(m.numberOfDroppedFrames) dropped, \(m.numberOfCorruptedFrames) corrupted")
            }
        }
        if let seconds, t >= seconds {
            source.stop()
            engine.stop()
            NSApp.terminate(nil)
        }
    }

    func snapshot(to dir: URL) {
        // not bridged to Swift; fine to reach through the runtime in a dev tool
        let sel = NSSelectorFromString("copyDisplayedPixelBuffer")
        guard let obj = layer.sampleBufferRenderer.perform(sel)?.takeRetainedValue() else {
            print("  (no displayed frame)")
            return
        }
        let pb = unsafeBitCast(obj, to: CVPixelBuffer.self)
        let image = CIImage(cvPixelBuffer: pb)
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return }
        snapshots += 1
        let file = dir.appendingPathComponent(String(format: "snap-%02d.png", snapshots))
        if let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
            print("  snapshot \(file.path) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        }
    }
}

@MainActor
func play(_ args: [String]) {
    var path: String?
    var what = "1"
    var seconds: Double?
    var snapshots: URL?
    var deinterlace = DeinterlaceMode.auto
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--service": i += 1; what = args[i]
        case "--seconds": i += 1; seconds = Double(args[i])
        case "--snapshots": i += 1; snapshots = URL(fileURLWithPath: args[i], isDirectory: true)
        case "--deinterlace": i += 1; deinterlace = DeinterlaceMode(rawValue: args[i]) ?? .auto
        default: path = args[i]
        }
        i += 1
    }
    guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
        FileHandle.standardError.write("usage: mzvtool play FILE.ts [--service 9.1|0x2600] [--seconds N] [--snapshots DIR] [--deinterlace auto|yadif|bob|decoder|off]\n".data(using: .utf8)!)
        exit(2)
    }
    let svc = services(in: data)
    let sid: UInt16? = UInt16(what.hasPrefix("0x") ? String(what.dropFirst(2)) : "", radix: 16)
        ?? svc.first(where: { $0.virtual == what })?.sid ?? svc.first?.sid
    guard let sid else {
        FileHandle.standardError.write("no such service; have \(svc.map(\.virtual))\n".data(using: .utf8)!)
        exit(1)
    }
    if let snapshots { try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let player = Player(url: URL(fileURLWithPath: path), serviceID: sid, seconds: seconds, snapshotDir: snapshots,
                        deinterlace: deinterlace)
    app.delegate = player
    app.run()
}
