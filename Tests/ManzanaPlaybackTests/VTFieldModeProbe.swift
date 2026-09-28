import CoreMedia
import Foundation
@testable import ManzanaPlayback
import ManzanaStream
import Testing
import VideoToolbox

/// Spike: does VideoToolbox's decoder deinterlace, and at field rate?
@Suite(.enabled(if: Fixtures.available && ProcessInfo.processInfo.environment["VT_PROBE"] != nil))
struct VTFieldModeProbe {
    final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var outputs = 0
        var errors = 0
        var fieldCounts: [Int: Int] = [:]
        var sizes = Set<String>()
        var ptsList: [Double] = []
    }

    @Test(arguments: ["none", "DeinterlaceFields/VerticalFilter", "DeinterlaceFields/Temporal", "BothFields"])
    func fieldMode(mode: String) throws {
        let frames = Array(units("rf27-5min-20s", pid: 0x66).video.prefix(120))
        var factory = VideoSampleFactory()
        let samples = try frames.map { try factory.sampleBuffer(for: $0) }
        let format = try #require(factory.formatDescription)

        let counter = Counter()
        var session: VTDecompressionSession?
        let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        var st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                              decompressionSessionOut: &session)
        try #require(st == noErr)
        let s = session!
        defer { VTDecompressionSessionInvalidate(s) }

        var accepted: [String: OSStatus] = [:]
        if mode != "none" {
            let fm = mode.hasPrefix("Deinterlace") ? kVTDecompressionProperty_FieldMode_DeinterlaceFields
                                                   : kVTDecompressionProperty_FieldMode_BothFields
            accepted["FieldMode"] = VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_FieldMode, value: fm)
            if mode.hasSuffix("Temporal") || mode.hasSuffix("VerticalFilter") {
                let dm = mode.hasSuffix("Temporal") ? kVTDecompressionProperty_DeinterlaceMode_Temporal
                                                    : kVTDecompressionProperty_DeinterlaceMode_VerticalFilter
                accepted["DeinterlaceMode"] = VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_DeinterlaceMode, value: dm)
            }
        }
        var supported: CFDictionary?
        VTSessionCopySupportedPropertyDictionary(s, supportedPropertyDictionaryOut: &supported)
        let keys = (supported as? [String: Any]).map { Array($0.keys).filter { $0.contains("Field") || $0.contains("Deinterlace") } } ?? []

        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
        for sb in samples {
            st = VTDecompressionSessionDecodeFrame(s, sampleBuffer: sb, flags: flags, infoFlagsOut: nil) { status, _, image, pts, _ in
                counter.lock.withLock {
                    guard status == noErr, let image else { counter.errors += 1; return }
                    counter.outputs += 1
                    let fc = (CVBufferCopyAttachment(image, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue ?? 0
                    counter.fieldCounts[fc, default: 0] += 1
                    counter.sizes.insert("\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))")
                    counter.ptsList.append(pts.seconds)
                }
            }
        }
        VTDecompressionSessionFinishDelayedFrames(s)
        VTDecompressionSessionWaitForAsynchronousFrames(s)
        let pts = counter.ptsList.sorted()
        let steps = zip(pts.dropFirst(), pts).map { (($0 - $1) * 1000).rounded() }
        print("VTPROBE \(mode): set \(accepted) supported-keys \(keys)")
        print("VTPROBE \(mode): \(samples.count) samples in → \(counter.outputs) images out, \(counter.errors) errors, FieldCount \(counter.fieldCounts), sizes \(counter.sizes), pts steps(ms) \(Set(steps).sorted().prefix(6))")
    }
}
