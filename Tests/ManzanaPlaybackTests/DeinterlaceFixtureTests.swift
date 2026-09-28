// SPDX-License-Identifier: GPL-2.0-only
import CoreMedia
import CoreVideo
import Foundation
@testable import ManzanaPlayback
import ManzanaStream
import Testing
import VideoToolbox

/// Decodes a stream's first frames with VideoToolbox, in display order
func decodeFrames(_ clip: String, pid: UInt16, count: Int) throws -> [CVPixelBuffer] {
    let frames = Array(units(clip, pid: pid).video.prefix(count))
    var factory = VideoSampleFactory()
    let samples = try frames.map { try factory.sampleBuffer(for: $0) }
    var session: VTDecompressionSession?
    let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                  kCVPixelBufferMetalCompatibilityKey: true]
    VTDecompressionSessionCreate(allocator: nil, formatDescription: factory.formatDescription!, decoderSpecification: nil,
                                 imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                 decompressionSessionOut: &session)
    final class Out: @unchecked Sendable { var frames: [(CMTime, CVPixelBuffer)] = []; let lock = NSLock() }
    let out = Out()
    for sb in samples {
        VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sb, flags: [], infoFlagsOut: nil) { st, _, img, pts, _ in
            if st == noErr, let img { out.lock.withLock { out.frames.append((pts, img)) } }
        }
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session!)
    VTDecompressionSessionInvalidate(session!)
    return out.frames.sorted { $0.0 < $1.0 }.map(\.1)
}

/// Comb metric on luma, sampling every 2nd column for speed
func combMetric(_ p: CVPixelBuffer) -> Double {
    CVPixelBufferLockBaseAddress(p, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(p, .readOnly) }
    let w = CVPixelBufferGetWidth(p), h = CVPixelBufferGetHeight(p)
    let y = CVPixelBufferGetBaseAddressOfPlane(p, 0)!.assumingMemoryBound(to: UInt8.self)
    let s = CVPixelBufferGetBytesPerRowOfPlane(p, 0)
    var sum = 0
    for r in 1..<(h - 1) {
        let a = y + (r - 1) * s, b = y + r * s, c = y + (r + 1) * s
        for x in stride(from: 0, to: w, by: 2) { sum += abs(2 * Int(b[x]) - Int(a[x]) - Int(c[x])) }
    }
    return Double(sum) / Double((h - 2) * (w / 2))
}

@Suite(.enabled(if: Fixtures.available, "set MANZANA_FIXTURES"))
struct DeinterlaceOnBroadcast {
    @Test(arguments: [("rf27-5min-20s", UInt16(0x66), "9.1 PAFF"), ("rf32-5min-20s", UInt16(0xc9), "14.2 MBAFF")])
    func yadifRemovesCombing(clip: String, pid: UInt16, label: String) throws {
        let frames = try decodeFrames(clip, pid: pid, count: 90)
        try #require(frames.count > 60)
        let d = try Deinterlacer()
        var woven: [Double] = [], yadif: [Double] = []
        for i in 1..<(frames.count - 1) {
            woven.append(combMetric(frames[i]))
            let out = try d.field(prev: frames[i - 1], cur: frames[i], next: frames[i + 1], first: true,
                                  topFieldFirst: true, mode: .yadif)
            yadif.append(combMetric(out))
        }
        // frames where weaving combs noticeably more than YADIF are the moving ones
        let ratios = zip(woven, yadif).map { $0 / max($1, 0.01) }
        let moving = ratios.filter { $0 > 1.2 }.count
        let worse = ratios.filter { $0 < 0.9 }.count
        print(String(format: "DEINT %@: comb woven %.2f → yadif %.2f (mean); max ratio %.2f; %d/%d frames improved >20%%, %d worse",
                     label, woven.reduce(0, +) / Double(woven.count), yadif.reduce(0, +) / Double(yadif.count),
                     ratios.max()!, moving, ratios.count, worse))
        #expect(yadif.reduce(0, +) <= woven.reduce(0, +), "YADIF combs more than the woven input")
        #expect(worse == 0, "\(worse) frames got more combed")
    }
}
