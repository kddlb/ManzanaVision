// SPDX-License-Identifier: GPL-2.0-only
// mzvtool live: plays a saved channel from the STK8096GP in a window.
import AppKit
import Foundation
import ManzanaPlayback
import ManzanaTuner
import ManzanaTV

/// LiveSession behind the player's PlaySource interface, printing its status
final class LiveSource: PlaySource, @unchecked Sendable {
    let channel: Channel
    private var session: LiveSession?
    private var printer: Task<Void, Never>?

    init(channel: Channel) {
        self.channel = channel
    }

    var title: String { "\(channel.virtual) \(channel.name) · RF \(channel.rf) (live)" }

    var status: String {
        guard let session else { return "" }
        var line = "tuner: \(describe(session.status))"
        if let s = session.signal {
            let layers = (0..<3).map { s.layerLocked($0) ? "✓" : "·" }.joined()
            line += String(format: "  SNR %.1f dB  level %d%%  layers %@  err %.0f/s", s.snr, s.strengthPercent,
                           layers, s.errorsPerSecond)
        }
        return line
    }

    func start(engine: PlaybackEngine) {
        let session = LiveSession(engine: engine)
        self.session = session
        printer = Task.detached { [self] in
            for await s in session.statusUpdates { print("  [status] \(describe(s))") }
        }
        session.play(channel)
    }

    func stop() {
        session?.stop()
        printer?.cancel()
    }

    private func describe(_ s: LiveStatus) -> String {
        switch s {
        case .noTuner: "no tuner plugged in"
        case .tunerBusy: "tuner in use by another program"
        case .firmwareProblem(let why): "firmware problem: \(why)"
        case .starting: "starting the tuner"
        case .tuning(let c): "tuning \(c.virtual) (RF \(c.rf))"
        case .noSignal(let c): "no signal on RF \(c.rf)"
        case .signalLost(let c): "signal lost on RF \(c.rf), re-tuning"
        case .playing(let c, let r): "playing \(c.virtual), reception \(r)"
        case .disconnected: "tuner unplugged; waiting for it"
        case .stopped: "stopped"
        }
    }
}

@MainActor
func live(_ args: [String]) {
    var query: String?
    var seconds: Double?
    var snapshots: URL?
    var deinterlace = DeinterlaceMode.auto
    var mute = false
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--seconds": i += 1; seconds = Double(args[i])
        case "--snapshots": i += 1; snapshots = URL(fileURLWithPath: args[i], isDirectory: true)
        case "--deinterlace": i += 1; deinterlace = DeinterlaceMode(rawValue: args[i]) ?? .auto
        case "--mute": mute = true
        default: query = args[i]
        }
        i += 1
    }
    let channels = (try? ChannelStore.load()) ?? []
    guard let query,
          let channel = channels.first(where: { $0.virtual == query })
            ?? channels.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) else {
        FileHandle.standardError.write("usage: mzvtool live <9.1|name> [--seconds N] [--snapshots DIR] [--deinterlace MODE] [--mute]\nsaved channels: \(channels.map(\.virtual).joined(separator: " "))\n".data(using: .utf8)!)
        exit(2)
    }
    if let snapshots { try? FileManager.default.createDirectory(at: snapshots, withIntermediateDirectories: true) }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let player = Player(source: LiveSource(channel: channel), seconds: seconds, snapshotDir: snapshots,
                        deinterlace: deinterlace, mute: mute)
    app.delegate = player
    app.run()
}
