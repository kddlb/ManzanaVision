// SPDX-License-Identifier: GPL-2.0-only
import CoreMedia
import ManzanaStream

public enum PlaybackError: Error, Sendable {
    case coreMedia(String, OSStatus)
    case audioFormat(String)
}

/// Turns parsed H.264 frames into compressed (AVCC) CMSampleBuffers.
public struct VideoSampleFactory {
    private var format: CMVideoFormatDescription?
    private var formatKey: [UInt8] = []
    public private(set) var formatChanges = 0

    public init() {}

    public var formatDescription: CMVideoFormatDescription? { format }

    /// 90 kHz timescale throughout
    public static let timescale: CMTimeScale = 90000

    public mutating func sampleBuffer(for frame: H264Frame) throws -> CMSampleBuffer {
        let key = frame.spsBytes + [0xff] + frame.ppsBytes
        if key != formatKey || format == nil {
            format = try Self.makeFormat(sps: frame.spsBytes, pps: frame.ppsBytes)
            formatKey = key
            formatChanges += 1
        }

        // AVCC: each NAL prefixed by its 4-byte big-endian length
        var avcc = [UInt8]()
        avcc.reserveCapacity(frame.nalus.reduce(0) { $0 + $1.bytes.count + 4 })
        for nal in frame.nalus {
            let n = UInt32(nal.bytes.count)
            avcc += [UInt8(n >> 24), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
            avcc += nal.bytes
        }

        let block = try makeBlockBuffer(avcc)
        var timing = CMSampleTimingInfo(
            duration: frameDuration(frame.sps),
            presentationTimeStamp: frame.pts.map { CMTime(value: $0, timescale: Self.timescale) } ?? .invalid,
            decodeTimeStamp: frame.dts.map { CMTime(value: $0, timescale: Self.timescale) } ?? .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                           formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                           sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw PlaybackError.coreMedia("CMSampleBufferCreateReady", st) }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            if !frame.isSyncPoint {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    private func frameDuration(_ sps: SPS) -> CMTime {
        guard sps.timeScale > 0, sps.numUnitsInTick > 0 else { return .invalid }
        // time_scale / num_units_in_tick is the field rate; a frame is two ticks
        return CMTime(value: CMTimeValue(2 * Int64(sps.numUnitsInTick)) * 90000 / CMTimeValue(sps.timeScale),
                      timescale: Self.timescale)
    }

    static func makeFormat(sps: [UInt8], pps: [UInt8]) throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        let st = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let sets = [s.baseAddress!, p.baseAddress!]
                let sizes = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: sets,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        guard st == noErr, let format else { throw PlaybackError.coreMedia("H264ParameterSets", st) }
        return format
    }
}

/// A CMBlockBuffer owning a copy of bytes
func makeBlockBuffer(_ bytes: [UInt8]) throws -> CMBlockBuffer {
    var block: CMBlockBuffer?
    var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
                                                customBlockSource: nil, offsetToData: 0, dataLength: bytes.count,
                                                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
    guard st == noErr, let block else { throw PlaybackError.coreMedia("CMBlockBufferCreate", st) }
    st = bytes.withUnsafeBytes {
        CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0,
                                      dataLength: bytes.count)
    }
    guard st == noErr else { throw PlaybackError.coreMedia("CMBlockBufferReplaceDataBytes", st) }
    return block
}
