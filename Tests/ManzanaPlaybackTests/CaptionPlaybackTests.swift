// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import Foundation
@testable import ManzanaPlayback
import ManzanaStream
import Testing

@MainActor
@Suite(.enabled(if: Fixtures.available, "set MANZANA_FIXTURES (runs in real time, ~10 s)"))
struct CaptionPlayback {
    /// Mega stamps caption PTS about 4 hours ahead of its video; the engine
    /// must still put them on screen, with the pictures they came with
    @Test func megaCaptionsReachTheScreen() async throws {
        let layer = AVSampleBufferDisplayLayer()
        let engine = PlaybackEngine(videoRenderer: layer.sampleBufferRenderer)
        engine.audioRenderer.isMuted = true
        let source = FileSource(url: Fixtures.dir!.appendingPathComponent("rf27-5min-20s.ts"), serviceID: 0x2600)
        source.start(packets: { engine.feed($0, epoch: $1) }, program: { engine.setProgram($0) })
        defer {
            source.stop()
            engine.stop()
            withExtendedLifetime(layer) {}
        }
        let shown = Task { () -> CaptionPage? in
            for await page in engine.captions where !page.isEmpty { return page }
            return nil
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            shown.cancel()
        }
        let page = await shown.value
        timeout.cancel()
        let stats = engine.currentStats()
        #expect(stats.hasCaptions)
        #expect(stats.captionLanguage == "spa")
        #expect(stats.captionsRetimed > 0)
        let text = try #require(page?.text, "no caption was presented (\(stats.captionScreens) decoded)")
        #expect(!text.isEmpty)
    }
}
