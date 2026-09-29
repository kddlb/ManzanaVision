// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ManzanaCore
import ManzanaStream

/// Turns a recording (MPEG-TS) into an MP4 that QuickTime, Photos and iOS
/// play: HEVC, deinterlaced to the field rate like live playback, and AAC,
/// with the closed captions as a subtitle track (3GPP timed text).
///
/// The file is read as fast as the decoder and encoder go. Video runs through
/// the same VideoPipeline as playback (VideoToolbox decode, Metal
/// deinterlacing), in offline mode; audio is decoded to PCM and re-encoded.
/// Everything is appended on one writer queue.
public final class Exporter: @unchecked Sendable {
    public struct Summary: Sendable {
        public var videoFrames = 0
        public var audioBuffers = 0
        /// Samples dropped because their timestamps went backwards (a re-tune
        /// that reset the broadcaster's clock) or their size changed mid-file
        public var skipped = 0
        public var decodeErrors = 0
        /// Seconds of silence put into audio gaps (signal loss while recording)
        public var silence: Double = 0
        public var duration: Double = 0
        /// Caption screens (with text) written to the subtitle track
        public var captions = 0
    }

    public enum ExportError: LocalizedError {
        case unreadable
        case noProgram
        case nothingDecoded
        case writer(String)

        public var errorDescription: String? {
            switch self {
            case .unreadable: String(localized: "The recording can't be read.")
            case .noProgram: String(localized: "The recording doesn't contain a TV or radio program.")
            case .nothingDecoded: String(localized: "Nothing in the recording could be decoded.")
            case .writer(let why): why
            }
        }
    }

    public let source: URL
    public let serviceID: UInt16
    public let destination: URL
    public let deinterlace: DeinterlaceMode

    private let lock = NSLock()
    private var cancelled = false

    public init(source: URL, serviceID: UInt16, destination: URL, deinterlace: DeinterlaceMode = .auto) {
        self.source = source
        self.serviceID = serviceID
        self.destination = destination
        self.deinterlace = deinterlace == .decoder || deinterlace == .off ? deinterlace : (deinterlace == .auto ? .yadif : deinterlace)
    }

