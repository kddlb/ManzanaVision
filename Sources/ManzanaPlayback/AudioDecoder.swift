// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import CoreMedia
import ManzanaStream

/// Decodes AAC frames (LC or HE-AAC, incl. implicit SBR) to interleaved
/// Float32 PCM sample buffers for AVSampleBufferAudioRenderer. Corrupt frames
/// become silence of the same length, so the timeline stays continuous.
public final class AudioDecoder {
    public private(set) var config: AudioSpecificConfig?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    public private(set) var outputFormat: AVAudioFormat?
    private var outputDescription: CMAudioFormatDescription?
    public private(set) var decoded = 0
    public private(set) var concealed = 0
    /// Decoder latency bookkeeping, in output samples: the converter trims its
    /// priming (962 samples for HE-AAC here), so later outputs lag their input
    private var fedSamples = 0
    private var producedSamples = 0
    /// Continuous output clock. Broadcast PES timestamps jitter (±10 ms on
    /// 14.3's 44.1 kHz audio), so outputs follow the sample count and only
    /// re-anchor when the stream's timing disagrees by more than this.
    public static let reanchorThreshold = CMTime(value: 40, timescale: 1000)
    private var nextOutputPTS: CMTime?
    public private(set) var reanchors = 0

    public init() {}

    /// The config Apple's decoder should see: implicit SBR made explicit
    public static func effectiveConfig(_ c: AudioSpecificConfig) -> AudioSpecificConfig {
        c.withImplicitSBR
    }

    private func configure(_ raw: AudioSpecificConfig) throws {
        let c = Self.effectiveConfig(raw)
        var asbd = AudioStreamBasicDescription()
        asbd.mSampleRate = Float64(c.outputSampleRate)
        asbd.mFormatID = c.ps ? kAudioFormatMPEG4AAC_HE_V2 : (c.sbr ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC)
        asbd.mChannelsPerFrame = UInt32(c.channels)
        asbd.mFramesPerPacket = UInt32(c.samplesPerFrame * (c.sbr ? 2 : 1))
        guard let input = AVAudioFormat(streamDescription: &asbd) else {
            throw PlaybackError.audioFormat("no AVAudioFormat for \(c)")
        }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(c.outputSampleRate),
                                         channels: AVAudioChannelCount(c.channels), interleaved: true),
              let conv = AVAudioConverter(from: input, to: output) else {
            throw PlaybackError.audioFormat("no converter for \(c)")
        }
        conv.magicCookie = Data(c.serialize())
        converter = conv
        nextOutputPTS = nil
        fedSamples = 0
        producedSamples = 0
        inputFormat = input
        outputFormat = output
        outputDescription = output.formatDescription
        config = raw
    }

    /// Decodes one frame; nil only if the stream's config can't be decoded at all
    public func decode(_ frame: AACFrame) throws -> CMSampleBuffer? {
        if frame.config != config || converter == nil {
            try configure(frame.config)
        }
        guard let converter, let inputFormat, let outputFormat else { return nil }
        let frames = AVAudioFrameCount(inputFormat.streamDescription.pointee.mFramesPerPacket)
        guard let pcm = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames) else { return nil }

        let packet = AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1,
                                             maximumPacketSize: max(frame.data.count, 1))
        frame.data.withUnsafeBytes { packet.data.copyMemory(from: $0.baseAddress!, byteCount: frame.data.count) }
        packet.byteLength = UInt32(frame.data.count)
        packet.packetCount = 1
        packet.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.data.count))

        let latency = fedSamples - producedSamples
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return packet
        }
        var pts = frame.pts
        if status == .error || (pcm.frameLength == 0 && fedSamples > 0) {
            // conceal: silence for the frame's duration, and start the decoder fresh
            concealed += 1
            converter.reset()
            fedSamples = 0
            producedSamples = 0
            pcm.frameLength = frames
            memset(pcm.audioBufferList.pointee.mBuffers.mData, 0, Int(pcm.audioBufferList.pointee.mBuffers.mDataByteSize))
        } else {
            decoded += 1
            fedSamples += Int(frames)
            producedSamples += Int(pcm.frameLength)
            // this output starts `latency` samples before the input frame did
            pts = pts.map { $0 - Int64(latency) * 90000 / Int64(outputFormat.sampleRate) }
            if pcm.frameLength == 0 { return nil }  // still priming
        }
        return try sampleBuffer(pcm, pts: pts)
    }

    public func reset() {
        converter?.reset()
        nextOutputPTS = nil
        fedSamples = 0
        producedSamples = 0
    }

    private func sampleBuffer(_ pcm: AVAudioPCMBuffer, pts: Int64?) throws -> CMSampleBuffer {
        let abl = pcm.audioBufferList.pointee
        let bytes = Int(abl.mBuffers.mDataByteSize)
        let count = Int(pcm.frameLength)
        let used = count * Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        var data = [UInt8](repeating: 0, count: used)
        data.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: abl.mBuffers.mData, count: min(bytes, used))) }
        let block = try makeBlockBuffer(data)
        let rate = CMTimeScale(pcm.format.sampleRate)
        var start = pts.map { CMTime(value: $0, timescale: 90000) } ?? .invalid
        if let next = nextOutputPTS {
            if !start.isValid || CMTimeAbsoluteValue(start - next) <= Self.reanchorThreshold {
                start = next
            } else {
                reanchors += 1
            }
        }
        if start.isValid {
            nextOutputPTS = start + CMTime(value: CMTimeValue(count), timescale: rate)
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                                        presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        var size = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                           formatDescription: outputDescription, sampleCount: count,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                           sampleBufferOut: &sample)
        guard st == noErr, let sample else { throw PlaybackError.coreMedia("audio CMSampleBufferCreateReady", st) }
        return sample
    }
}
