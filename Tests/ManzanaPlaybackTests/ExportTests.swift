// SPDX-License-Identifier: GPL-2.0-only
import AVFoundation
import Foundation
@testable import ManzanaPlayback
import Testing

@Suite(.enabled(if: Fixtures.available, "set MANZANA_FIXTURES"))
struct Export {
    private func export(_ clip: String, service: UInt16) async throws -> (URL, Exporter.Summary) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mzv-export-\(UUID().uuidString).mp4")
        let exporter = Exporter(source: Fixtures.dir!.appendingPathComponent("\(clip).ts"), serviceID: service, destination: out)
        let summary = try await exporter.run { _ in }
        return (out, summary)
    }

    private func tracks(_ url: URL) async throws -> (video: AVAssetTrack?, audio: AVAssetTrack?, duration: Double) {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        return (video, audio, try await asset.load(.duration).seconds)
    }

    @Test func interlacedHDBecomesHEVCAtFieldRate() async throws {
        let (url, summary) = try await export("rf27-5min-20s", service: 0x2600)  // 9.1: 1080i PAFF, HE-AAC in LATM
        defer { try? FileManager.default.removeItem(at: url) }
        let (video, audio, duration) = try await tracks(url)
        let v = try #require(video)
        #expect(try await v.load(.naturalSize) == CGSize(width: 1920, height: 1080))
        let fps = try await v.load(.nominalFrameRate)
        #expect(abs(fps - 59.94) < 0.5, "deinterlaced to field rate, got \(fps)")
        let codec = try await v.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(codec == kCMVideoCodecType_HEVC)
        #expect(audio != nil)
        #expect(abs(duration - 20.5) < 1.5, "about the clip's length, got \(duration)")
        #expect(summary.videoFrames > 1150)
    }

    @Test func captionsBecomeASubtitleTrack() async throws {
        let (url, summary) = try await export("rf27-5min-20s", service: 0x2600)  // 9.1: Spanish captions
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(summary.captions > 20)
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .subtitle).first)
        #expect(try await track.load(.languageCode) == "spa")
        #expect(try await track.load(.isEnabled) == false)
        let subtype = try await track.load(.formatDescriptions).first.map(CMFormatDescriptionGetMediaSubType)
        #expect(subtype == kCMTextFormatType_3GText)

        // the text reads back, and the track spans the movie
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        #expect(reader.startReading())
        var texts: [String] = []
        var last: CMTime = .zero
        while let sample = output.copyNextSampleBuffer() {
            last = CMSampleBufferGetPresentationTimeStamp(sample) + CMSampleBufferGetDuration(sample)
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
            guard bytes.count >= 2 else { continue }
            let n = Int(bytes[0]) << 8 | Int(bytes[1])
            texts.append(String(decoding: bytes[2..<min(bytes.count, 2 + n)], as: UTF8.self))
        }
        #expect(texts.contains { $0.contains("Ó") || $0.contains("É") })
        // a screen on show a while is split into pieces with the same text
        #expect(Set(texts.filter { !$0.isEmpty }).count >= summary.captions / 2)
        let duration = try await asset.load(.duration)
        #expect(abs((last - duration).seconds) < 1, "captions end at \(last.seconds), movie at \(duration.seconds)")
    }

    @Test func progressiveStaysAtItsRate() async throws {
        let (url, _) = try await export("rf32-5min-20s", service: 0x22)  // 14.3: 720p, AAC at 44.1 kHz
        defer { try? FileManager.default.removeItem(at: url) }
        let (video, audio, _) = try await tracks(url)
        let fps = try await #require(video).load(.nominalFrameRate)
        #expect(abs(fps - 29.97) < 0.5)
        let rate = try await #require(audio).load(.formatDescriptions).first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate }
        #expect(rate == 44100)
    }

    @Test func cancellingRemovesThePartialFile() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("mzv-export-\(UUID().uuidString).mp4")
        let exporter = Exporter(source: Fixtures.dir!.appendingPathComponent("rf27-5min-20s.ts"), serviceID: 0x2600, destination: out)
        let task = Task { try await exporter.run { _ in } }
        try await Task.sleep(for: .milliseconds(800))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: out.path))
    }

    @Test func gapsStayInSync() async throws {
        // a recording through a 6 s dropout: cut the middle out of the clip
        let ts = try #require(Fixtures.data("rf27-5min-20s"))
        let packets = ts.count / 188
        let cut = (packets * 3 / 10)..<(packets * 6 / 10)
        let gapped = ts.prefix(cut.lowerBound * 188) + ts[(cut.upperBound * 188)...]
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("mzv-gap-\(UUID().uuidString).ts")
        let out = source.deletingPathExtension().appendingPathExtension("mp4")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: out)
        }
        try Data(gapped).write(to: source)
        let summary = try await Exporter(source: source, serviceID: 0x2600, destination: out).run { _ in }
        #expect(summary.silence > 4, "the hole in the audio is filled, got \(summary.silence) s")

        let asset = AVURLAsset(url: out)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let v = try await video.load(.timeRange), a = try await audio.load(.timeRange)
        // without the fill, audio after the gap would start early and the track would be ~6 s short
        #expect(abs(a.end.seconds - v.end.seconds) < 0.6, "audio ends at \(a.end.seconds), video at \(v.end.seconds)")
    }

    @Test func findsTheServiceInARecording() throws {
        // a whole-mux capture lists every service; the first is 9.1's
        #expect(Exporter.firstServiceID(in: Fixtures.dir!.appendingPathComponent("rf27-5min-20s.ts")) == 0x2600)
    }
}