    /// Exports, reporting progress (0...1) now and then from a background
    /// thread. Cancelling the task stops it and removes the partial file.
    public func run(progress: @escaping @Sendable (Double) -> Void) async throws -> Summary {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Summary, Error>) in
                let thread = Thread { cont.resume(with: Result { try self.work(progress: progress) }) }
                thread.name = "mzv.export"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        } onCancel: {
            lock.withLock { cancelled = true }
        }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    /// The first program listed in the file's PAT: the channel, in a
    /// recording (which lists only that one)
    public static func firstServiceID(in url: URL) -> UInt16? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 188 * 20_000) else { return nil }
        return data.withUnsafeBytes { raw -> UInt16? in
            let b = raw.bindMemory(to: UInt8.self)
            var off = 0
            while off + 188 <= b.count {
                defer { off += 188 }
                // sync, payload_unit_start, PID 0, payload present
                guard b[off] == 0x47, b[off + 1] & 0x40 != 0, (UInt16(b[off + 1] & 0x1f) << 8 | UInt16(b[off + 2])) == 0 else { continue }
                var p = off + 4
                if b[off + 3] & 0x20 != 0 { p += 1 + Int(b[p]) }  // adaptation field
                guard p < off + 188 else { continue }
                p += 1 + Int(b[p])  // pointer field
                guard p + 8 <= off + 188, b[p] == 0x00 else { continue }  // table_id: PAT
                let length = Int(b[p + 1] & 0x0f) << 8 | Int(b[p + 2])
                var q = p + 8
                let end = min(p + 3 + length - 4, off + 188)  // without the CRC
                while q + 4 <= end {
                    let program = UInt16(b[q]) << 8 | UInt16(b[q + 1])
                    if program != 0 { return program }
                    q += 4
                }
            }
            return nil
        }
    }

    // MARK: - export thread

    private func work(progress: @Sendable (Double) -> Void) throws -> Summary {
        guard let data = try? Data(contentsOf: source, options: .alwaysMapped) else { throw ExportError.unreadable }
        try? FileManager.default.removeItem(at: destination)
        let writer = try Writer(destination: destination)

        // bound the frames between the file and the encoder
        let inFlight = DispatchSemaphore(value: 24)
        let video = VideoPipeline(mode: deinterlace, frames: { image, pts, duration in
            writer.appendVideo(image, pts: pts, duration: duration)
        }, decodedOne: { inFlight.signal() })

        var demux = TSDemuxer(pids: [UInt16]())
        var h264 = H264Assembler()
        var aac = AACStreamParser()
        var factory = VideoSampleFactory()
        let audioDecoder = AudioDecoder()
        var videoPID: UInt16?
        var audioPID: UInt16?
        var captionPID: UInt16?
        var captions = ARIBCaptionDecoder()
        var captionClock = CaptionClock()
        var newestVideo: CMTime = .invalid, newestAudio: CMTime = .invalid
        var haveSync = false
        // compressed video waiting for room in the decoder; reading goes on
        // meanwhile, so audio keeps flowing to the writer
        var waiting: [CMSampleBuffer] = []
        func pump(blockAbove limit: Int) {
            while !waiting.isEmpty {
                if waiting.count > limit {
                    inFlight.wait()
                } else if inFlight.wait(timeout: .now()) != .success {
                    return
                }
                video.decode(waiting.removeFirst())
            }
        }

        let filter = mzv_filter_new(serviceID, true)
        defer { mzv_filter_free(filter) }
        let total = data.count / 188
        let batch = 512
        var out = [UInt8](repeating: 0, count: batch * 188)
        var generation: UInt32 = 0
        var i = 0
        var reported = -1.0

        func handle(_ event: DemuxEvent) {
            guard case .pes(let pes) = event else { return }
            if pes.pid == videoPID {
                for frame in h264.feed(pes) {
                    if !haveSync {
                        guard frame.isSyncPoint else { continue }
                        haveSync = true
                    }
                    guard let sb = try? factory.sampleBuffer(for: frame) else { continue }
                    let pts = CMSampleBufferGetPresentationTimeStamp(sb)
                    if pts.isValid, !newestVideo.isValid || pts > newestVideo { newestVideo = pts }
                    waiting.append(sb)
                }
            } else if pes.pid == audioPID {
                for frame in aac.feed(pes) {
                    if let sb = try? audioDecoder.decode(frame) {
                        newestAudio = CMSampleBufferGetPresentationTimeStamp(sb)
                        writer.appendAudio(sb)
                    }
                }
            } else if pes.pid == captionPID {
                let page = captions.decode(pes.payload)
                if let language = captions.page.language { writer.captionLanguage(language) }
                guard let page else { return }
                let time = captionClock.time(pts: pes.pts, muxedWith: newestVideo.isValid ? newestVideo : newestAudio)
                if time.isValid { writer.appendCaption(page.text, at: time) }
            }
        }

        while i < total {
            if isCancelled {
                writer.cancel()
                throw CancellationError()
            }
            let n = min(batch, total - i)
            let kept = data.withUnsafeBytes { raw in
                mzv_filter_feed(filter, raw.bindMemory(to: UInt8.self).baseAddress! + i * 188, n, &out)
            }
            i += n
            var prog = mzv_program()
            if mzv_filter_program(filter, &prog), prog.generation != generation {
                generation = prog.generation
                let streams = withUnsafeBytes(of: prog.es) { raw in
                    raw.bindMemory(to: mzv_es.self).prefix(Int(prog.nes)).map {
                        ProgramStream($0)
                    }
                }
                videoPID = streams.first(where: \.isVideo)?.pid
                audioPID = streams.first(where: \.isAudio)?.pid
                captionPID = streams.first(where: \.isCaption)?.pid
                demux.setPIDs([videoPID, audioPID, captionPID].compactMap { $0 }, pcrPID: nil)
                writer.expect(video: videoPID != nil, audio: audioPID != nil, captions: captionPID != nil)
            }
            if kept > 0 {
                out.withUnsafeBytes { raw in
                    demux.feed(UnsafeRawBufferPointer(rebasing: raw.prefix(kept * 188))) { handle($0) }
                }
            }
            pump(blockAbove: 300)  // ~10 s of pictures
            let p = Double(i) / Double(max(1, total))
            if p - reported >= 0.005 {
                reported = p
                progress(p)
            }
            if let failure = writer.failure {
                writer.cancel()
                throw ExportError.writer(failure)
            }
        }
        guard generation > 0 else {
            writer.cancel()
            throw ExportError.noProgram
        }

        writer.audioEnded()  // the writer waits for audio up ahead unless it knows there's no more
        pump(blockAbove: 0)
        video.finish()
        var summary = try writer.finish()
        summary.decodeErrors = video.currentStats().decodeErrors
        progress(1)
        return summary
    }
}

