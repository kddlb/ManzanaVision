// SPDX-License-Identifier: GPL-2.0-only
import AVFoundation
import CoreMedia
import Foundation
@testable import ManzanaPlayback
import ManzanaStream
import Testing

enum Fixtures {
    static let dir = ProcessInfo.processInfo.environment["MANZANA_FIXTURES"].map { URL(fileURLWithPath: $0) }
    static func data(_ clip: String) -> Data? {
        dir.flatMap { try? Data(contentsOf: $0.appendingPathComponent("\(clip).ts")) }
    }
    static let available = dir.map {
        FileManager.default.fileExists(atPath: $0.appendingPathComponent("rf27-5min-20s.ts").path)
    } ?? false
}

/// Parsed elementary-stream units for one PID of a clip
func units(_ clip: String, pid: UInt16) -> (video: [H264Frame], audio: [AACFrame]) {
    guard let ts = Fixtures.data(clip) else { return ([], []) }
    var demux = TSDemuxer(pids: [pid])
    var h264 = H264Assembler()
    var aac = AACStreamParser()
    var video: [H264Frame] = [], audio: [AACFrame] = []
    func handle(_ e: DemuxEvent) {
        guard case .pes(let p) = e else { return }
        video += h264.feed(p)
        audio += aac.feed(p)
    }
    ts.withUnsafeBytes { demux.feed($0, emit: handle) }
    demux.flush(emit: handle)
    return (video, audio)
}

/// RMS of interleaved float PCM in a sample buffer
func rms(_ sb: CMSampleBuffer) -> Float {
    guard let block = CMSampleBufferGetDataBuffer(sb) else { return 0 }
    var length = 0
    var ptr: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
    guard let ptr else { return 0 }
    let n = length / 4
    return ptr.withMemoryRebound(to: Float.self, capacity: n) { f in
        var sum: Float = 0
        for i in 0..<n { sum += f[i] * f[i] }
        return (sum / Float(max(n, 1))).squareRoot()
    }
}

@Suite(.enabled(if: Fixtures.available, "set MANZANA_FIXTURES"))
struct AudioDecoding {
    // (clip, pid, output rate, samples per frame)
    @Test(arguments: [("rf27-5min-20s", UInt16(0x67), 48000, 2048),   // HE-AAC LATM, implicit SBR
                      ("rf27-5min-20s", UInt16(0xcb), 48000, 1024),   // AAC-LC ADTS labelled LATM
                      ("rf32-5min-20s", UInt16(0x1e2), 44100, 1024)]) // AAC-LC ADTS at 44.1 kHz
    func decodesToAudiblePCM(clip: String, pid: UInt16, rate: Int, samples: Int) throws {
        let frames = units(clip, pid: pid).audio
        try #require(frames.count > 100)
        let decoder = AudioDecoder()
        var loud = 0
        var nextPTS: CMTime?
        var gaps = 0
        for (i, f) in frames.prefix(200).enumerated() {
            guard let sb = try decoder.decode(f) else { continue }  // priming
            // the first output is shortened by the decoder's priming trim
            if i > 0 { #expect(CMSampleBufferGetNumSamples(sb) == samples) }
            // outputs tile the timeline: each starts where the previous ended (±1 tick)
            let pts = CMSampleBufferGetPresentationTimeStamp(sb)
            // …except where the decoder re-anchored on a real loss (counted below)
            if let nextPTS, abs((pts - nextPTS).seconds) >= 1.0 / 90000 { gaps += 1 }
            nextPTS = pts + CMSampleBufferGetDuration(sb)
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sb)!)!.pointee
            #expect(Int(asbd.mSampleRate) == rate)
            if rms(sb) > 0.001 { loud += 1 }
        }
        #expect(decoder.concealed <= 2, "concealed \(decoder.concealed) of 200")
        #expect(gaps == decoder.reanchors, "\(gaps) gaps but \(decoder.reanchors) re-anchors")
        #expect(decoder.reanchors <= 2, "\(decoder.reanchors) re-anchors: timestamps jitter through")
        #expect(loud > 150, "only \(loud) of 200 frames carry sound")
    }
}

@Suite(.enabled(if: Fixtures.available, "set MANZANA_FIXTURES"))
struct VideoSamples {
    @Test(arguments: [("rf27-5min-20s", UInt16(0x66), 1920, 1080), ("rf32-5min-20s", UInt16(0x1e1), 1280, 720),
                      ("rf27-5min-20s", UInt16(0x401), 320, 180)])
    func buildsSampleBuffers(clip: String, pid: UInt16, width: Int32, height: Int32) throws {
        let frames = units(clip, pid: pid).video
        try #require(frames.count > 100)
        var factory = VideoSampleFactory()
        for f in frames.prefix(60) {
            let sb = try factory.sampleBuffer(for: f)
            #expect(CMSampleBufferGetPresentationTimeStamp(sb).isValid)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(factory.formatDescription))
        #expect(dims.width == width && dims.height == height)
    }
}
