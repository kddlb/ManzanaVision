// SPDX-License-Identifier: GPL-2.0-only
// mzvtool play: plays one service of a recording in a window, as if live.
import AppKit
@preconcurrency import AVFoundation
import CoreImage
import ManzanaPlayback
import UniformTypeIdentifiers

/// Something that feeds the engine: a recording or the live tuner
protocol PlaySource: AnyObject, Sendable {
    var title: String { get }
    func start(engine: PlaybackEngine)
    func stop()
    /// Extra status for the per-second line
    var status: String { get }
}

final class RecordingSource: PlaySource, @unchecked Sendable {
    let source: FileSource
    let title: String
    init(url: URL, serviceID: UInt16, faults: FaultPlan) {
        source = FileSource(url: url, serviceID: serviceID)
        source.faults = faults
        title = "\(url.lastPathComponent) · service 0x\(String(serviceID, radix: 16))"
    }
    func start(engine: PlaybackEngine) {
        source.start(packets: { data, epoch in engine.feed(data, epoch: epoch) },
                     program: { streams in engine.setProgram(streams) })
    }
    func stop() { source.stop() }
    var status: String { "" }
}

@MainActor
final class Player: NSObject, NSApplicationDelegate {
    let playSource: PlaySource
    let seconds: Double?
    let snapshotDir: URL?
    let deinterlace: DeinterlaceMode
    let mute: Bool
    let layer = AVSampleBufferDisplayLayer()
    var engine: PlaybackEngine!
    var window: NSWindow!
    var started = Date()
    var snapshots = 0

    init(source: PlaySource, seconds: Double?, snapshotDir: URL?, deinterlace: DeinterlaceMode, mute: Bool) {
        playSource = source
        self.deinterlace = deinterlace
        self.mute = mute
        self.seconds = seconds
        self.snapshotDir = snapshotDir
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = playSource.title
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
        engine.audioRenderer.isMuted = mute
        playSource.start(engine: engine)

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
    }

    var debugVideo: (() -> String)?

    func tick() {
        let t = Date().timeIntervalSince(started)
        let s = engine.currentStats()
        let size = s.videoSize == .zero ? "-" : "\(Int(s.videoSize.width))x\(Int(s.videoSize.height))\(s.interlaced ? "i" : "p")"
        print(String(format: "%5.1fs %@ epoch %u rate %.3f  decoded %d → out %d (%@ %.2f ms, errs %d)  %@  buf v %.2fs a %.2fs  %@  cc %d  conceal %d  reanchor %d  restarts %d stalls %d jumps %d rebuf %d rfail %d dreset %d",
                     t, s.state.rawValue, s.epoch, s.rate, s.decodedFrames, s.outputFrames, s.deinterlace.rawValue,
                     s.deinterlaceGPUms, s.decodeErrors, size, s.videoBuffer, s.audioBuffer, s.audioDescription,
                     s.continuityErrors, s.audioConcealed, s.audioReanchors, s.restarts, s.stalls, s.ptsJumps, s.rebuffers,
                     s.rendererFailures, s.decoderResets))
        print(String(format: "  output: %d backwards, %d late, min lead %.3fs", s.outputBackwards, s.outputLate, s.outputMinLead))
        if !playSource.status.isEmpty { print("  " + playSource.status) }
        fflush(stdout)
        if let dir = snapshotDir, s.state == .playing, Int(t) % 3 == 0 { snapshot(to: dir) }
        let renderer = layer.sampleBufferRenderer
        Task { @MainActor in
            if let m = await renderer.videoPerformanceMetrics {
                print("  renderer: \(m.totalNumberOfFrames) frames, \(m.numberOfDroppedFrames) dropped, \(m.numberOfCorruptedFrames) corrupted")
            }
        }
        if let seconds, t >= seconds {
            playSource.stop()
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
    var faults = FaultPlan()
    var mute = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--service": i += 1; what = args[i]
        case "--seconds": i += 1; seconds = Double(args[i])
        case "--snapshots": i += 1; snapshots = URL(fileURLWithPath: args[i], isDirectory: true)
        case "--deinterlace": i += 1; deinterlace = DeinterlaceMode(rawValue: args[i]) ?? .auto
        case "--faults": i += 1; faults = FaultPlan(parsing: args[i]) ?? faults
        case "--mute": mute = true
        default: path = args[i]
        }
        i += 1
    }
    guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
        FileHandle.standardError.write("usage: mzvtool play FILE.ts [--service 9.1|0x2600] [--seconds N] [--snapshots DIR] [--deinterlace auto|yadif|bob|decoder|off]\n  [--mute] [--faults drop=P,tei=P,corrupt=P,gap=EVERY:LEN,jump=EVERY:LEN,clock=RATIO,seed=N]\n".data(using: .utf8)!)
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
    let source = RecordingSource(url: URL(fileURLWithPath: path), serviceID: sid, faults: faults)
    let player = Player(source: source, seconds: seconds, snapshotDir: snapshots, deinterlace: deinterlace, mute: mute)
    app.delegate = player
    app.run()
}
