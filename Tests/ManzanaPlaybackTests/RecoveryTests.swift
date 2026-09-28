// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import Foundation
@testable import ManzanaPlayback
import Testing

/// Plays a fixture through the real engine (off-screen layer, muted) with
/// injected faults, sampling stats every 100 ms
@MainActor
func runScenario(_ spec: String, seconds: Double, clip: String = "rf27-5min-20s",
                 service: UInt16 = 0x2600) async throws -> [(t: Double, s: PlaybackStats)] {
    var url = Fixtures.dir!.appendingPathComponent("\(clip).ts")
    if !FileManager.default.fileExists(atPath: url.path) {
        url = Fixtures.dir!.deletingLastPathComponent().appendingPathComponent("\(clip).ts")  // full captures
    }
    // a renderer needs a display target; an off-screen layer is enough
    let layer = AVSampleBufferDisplayLayer()
    let engine = PlaybackEngine(videoRenderer: layer.sampleBufferRenderer)
    engine.audioRenderer.isMuted = true
    let source = FileSource(url: url, serviceID: service)
    source.faults = try #require(FaultPlan(parsing: spec))
    source.start(packets: { engine.feed($0, epoch: $1) }, program: { engine.setProgram($0) })
    defer {
        source.stop()
        engine.stop()
        withExtendedLifetime(layer) {}
    }
    var samples: [(Double, PlaybackStats)] = []
    let start = Date()
    while Date().timeIntervalSince(start) < seconds {
        try await Task.sleep(for: .milliseconds(100))
        samples.append((Date().timeIntervalSince(start), engine.currentStats()))
    }
    return samples
}

/// Longest stretch without playback after the first start
func longestOutage(_ samples: [(t: Double, s: PlaybackStats)]) -> Double {
    guard let first = samples.firstIndex(where: { $0.s.state == .playing }) else { return .infinity }
    var longest = 0.0, since: Double?
    for (t, s) in samples[first...] {
        if s.state == .playing {
            if let a = since { longest = max(longest, t - a) }
            since = nil
        } else if since == nil {
            since = t
        }
    }
    if let a = since, let last = samples.last { longest = max(longest, last.t - a) }
    return longest
}

@MainActor
@Suite(.serialized, .enabled(if: Fixtures.available && ProcessInfo.processInfo.environment["MANZANA_FAULT_TESTS"] != nil,
                             "set MANZANA_FIXTURES and MANZANA_FAULT_TESTS=1 (runs in real time, ~2 min)"))
struct Recovery {
    @Test func signalGaps() async throws {
        // 3 s without data every 6 s: freeze on the last picture, then resume
        let samples = try await runScenario("gap=6:3", seconds: 17)
        let last = samples.last!.s
        #expect(last.stalls >= 2, "stalls \(last.stalls)")
        // outage = the 3 s gap + stall detection; resuming itself must be quick
        #expect(longestOutage(samples) < 3 + 3, "outage \(longestOutage(samples)) s")
        #expect(samples.suffix(5).allSatisfy { $0.s.state == .playing })
    }

    @Test func timestampJumps() async throws {
        let samples = try await runScenario("jump=5:5", seconds: 13)
        let last = samples.last!.s
        #expect(last.ptsJumps >= 1)
        #expect(longestOutage(samples) < 3, "outage \(longestOutage(samples)) s")
        #expect(last.state == .playing)
    }

    /// New pictures in each second of playback
    func picturesPerSecond(_ samples: [(t: Double, s: PlaybackStats)]) -> [Int] {
        let playing = samples.drop { $0.s.state != .playing }
        var out: [Int] = [], t = playing.first!.t + 1
        while t < samples.last!.t {
            out.append(samples.last { $0.t <= t }!.s.outputFrames - samples.last { $0.t <= t - 1 }!.s.outputFrames)
            t += 1
        }
        return out
    }

    @Test func marginalReception() async throws {
        // 0.1% loss plus some corruption: like RF 22/33 on a bad day
        let samples = try await runScenario("drop=0.001,corrupt=0.0005,seed=5", seconds: 12)
        #expect(longestOutage(samples) == 0)
        let pps = picturesPerSecond(samples)
        #expect(pps.allSatisfy { $0 >= 30 }, "pictures per second: \(pps)")
    }

    @Test func heavyDamage() async throws {
        let samples = try await runScenario("drop=0.01,tei=0.002,corrupt=0.002,seed=3", seconds: 12)
        let last = samples.last!.s
        #expect(last.continuityErrors > 300)
        #expect(longestOutage(samples) == 0, "stopped playing under damage")
        #expect(last.rendererFailures == 0)
        // 1% loss damages nearly every 1080 field and errors propagate to the next
        // recovery point, so it gets choppy; it must never freeze
        let pps = picturesPerSecond(samples)
        #expect(pps.allSatisfy { $0 > 0 }, "pictures per second: \(pps)")
        let early = samples.first { $0.t >= 6 }!.s.outputFrames
        #expect(last.outputFrames - early > 100, "only \(last.outputFrames - early) frames in 6 s")
    }

    @Test func runawayFastClock() async throws {
        // 5% fast source: beyond drift control, so the buffer must be capped by rebuffering
        let samples = try await runScenario("clock=1.05", seconds: 40, clip: "rf27-5min")
        let maxBuffer = samples.map(\.s.audioBuffer).max()!
        #expect(maxBuffer < 4.5, "buffer grew to \(maxBuffer) s")
        #expect(samples.last!.s.state == .playing)
    }

    @Test func runawaySlowClock() async throws {
        let samples = try await runScenario("clock=0.95", seconds: 40, clip: "rf27-5min")
        let last = samples.last!.s
        #expect(last.rebuffers >= 1, "never rebuffered")
        #expect(samples.filter { $0.s.state == .playing }.map(\.s.audioBuffer).min()! > -0.5)
    }
}
