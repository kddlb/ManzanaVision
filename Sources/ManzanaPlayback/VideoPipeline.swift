// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

/// Decodes compressed video with VideoToolbox, deinterlaces interlaced frames
/// on the GPU at field rate, and enqueues the pictures to the renderer.
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
    }

    private let renderer: AVSampleBufferVideoRenderer
    private let queue = DispatchQueue(label: "mzv.video", qos: .userInteractive)
    private let deinterlacer: Deinterlacer?
    private var session: VTDecompressionSession?
    private var sessionFormat: CMVideoFormatDescription?
    private var outputFormats: [String: CMVideoFormatDescription] = [:]

    // guarded by `lock`: read from VideoToolbox's callback thread
    private let lock = NSLock()
    private var generation = 0
    private var _mode: DeinterlaceMode

    // queue-confined
    private typealias Decoded = (image: CVPixelBuffer, pts: CMTime, duration: CMTime)
    private var reorder: [Decoded] = []
    /// Frames held back to restore display order (≥ max_num_reorder_frames)
    private let reorderDepth = 4
    private var history: [(image: CVPixelBuffer, pts: CMTime, duration: CMTime, tff: Bool)] = []
    private var stats = Stats()
    private var lastOutputPTS: CMTime = .invalid

    init(renderer: AVSampleBufferVideoRenderer, mode: DeinterlaceMode) {
        self.renderer = renderer
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
        let gen = lock.withLock { generation }
        let flags: VTDecodeFrameFlags = [._EnableAsynchronousDecompression, ._EnableTemporalProcessing]
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags, infoFlagsOut: nil) {
            [weak self] status, _, image, pts, duration in
            guard let self else { return }
            // hop to our queue; drop frames from before the last flush
            queue.async {
                guard gen == self.lock.withLock({ self.generation }) else { return }
                self.decoded(status: status, image: image, pts: pts, duration: duration)
            }
        }
        if st != noErr {
            queue.async { self.stats.decodeErrors += 1 }
            if st == kVTInvalidSessionErr { invalidateSession() }
        }
    }

    /// Drops everything in flight (called on restarts)
    func flush() {
        lock.withLock { generation += 1 }
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        queue.sync {
            history.removeAll()
            reorder.removeAll()
            lastOutputPTS = .invalid
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
        let now = CMTimebaseGetTime(renderer.timebase)
        if CMTimebaseGetRate(renderer.timebase) > 0 {
            let lead = (pts - now).seconds
            if lead < 0 { stats.late += 1 }
            stats.minLead = min(stats.minLead, lead)
        }
        renderer.enqueue(sample)
        stats.output += 1
    }
}