/// The AVAssetWriter side. It waits until it knows the formats it has to
/// write, then appends in timestamp order per track.
///
/// Nothing ever waits inside its queue: the writer refuses a track that runs
/// ahead of the other, and both tracks come from one reader, so a refused
/// sample is queued and retried on the next call. Video waits outside the
/// queue when too much is queued; the reader keeps going meanwhile (see
/// Exporter.work), so the audio the writer is waiting for still arrives.
private final class Writer: @unchecked Sendable {
    private let destination: URL
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "mzv.export.writer")
    private static let maxQueuedVideo = 30

    // queue-confined
    private var expectVideo = true
    private var expectAudio = true
    private var expectCaptions = false
    private var language: String?
    private var videoReceiver: AVAssetWriterInput.PixelBufferReceiver?
    private var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
    private var captionReceiver: AVAssetWriterInput.SampleBufferReceiver?
    /// Caption screens from before the start
    private var earlyCaptions: [(text: String, time: CMTime)] = []
    /// The screen on show, written once the next one says how long it lasts
    private var openCaption: (text: String, time: CMTime)?
    private var queuedCaptions: [CMSampleBuffer] = []
    private var captionsWritten = false
    private var started = false
    private var audioDone = false      // no more audio will come
    private var audioFinished = false  // ...and the input's been told
    private var videoFinished = false
    private var start: CMTime = .invalid
    private var queuedVideo: [(CVPixelBuffer, CMTime)] = []
    private var queuedAudio: [CMSampleBuffer] = []
    private var lastVideo: CMTime = .invalid
    private var lastAudio: CMTime = .invalid
    private var audioEnd: CMTime = .invalid
    /// The audio encoder joins whatever it's given end to end, ignoring
    /// timestamps, so holes longer than this are filled with silence
    private static let audioGapTolerance = CMTime(value: 20, timescale: 1000)
    private var end: CMTime = .invalid
    private var videoSize: (Int, Int)?
    private var summary = Exporter.Summary()
    private var _failure: String?

    init(destination: URL) throws {
        self.destination = destination
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        } catch {
            throw Exporter.ExportError.writer(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
    }

    var failure: String? { queue.sync { _failure } }

    func expect(video: Bool, audio: Bool, captions: Bool) {
        queue.sync {
            guard !started else { return }
            expectVideo = video
            expectAudio = audio
            expectCaptions = captions
        }
    }

    /// ISO 639-2, for the subtitle track (known within a second or so of captions)
    func captionLanguage(_ code: String) {
        queue.sync {
            guard language == nil else { return }
            language = code
            if !started { startIfReady() }
        }
    }

    /// A caption screen (the text shown from `time` until the next one; "" clears)
    func appendCaption(_ text: String, at time: CMTime) {
        queue.sync {
            guard _failure == nil else { return }
            if started {
                caption(text, at: time)
                drain()
            } else {
                earlyCaptions.append((text, time))
            }
        }
    }

    func appendVideo(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        queue.sync {
            guard _failure == nil else { return }
            queuedVideo.append((image, pts))
            if started { drain() } else { startIfReady() }
        }
        // the encoder is behind: hold the decoder back until it catches up
        var waited = 0
        while queue.sync(execute: { started && _failure == nil && queuedVideo.count > Self.maxQueuedVideo }) {
            usleep(2000)
            queue.sync { drain() }
            waited += 1
            if waited > 10_000 { queue.sync { fail(String(localized: "The encoder stopped responding.")) } }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        queue.sync {
            guard _failure == nil else { return }
            queuedAudio.append(sample)
            if started { drain() } else { startIfReady() }
        }
    }

    func audioEnded() {
        queue.sync {
            audioDone = true
            if started { drain() }
        }
    }

    func cancel() {
        queue.sync {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: destination)
        }
    }

    func finish() throws -> Exporter.Summary {
        let summary: Exporter.Summary = try queue.sync {
            if !started {
                // a stream never showed up: write what there is
                if queuedVideo.isEmpty { expectVideo = false }
                if queuedAudio.isEmpty { expectAudio = false }
                guard expectVideo || expectAudio else { throw Exporter.ExportError.nothingDecoded }
                if language == nil { language = "und" }
                startIfReady()
            }
            // write out everything left, ending each track as it runs out
            audioDone = true
            var tries = 0
            while _failure == nil {
                drain()
                if queuedVideo.isEmpty && !videoFinished {
                    videoReceiver?.finish()
                    videoFinished = true
                    continue
                }
                if queuedVideo.isEmpty && queuedAudio.isEmpty { break }
                tries += 1
                if tries > 10_000 { fail(String(localized: "The encoder stopped responding.")) } else { usleep(1000) }
            }
            if let _failure { throw Exporter.ExportError.writer(_failure) }
            if !videoFinished { videoReceiver?.finish() }
            if !audioFinished { audioReceiver?.finish() }
            finishCaptions()
            if let _failure { throw Exporter.ExportError.writer(_failure) }
            if end.isValid { writer.endSession(atSourceTime: end) }
            var s = self.summary
            s.duration = start.isValid && end.isValid ? (end - start).seconds : 0
            return s
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw Exporter.ExportError.writer(writer.error?.localizedDescription ?? String(localized: "The movie couldn't be written."))
        }
        return summary
    }

    // MARK: queue

    /// Starts once each expected stream has produced something, or when one
    /// clearly isn't coming (lots of the other queued)
    private func startIfReady() {
        let videoReady = !expectVideo || !queuedVideo.isEmpty
        let audioReady = !expectAudio || !queuedAudio.isEmpty
        // the subtitle track's language is set when it's added: wait a little for it
        let captionsReady = !expectCaptions || language != nil
        let starving = queuedVideo.count > 120 || queuedAudio.count > 400
        guard (videoReady && audioReady && captionsReady) || starving else { return }
        guard videoReady || audioReady else { return }
        if starving {
            if queuedVideo.isEmpty { expectVideo = false }
            if queuedAudio.isEmpty { expectAudio = false }
        }

        if expectVideo, let (image, _) = queuedVideo.first {
            let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
            videoSize = (w, h)
            let bitrate = max(500_000, Int(Double(w * h) * 60 * 0.08))  // ≈10 Mbit/s at 1080p60
            var settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: w,
                AVVideoHeightKey: h,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoExpectedSourceFrameRateKey: 60,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                ],
            ]
            if let par = CVBufferCopyAttachment(image, kCVImageBufferPixelAspectRatioKey, nil) as? [String: Any],
               let hs = par[kCVImageBufferPixelAspectRatioHorizontalSpacingKey as String] as? Int,
               let vs = par[kCVImageBufferPixelAspectRatioVerticalSpacingKey as String] as? Int, hs != vs {
                settings[AVVideoPixelAspectRatioKey] = [AVVideoPixelAspectRatioHorizontalSpacingKey: hs,
                                                        AVVideoPixelAspectRatioVerticalSpacingKey: vs]
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            guard writer.canAdd(input) else { return fail(String(localized: "The video can't be encoded.")) }
            videoReceiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        }
        if expectAudio, let first = queuedAudio.first, let format = CMSampleBufferGetFormatDescription(first),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
            let channels = Int(asbd.mChannelsPerFrame)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: channels > 2 ? 384_000 : 192_000,
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings, sourceFormatHint: format)
            guard writer.canAdd(input) else { return fail(String(localized: "The audio can't be encoded.")) }
            audioReceiver = writer.inputReceiver(for: input)
        }
        if expectCaptions, let format = Self.timedTextFormat {
            let input = AVAssetWriterInput(mediaType: .subtitle, outputSettings: nil, sourceFormatHint: format)
            input.languageCode = language ?? "und"
            // closed captions: there to turn on, not shown by default
            input.marksOutputTrackAsEnabled = false
            if writer.canAdd(input) { captionReceiver = writer.inputReceiver(for: input) }
        }
        if videoReceiver == nil { queuedVideo.removeAll() }
        if audioReceiver == nil { queuedAudio.removeAll() }
        guard videoReceiver != nil || audioReceiver != nil else {
            return fail(String(localized: "Nothing in the recording could be decoded."))
        }
        do {
            try writer.start()
        } catch {
            return fail(error.localizedDescription)
        }
        // start with the picture; audio from before the first frame is dropped
        start = videoReceiver != nil ? queuedVideo[0].1 : CMSampleBufferGetPresentationTimeStamp(queuedAudio[0])
        writer.startSession(atSourceTime: start)
        started = true
        for c in earlyCaptions { caption(c.text, at: c.time) }
        earlyCaptions.removeAll()
        drain()
    }

    // MARK: captions

    /// Closes the screen on show at `time` and opens this one. Samples cover
    /// the track end to end, blanks included, as timed text wants.
    private func caption(_ text: String, at time: CMTime) {
        guard captionReceiver != nil else { return }
        let t = max(time, start)  // said before the first picture: show from the start
        if let open = openCaption {
            guard t > open.time else {
                openCaption = (text, open.time)  // same instant: the newer screen wins
                return
            }
            queueCaption(open.text, from: open.time, to: t)
        } else if t > start {
            queueCaption("", from: start, to: t)
        }
        openCaption = (text, t)
        if !text.isEmpty { summary.captions += 1 }
    }

    /// The writer interleaves by time and holds the picture back until every
    /// track has caught up, so the screen on show is written in pieces as the
    /// picture advances (players show consecutive same-text samples as one)
    private func advanceCaptions(to t: CMTime) {
        guard captionReceiver != nil, t.isValid, t > start else { return }
        let open = openCaption ?? ("", start)
        guard (t - open.time).seconds >= 0.5 else {
            openCaption = open
            return
        }
        queueCaption(open.text, from: open.time, to: t)
        openCaption = (open.text, t)
    }

    private func queueCaption(_ text: String, from: CMTime, to: CMTime) {
        guard let sample = Self.timedText(text, at: from, duration: to - from) else { return }
        queuedCaptions.append(sample)
    }

    private func finishCaptions() {
        guard let receiver = captionReceiver else { return }
        let stop = end.isValid ? end : start
        if let open = openCaption, stop > open.time {
            queueCaption(open.text, from: open.time, to: stop)
        } else if openCaption == nil, !captionsWritten, queuedCaptions.isEmpty, stop > start {
            queueCaption("", from: start, to: stop)  // no captions after all: an empty track, not a broken one
        }
        openCaption = nil
        var tries = 0
        while !queuedCaptions.isEmpty && _failure == nil {
            drainCaptions()
            tries += 1
            if tries > 10_000 { fail(String(localized: "The encoder stopped responding.")) } else if !queuedCaptions.isEmpty { usleep(1000) }
        }
        receiver.finish()
    }

    private func drainCaptions() {
        guard let receiver = captionReceiver else {
            queuedCaptions.removeAll()
            return
        }
        while let sample = queuedCaptions.first {
            nonisolated(unsafe) let owned = sample
            switch attempt({ try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: owned)) }) {
            case .written, .skipped:
                queuedCaptions.removeFirst()
                captionsWritten = true
            case .notNow, .failed:
                return
            }
        }
    }

    /// 3GPP timed text (tx3g): centred at the bottom, white, the player's own font and size
    private static let timedTextFormat: CMFormatDescription? = {
        var d: [UInt8] = []
        func u16(_ v: Int) { d += [UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
        func u32(_ v: Int) { u16(v >> 16); u16(v & 0xffff) }
        let font = Array("Sans-Serif".utf8)
        u32(0)                                   // size, filled in below
        d += Array("tx3g".utf8)
        d += [0, 0, 0, 0, 0, 0]; u16(1)          // reserved, data_reference_index
        u32(0)                                   // display flags
        d += [0x01, 0xff]                        // justification: centred, bottom
        d += [0, 0, 0, 0]                        // background: none
        u16(0); u16(0); u16(0); u16(0)           // default text box: the whole track
        u16(0); u16(0); u16(1); d += [0, 18]     // style: chars, font 1, plain, 18 pt
        d += [0xff, 0xff, 0xff, 0xff]            // white
        u32(8 + 2 + 3 + font.count); d += Array("ftab".utf8)
        u16(1); u16(1); d.append(UInt8(font.count)); d += font
        let size = d.count
        d[0] = UInt8(size >> 24 & 0xff); d[1] = UInt8(size >> 16 & 0xff); d[2] = UInt8(size >> 8 & 0xff); d[3] = UInt8(size & 0xff)
        var format: CMFormatDescription?
        let status = d.withUnsafeBufferPointer {
            CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: nil, bigEndianTextDescriptionData: $0.baseAddress!, size: $0.count,
                flavor: nil, mediaType: kCMMediaType_Subtitle, formatDescriptionOut: &format)
        }
        return status == noErr ? format : nil
    }()

    /// One tx3g sample: a 16-bit length, then the UTF-8 text
    private static func timedText(_ text: String, at pts: CMTime, duration: CMTime) -> CMSampleBuffer? {
        guard let format = timedTextFormat, duration > .zero else { return nil }
        let utf8 = Array(text.utf8.prefix(0xffff))
        guard let block = try? makeBlockBuffer([UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)] + utf8) else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var size = utf8.count + 2
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                  sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                  sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return sample
    }

    /// Appends what the writer will take right now, in order
    private func drain() {
        guard _failure == nil else { return }
        drainCaptions()
        var progress = true
        while progress {
            progress = false
            if let (image, pts) = queuedVideo.first {
                switch writeVideo(image, pts: pts) {
                case .written, .skipped: queuedVideo.removeFirst(); progress = true
                case .notNow: break
                case .failed: return
                }
            }
            if let sample = queuedAudio.first {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let from = audioEnd.isValid ? audioEnd : start
                if pts - from > Self.audioGapTolerance {
                    let fill = Self.silence(like: sample, from: from, until: pts)
                    queuedAudio.insert(contentsOf: fill, at: 0)
                    summary.silence += fill.reduce(0) { $0 + CMSampleBufferGetDuration($1).seconds }
                    progress = !fill.isEmpty
                    if progress { continue }
                }
                switch writeAudio(queuedAudio[0]) {
                case .written, .skipped: queuedAudio.removeFirst(); progress = true
                case .notNow: break
                case .failed: return
                }
            }
            let before = queuedCaptions.count
            advanceCaptions(to: lastVideo.isValid ? lastVideo : audioEnd)
            if queuedCaptions.count > before {
                drainCaptions()
                progress = true
            }
            if audioDone, queuedAudio.isEmpty, !audioFinished {
                audioReceiver?.finish()
                audioFinished = true
                progress = true
            }
        }
    }

    private enum Append { case written, skipped, notNow, failed }

    private func writeVideo(_ image: CVPixelBuffer, pts: CMTime) -> Append {
        guard let receiver = videoReceiver else { return .skipped }
        guard pts >= start, !lastVideo.isValid || pts > lastVideo,
              videoSize.map({ $0 == (CVPixelBufferGetWidth(image), CVPixelBufferGetHeight(image)) }) ?? false else {
            summary.skipped += 1
            return .skipped
        }
        nonisolated(unsafe) let owned = image  // read-only from here on
        let result = attempt { try receiver.appendImmediately(CVReadOnlyPixelBuffer(unsafeBuffer: owned), with: pts) }
        if result == .written {
            lastVideo = pts
            end = max(end.isValid ? end : pts, pts + CMTime(value: 1501, timescale: 90000))
            summary.videoFrames += 1
        }
        return result
    }

    private func writeAudio(_ sample: CMSampleBuffer) -> Append {
        guard let receiver = audioReceiver else { return .skipped }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts >= start, !lastAudio.isValid || pts > lastAudio else {
            summary.skipped += 1
            return .skipped
        }
        nonisolated(unsafe) let owned = sample
        let result = attempt { try receiver.appendImmediately(CMReadySampleBuffer(unsafeBuffer: owned)) }
        if result == .written {
            lastAudio = pts
            let stop = pts + CMSampleBufferGetDuration(sample)
            audioEnd = stop
            end = max(end.isValid ? end : stop, stop)
            summary.audioBuffers += 1
        }
        return result
    }

    /// Silent PCM in the format of `sample`, from `from` up to `until`, in
    /// buffers of at most a second
    private static func silence(like sample: CMSampleBuffer, from: CMTime, until: CMTime) -> [CMSampleBuffer] {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mBytesPerFrame > 0, asbd.mSampleRate > 0 else { return [] }
        let rate = CMTimeScale(asbd.mSampleRate)
        var frames = Int(((until - from).seconds * asbd.mSampleRate).rounded())
        var t = from
        var out: [CMSampleBuffer] = []
        while frames > 0 {
            let n = min(frames, Int(rate))
            var size = Int(asbd.mBytesPerFrame)
            guard let block = try? makeBlockBuffer([UInt8](repeating: 0, count: n * size)) else { break }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: rate),
                                            presentationTimeStamp: t, decodeTimeStamp: .invalid)
            var buffer: CMSampleBuffer?
            CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                      sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
            guard let buffer else { break }
            out.append(buffer)
            t = t + CMTime(value: CMTimeValue(n), timescale: rate)
            frames -= n
        }
        return out
    }

    private func attempt(_ append: () throws -> Bool) -> Append {
        do {
            if try append() { return .written }
            if writer.status != .writing {
                fail(writer.error?.localizedDescription ?? String(localized: "The movie couldn't be written."))
                return .failed
            }
            return .notNow
        } catch {
            fail(error.localizedDescription)
            return .failed
        }
    }

    private func fail(_ why: String) {
        if _failure == nil { _failure = why }
    }
}
