// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes compressed video with VideoToolbox, deinterlaces interlaced frames
/// on the GPU at field rate, and enqueues the pictures to the renderer (or,
/// for exporting, hands them to a callback).
///
/// Compressed samples arrive from the engine's queue; decoded frames come
/// back on VideoToolbox's thread in decode order (it doesn't reorder these
/// B-picture streams), so a small PTS-sorted buffer restores display order
/// before deinterlacing, which needs true temporal neighbours.
final class VideoPipeline: @unchecked Sendable {
    struct Stats: Sendable {
        var decoded = 0
        var decodeErrors = 0
        var output = 0
        var deinterlaced = 0
        var gpuTime: Double = 0         // last field, seconds
        var interlacedSource = false
        var activeMode: DeinterlaceMode = .off
        var backwards = 0   // output PTS lower than the previous one
        var late = 0        // output PTS already behind the renderer's clock
        var minLead = Double.infinity
        var rendererDecodeFailures = 0
        var decoderResets = 0
    }

    /// The synchronizer's receiver for the video renderer; only used on `queue`
    private let receiver: AVSampleBufferVideoRenderer.Receiver?
    private let timebase: CMTimebase?
    /// Instead of a renderer: frames in display order (image, pts, duration), on `queue`
    private let frameSink: ((CVPixelBuffer, CMTime, CMTime) -> Void)?
    /// Called on `queue` once per compressed sample that came back from the decoder
    private let decodedOne: (() -> Void)?
    /// Renderer events (failures), for the engine to watch
    let events: any AsyncSequence<AVSampleBufferVideoRenderer.Receiver.RenderingEvent, Never> & Sendable
    private let queue = DispatchQueue(label: "mzv.video", qos: .userInteractive)
    private let deinterlacer: Deinterlacer?
    private var session: VTDecompressionSession?
    private var sessionFormat: CMVideoFormatDescription?
    private var outputFormats: [String: CMVideoFormatDescription] = [:]

    // guarded by `lock`: read from VideoToolbox's callback thread
    private let lock = NSLock()
    private var generation = 0
    private var _mode: DeinterlaceMode
    private var _needsRestart = false
    private var firstSubmit: UInt64 = 0    // uptime ns, since the last flush/reset
    private var lastSubmit: UInt64 = 0
    private var lastOutput: UInt64 = 0

    // queue-confined
    private typealias Decoded = (image: CVPixelBuffer, pts: CMTime, duration: CMTime)
    private var reorder: [Decoded] = []
    /// Frames held back to restore display order (≥ max_num_reorder_frames)
    private let reorderDepth = 4
    private var history: [(image: CVPixelBuffer, pts: CMTime, duration: CMTime, tff: Bool)] = []
    private var stats = Stats()
    private var lastOutputPTS: CMTime = .invalid

    init(receiver: sending AVSampleBufferVideoRenderer.Receiver, timebase: CMTimebase, mode: DeinterlaceMode) {
        events = receiver.renderingEventsAfterFinishedEnqueuing
        self.receiver = receiver
        self.timebase = timebase
        frameSink = nil
        decodedOne = nil
        _mode = mode
        deinterlacer = try? Deinterlacer()
    }

    /// Offline: frames go to `frames`; `decodedOne` lets the caller bound how
    /// much is in flight
    init(mode: DeinterlaceMode, frames: @escaping (CVPixelBuffer, CMTime, CMTime) -> Void,
         decodedOne: @escaping () -> Void) {
        events = AsyncStream { $0.finish() }
        receiver = nil
        timebase = nil
        frameSink = frames
        self.decodedOne = decodedOne
        _mode = mode
        deinterlacer = try? Deinterlacer()
    }

    var mode: DeinterlaceMode {
        get { lock.withLock { _mode } }
        set {
            let changed = lock.withLock {
                defer { _mode = newValue }
                return (_mode == .decoder) != (newValue == .decoder)
            }
            // the decoder's own deinterlacing is a session property
            if changed { invalidateSession() }
        }
    }

    func currentStats() -> Stats { queue.sync { stats } }

    /// Set when the renderer refused a frame in a way only a restart fixes
    func takeNeedsRestart() -> Bool {
        lock.withLock {
            defer { _needsRestart = false }
            return _needsRestart
        }
    }

    /// Engine-queue watchdog: input keeps going but nothing decodes → new session
    func checkDecoderStall(timeout: Double) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        let t = UInt64(timeout * 1e9)
        let (first, submit, output) = lock.withLock { (firstSubmit, lastSubmit, lastOutput) }
        let since = max(output, first)
        // fed within the timeout, yet nothing out for longer than it
        guard session != nil, first > 0, now - submit < t, now - since >= t else { return false }
        invalidateSession()
        lock.withLock {
            firstSubmit = 0
            lastOutput = 0
        }
        queue.async { self.stats.decoderResets += 1 }
        return true
    }

    /// Decodes one compressed sample (called from the engine's queue)
    func decode(_ sample: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
        if session == nil || !(sessionFormat.map { CMFormatDescriptionEqual($0, otherFormatDescription: format) } ?? false) {
            if let s = session, VTDecompressionSessionCanAcceptFormatDescription(s, formatDescription: format) {
                sessionFormat = format
            } else {
                createSession(format)
            }
        }
        guard let session else { return }
        let gen = lock.withLock {
            lastSubmit = DispatchTime.now().uptimeNanoseconds
            if firstSubmit == 0 { firstSubmit = lastSubmit }
            return generation
        }
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil) {
            [weak self] status, _, image, pts, duration in
            guard let self else { return }
            if status == noErr, image != nil {
                self.lock.withLock { self.lastOutput = DispatchTime.now().uptimeNanoseconds }
            }
            // hop to our queue; drop frames from before the last flush
            queue.async {
                defer { self.decodedOne?() }
                guard gen == self.lock.withLock({ self.generation }) else { return }
                self.decoded(status: status, image: image, pts: pts, duration: duration)
            }
        }
        if st != noErr {
            queue.async {
                self.stats.decodeErrors += 1
                self.decodedOne?()  // may or may not also come back through the handler; over-release only loosens the bound
            }
            if st == kVTInvalidSessionErr { invalidateSession() }
        }
    }

    /// Drops everything in flight (called on restarts)
    func flush() {
        lock.withLock {
            generation += 1
            firstSubmit = 0
            lastSubmit = 0
            lastOutput = 0
        }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        queue.sync {
            receiver?.flush()
            history.removeAll()
            reorder.removeAll()
            lastOutputPTS = .invalid
        }
    }

    /// End of input: waits for the decoder, then pushes out the frames held
    /// back for reordering and deinterlacing
    func finish() {
        if let session {
            VTDecompressionSessionFinishDelayedFrames(session)
            VTDecompressionSessionWaitForAsynchronousFrames(session)
        }
        queue.sync {
            while !reorder.isEmpty {
                let f = reorder.removeFirst()
                display(image: f.image, pts: f.pts, duration: f.duration)
            }
            // YADIF waits for a next frame; the last one uses itself
            let mode = self.mode
            if mode != .bob, mode.kernel != nil, let last = history.last, let deinterlacer {
                let prev = history.count >= 2 ? history[history.count - 2].image : last.image
                emitFields(prev: prev, cur: last, next: last.image, with: deinterlacer, mode: mode)
            }
            history.removeAll()
        }
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        sessionFormat = nil
    }

    private func createSession(_ format: CMVideoFormatDescription) {
        invalidateSession()
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let st = VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                              imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                                              decompressionSessionOut: &s)
        guard st == noErr, let s else { return }
        if mode == .decoder {
            VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_FieldMode,
                                 value: kVTDecompressionProperty_FieldMode_DeinterlaceFields)
        }
        session = s
        sessionFormat = format
    }

    // MARK: - pipeline queue

    private func decoded(status: OSStatus, image: CVImageBuffer?, pts: CMTime, duration: CMTime) {
        guard status == noErr, let image else {
            stats.decodeErrors += 1
            return
        }
        stats.decoded += 1
        // insert by PTS; release the earliest once enough are held
        let at = reorder.firstIndex { $0.pts > pts } ?? reorder.count
        reorder.insert((image, pts, duration), at: at)
        while reorder.count > reorderDepth {
            let f = reorder.removeFirst()
            display(image: f.image, pts: f.pts, duration: f.duration)
        }
    }

    /// Frames in display order
    private func display(image: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        let fields = (CVBufferCopyAttachment(image, kCVImageBufferFieldCountKey, nil) as? NSNumber)?.intValue ?? 1
        let mode = self.mode
        // with .decoder, VideoToolbox has already merged the fields (FieldCount 1)
        if mode == .decoder {
            stats.activeMode = .decoder
        } else if fields == 2, mode.kernel != nil, deinterlacer != nil {
            stats.activeMode = mode == .auto ? .yadif : mode
        } else {
            stats.activeMode = .off
        }
        if fields == 2 { stats.interlacedSource = true }

        guard fields == 2, mode.kernel != nil, let deinterlacer else {
            history.removeAll()
            enqueue(image, pts: pts, duration: duration)
            return
        }

        let detail = CVBufferCopyAttachment(image, kCVImageBufferFieldDetailKey, nil) as? String
        let tff = detail != (kCVImageBufferFieldDetailTemporalBottomFirst as String)
        let dur = duration.isValid ? duration : CMTime(value: 3003, timescale: 90000)
        history.append((image, pts, dur, tff))

        // bob needs no future frame; YADIF emits a frame's fields once the next one arrives
        let needsNext = mode != .bob
        if needsNext {
            guard history.count >= 2 else { return }
            if history.count > 3 { history.removeFirst(history.count - 3) }
            let cur = history[history.count - 2], next = history[history.count - 1]
            let prev = history.count == 3 ? history[0] : cur
            emitFields(prev: prev.image, cur: cur, next: next.image, with: deinterlacer, mode: mode)
        } else {
            let cur = history[history.count - 1]
            history = [cur]
            emitFields(prev: cur.image, cur: cur, next: cur.image, with: deinterlacer, mode: mode)
        }
    }

    private func emitFields(prev: CVPixelBuffer, cur: (image: CVPixelBuffer, pts: CMTime, duration: CMTime, tff: Bool),
                            next: CVPixelBuffer, with d: Deinterlacer, mode: DeinterlaceMode) {
        let half = CMTimeMultiplyByRatio(cur.duration, multiplier: 1, divisor: 2)
        for first in [true, false] {
            guard let out = try? d.field(prev: prev, cur: cur.image, next: next, first: first,
                                         topFieldFirst: cur.tff, mode: mode) else {
                stats.decodeErrors += 1
                continue
            }
            stats.deinterlaced += 1
            stats.gpuTime = d.lastGPUTime
            enqueue(out, pts: first ? cur.pts : cur.pts + half, duration: half)
        }
    }

    private func enqueue(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        if let frameSink {
            if lastOutputPTS.isValid && pts <= lastOutputPTS { stats.backwards += 1 }
            lastOutputPTS = pts
            frameSink(image, pts, duration)
            stats.output += 1
            return
        }
        guard let receiver, let timebase else { return }
        let key = "\(CVPixelBufferGetWidth(image))x\(CVPixelBufferGetHeight(image))"
        var format = outputFormats[key]
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: image) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &f)
            format = f
            outputFormats[key] = f
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if lastOutputPTS.isValid && pts <= lastOutputPTS { stats.backwards += 1 }
        lastOutputPTS = pts
        let now = CMTimebaseGetTime(timebase)
        if CMTimebaseGetRate(timebase) > 0 {
            let lead = (pts - now).seconds
            if lead < 0 { stats.late += 1 }
            stats.minLead = min(stats.minLead, lead)
        }
        // handed over for good: nothing here touches the sample after this
        nonisolated(unsafe) let owned = sample
        switch receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: owned)) {
        case .enqueued, .cancelledDueToFlush:
            break
        case .enqueuedWithDecodeFailures(let errors):
            stats.rendererDecodeFailures += errors.count
        case .cancelledDueToFlushRequiredToResume, .cancelledDueToError:
            lock.withLock { _needsRestart = true }
            return
        @unknown default:
            break
        }
        stats.output += 1
    }
}
