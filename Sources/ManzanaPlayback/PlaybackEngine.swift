// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ManzanaStream

/// An elementary stream of the program being played
public struct ProgramStream: Sendable, Equatable {
    public var pid: UInt16
    public var streamType: UInt8
    public init(pid: UInt16, streamType: UInt8) {
        self.pid = pid
        self.streamType = streamType
    }
    public var isVideo: Bool { streamType == 0x1b }
    public var isAudio: Bool { streamType == 0x0f || streamType == 0x11 }
}

public struct PlaybackStats: Sendable, Equatable {
    public enum State: String, Sendable {
        case idle
        case buffering  // waiting for a start point
        case playing
        case stalled    // no data: showing the last picture
    }
    public var state: State = .idle
    public var epoch: UInt32 = 0
    public var videoFrames = 0
    public var audioFrames = 0
    public var videoSkippedBeforeSync = 0
    public var videoErrors = 0
    public var audioConcealed = 0
    public var audioReanchors = 0
    public var continuityErrors = 0
    public var restarts = 0
    public var stalls = 0
    public var ptsJumps = 0
    public var rendererFailures = 0
    public var decoderResets = 0
    public var rebuffers = 0
    public var rate: Float = 0
    /// How far ahead of the playback clock the newest enqueued samples are
    public var videoBuffer: Double = 0
    public var audioBuffer: Double = 0
    public var videoSize: CGSize = .zero
    public var interlaced = false
    public var audioDescription = ""
    public var deinterlace: DeinterlaceMode = .off  // what's being applied now
    public var decodedFrames = 0
    public var outputFrames = 0
    public var decodeErrors = 0
    public var deinterlaceGPUms: Double = 0
    public var outputBackwards = 0
    public var outputLate = 0
    public var outputMinLead: Double = 0

    public init() {}
}

/// Demuxes one program's TS, decodes it, and feeds the video/audio renderers
/// under a shared synchronizer, recovering from gaps, jumps, stalls and
/// renderer failures on its own. All work runs on a private serial queue;
/// the public methods are safe from any thread.
public final class PlaybackEngine: @unchecked Sendable {
    public let synchronizer = AVSampleBufferRenderSynchronizer()
    public let videoRenderer: AVSampleBufferVideoRenderer
    public let audioRenderer = AVSampleBufferAudioRenderer()

    /// Audio that must be queued past the start point before the clock starts
    public var startupAudio = 0.4
    /// The clock starts this long after the start conditions are met, so
    /// renderers keep a cushion against jitter and just-in-time muxing
    public var latency = 0.5
    /// Video-only services start once this much is queued
    public var startupVideo = 0.5
    /// Buffer depth the drift controller keeps playback within, in seconds
    public var bufferBand: ClosedRange<Double> = 0.4...2.0
    /// Drift control waits this long after a start, while the buffer settles
    public var driftSettle = 5.0
    /// No data for this long while playing → stalled
    public var stallTimeout = 1.5
    /// Timestamps moving more than this within an epoch → restart
    public var jumpThreshold = 2.0

    private let queue = DispatchQueue(label: "mzv.playback", qos: .userInteractive)
    /// The synchronizer's audio receiver; only used on `queue`
    private let audioReceiver: AVSampleBufferAudioRenderer.Receiver
    private let video: VideoPipeline
    private var timer: DispatchSourceTimer?
    private var eventTasks: [Task<Void, Never>] = []

    private var streams: [ProgramStream] = []
    private var videoPID: UInt16?
    private var audioPID: UInt16?
    private var demux = TSDemuxer(pids: [UInt16]())
    private var h264 = H264Assembler()
    private var aac = AACStreamParser()
    private var factory = VideoSampleFactory()
    private let audioDecoder = AudioDecoder()
    private var epoch: UInt32?
    private var state = PlaybackStats.State.idle
    private var haveSync = false
    private var pendingVideo: [CMSampleBuffer] = []
    private var pendingAudio: [CMSampleBuffer] = []
    private var lastVideoEnd: CMTime = .invalid
    private var lastAudioEnd: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var lastFeed: UInt64 = 0          // uptime ns of the last packets
    private var playingSince: UInt64 = 0
    private var restartRequested = false
    private var drift: Float = 1              // current rate nudge
    private var stats = PlaybackStats()

    public init(videoRenderer: AVSampleBufferVideoRenderer, deinterlace: DeinterlaceMode = .auto) {
        self.videoRenderer = videoRenderer
        audioRenderer.audioTimePitchAlgorithm = .spectral  // rate nudges keep the pitch
        video = VideoPipeline(receiver: synchronizer.sampleBufferReceiver(adding: videoRenderer),
                              timebase: synchronizer.timebase, mode: deinterlace)
        audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)

        let videoEvents = video.events
        let audioEvents = audioReceiver.renderingEventsAfterFinishedEnqueuing
        eventTasks = [
            Task { [weak self] in
                for await event in videoEvents {
                    guard case .didFailToDecode = event else {
                        self?.queue.async { self?.rendererFailed() }
                        continue
                    }
                }
            },
            Task { [weak self] in
                for await event in audioEvents {
                    if case .failed = event { self?.queue.async { self?.rendererFailed() } }
                }
            },
        ]

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.housekeeping() }
        t.resume()
        timer = t
    }

    deinit {
        timer?.cancel()
        eventTasks.forEach { $0.cancel() }
    }

    /// The program's elementary streams (from its PMT). Plays the first
    /// video and first audio stream.
    public func setProgram(_ streams: [ProgramStream]) {
        queue.async { [self] in
            guard streams != self.streams else { return }
            self.streams = streams
            videoPID = streams.first(where: \.isVideo)?.pid
            audioPID = streams.first(where: \.isAudio)?.pid
            demux.setPIDs([videoPID, audioPID].compactMap { $0 }, pcrPID: nil)
            restart()
        }
    }

    /// Packets of the program; a new epoch means a discontinuity (re-tune, zap, loop)
    public func feed(_ packets: Data, epoch: UInt32) {
        queue.async { [self] in
            lastFeed = DispatchTime.now().uptimeNanoseconds
            if self.epoch != epoch {
                self.epoch = epoch
                stats.epoch = epoch
                restart()
            } else if state == .stalled {
                restart()  // data is back after a gap: start clean
            }
            packets.withUnsafeBytes { raw in
                demux.feed(raw) { handle($0) }
            }
            stats.continuityErrors = demux.stats.continuityErrors
            if restartRequested {
                restartRequested = false
                restart()
            }
            if state == .buffering { maybeStart() }
        }
    }

    /// Deinterlacing for interlaced sources; takes effect on the next frame
    public var deinterlace: DeinterlaceMode {
        get { video.mode }
        set { queue.async { self.video.mode = newValue } }
    }

    public func currentStats() -> PlaybackStats {
        let v = video.currentStats()
        return queue.sync {
            var s = stats
            s.deinterlace = v.activeMode
            s.decodedFrames = v.decoded
            s.outputFrames = v.output
            s.decodeErrors = v.decodeErrors
            s.deinterlaceGPUms = v.gpuTime * 1000
            s.outputBackwards = v.backwards
            s.outputLate = v.late
            s.outputMinLead = v.minLead
            s.decoderResets = v.decoderResets
            if v.interlacedSource { s.interlaced = true }
            s.state = state
            s.rate = state == .playing ? drift : 0
            (s.videoBuffer, s.audioBuffer) = buffers()
            s.audioConcealed = audioDecoder.concealed
            s.audioReanchors = audioDecoder.reanchors
            return s
        }
    }

    public func stop() {
        queue.sync {
            synchronizer.setRate(0, time: .zero)
            video.flush()
            audioReceiver.flush()
            state = .idle
        }
    }

    // MARK: - queue-confined

    private func buffers() -> (video: Double, audio: Double) {
        guard state == .playing else { return (0, 0) }
        let now = synchronizer.currentTime()
        return (lastVideoEnd.isValid ? (lastVideoEnd - now).seconds : 0,
                lastAudioEnd.isValid ? (lastAudioEnd - now).seconds : 0)
    }

    /// Drops everything in flight and waits for a fresh start point
    private func restart() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
        video.flush()  // keeps the last picture on screen
        audioReceiver.flush()
        demux.reset()
        h264.reset()
        aac.reset()
        audioDecoder.reset()
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        lastVideoEnd = .invalid
        lastAudioEnd = .invalid
        lastVideoPTS = .invalid
        haveSync = false
        drift = 1
        if state == .playing || state == .stalled { stats.restarts += 1 }
        state = .buffering
    }

    private func rendererFailed() {
        stats.rendererFailures += 1
        if state == .playing { restart() }
    }

    /// Every 250 ms: stall detection, decoder watchdog, drift control
    private func housekeeping() {
        guard state == .playing else { return }
        let now = DispatchTime.now().uptimeNanoseconds

        if Double(now - lastFeed) / 1e9 > stallTimeout {
            // freeze on the last picture until data returns
            synchronizer.setRate(0, time: synchronizer.currentTime())
            state = .stalled
            stats.stalls += 1
            return
        }
        if video.takeNeedsRestart() {
            rendererFailed()
            return
        }
        _ = video.checkDecoderStall(timeout: 2)

        // keep the buffer inside the band by nudging the rate (pitch preserved)
        guard Double(now - playingSince) / 1e9 >= driftSettle else { return }
        let (vb, ab) = buffers()
        let depth = audioPID != nil ? ab : vb
        // underrun while data still arrives → rebuffer; if data stopped, the
        // stall check above takes over (so the UI can say "signal lost")
        let feeding = Double(now - lastFeed) / 1e9 < 0.5
        if depth > bufferBand.upperBound + 2 || (depth < -0.25 && feeding) {
            // hopelessly behind live, or run dry: rebuffer from a fresh start point
            stats.rebuffers += 1
            restart()
            return
        }
        // outside the band: speed up/slow down in proportion to the error, up
        // to ±1%; back to 1.0 once the buffer is back at the middle
        let mid = (bufferBand.lowerBound + bufferBand.upperBound) / 2
        var target = drift
        if depth > bufferBand.upperBound || depth < bufferBand.lowerBound {
            target = 1 + Float(max(-0.01, min(0.01, 0.005 * (depth - mid))))
        } else if (drift > 1 && depth <= mid) || (drift < 1 && depth >= mid) {
            target = 1
        }
        if abs(target - drift) >= 0.0005 || (target == 1 && drift != 1) {
            drift = target
            synchronizer.rate = drift
        }
    }

    private func handle(_ event: DemuxEvent) {
        guard case .pes(let pes) = event, !restartRequested else { return }
        if pes.pid == videoPID {
            for frame in h264.feed(pes) {
                if !haveSync {
                    guard frame.isSyncPoint else {
                        stats.videoSkippedBeforeSync += 1
                        continue
                    }
                    haveSync = true
                }
                stats.interlaced = frame.interlaced
                stats.videoSize = CGSize(width: frame.sps.width, height: frame.sps.height)
                guard let sb = try? factory.sampleBuffer(for: frame) else {
                    stats.videoErrors += 1
                    continue
                }
                if jumped(CMSampleBufferGetPresentationTimeStamp(sb)) { return }
                enqueue(video: sb)
            }
        } else if pes.pid == audioPID {
            for frame in aac.feed(pes) {
                guard let sb = try? audioDecoder.decode(frame) else { continue }
                if videoPID == nil, jumped(CMSampleBufferGetPresentationTimeStamp(sb)) { return }
                if stats.audioDescription.isEmpty || stats.audioFrames % 500 == 0 {
                    let c = AudioDecoder.effectiveConfig(frame.config)
                    stats.audioDescription = "\(c.ps ? "HE-AACv2" : c.sbr ? "HE-AAC" : "AAC-LC") \(c.outputSampleRate) Hz \(c.channels) ch"
                }
                enqueue(audio: sb)
            }
        }
    }

    /// A timestamp far from the last one (in either direction) within an
    /// epoch means the source jumped; restart after this batch
    private func jumped(_ pts: CMTime) -> Bool {
        defer { if !restartRequested { lastVideoPTS = pts } }
        guard pts.isValid, lastVideoPTS.isValid,
              abs((pts - lastVideoPTS).seconds) > jumpThreshold else { return false }
        stats.ptsJumps += 1
        restartRequested = true
        return true
    }

    private func enqueue(video sb: CMSampleBuffer) {
        stats.videoFrames += 1
        let end = CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb)
        if end.isValid, !lastVideoEnd.isValid || end > lastVideoEnd { lastVideoEnd = end }
        if state == .playing {
            video.decode(sb)
        } else {
            pendingVideo.append(sb)
        }
    }

    private func enqueue(audio sb: CMSampleBuffer) {
        stats.audioFrames += 1
        lastAudioEnd = CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb)
        if state == .playing {
            enqueueAudio(sb)
        } else {
            pendingAudio.append(sb)
        }
    }

    private func enqueueAudio(_ sb: CMSampleBuffer) {
        // handed over for good: nothing here touches the sample after this
        nonisolated(unsafe) let owned = sb
        switch audioReceiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: owned)) {
        case .cancelledDueToError:
            restartRequested = true
        default:
            break
        }
    }

    /// Starts the clock once a video sync point and enough audio are queued
    private func maybeStart() {
        let hasVideo = videoPID != nil, hasAudio = audioPID != nil
        let firstVideo = pendingVideo.first.map(CMSampleBufferGetPresentationTimeStamp)
        let firstAudio = pendingAudio.first.map(CMSampleBufferGetPresentationTimeStamp)
        if hasVideo && firstVideo == nil { return }
        // audio before the start point is dropped, so count what lies past it
        let from = firstVideo ?? firstAudio ?? .zero
        let audioQueued = firstAudio != nil && lastAudioEnd.isValid ? (lastAudioEnd - from).seconds : 0
        let videoQueued = firstVideo.map { lastVideoEnd.isValid ? (lastVideoEnd - $0).seconds : 0 } ?? 0

        if hasAudio && audioQueued < startupAudio && !(hasVideo && videoQueued > 2) { return }
        if !hasAudio && videoQueued < startupVideo { return }

        // start on the video sync point; audio before it would only play early
        let start = firstVideo ?? firstAudio ?? .zero
        synchronizer.setRate(0, time: start)
        for sb in pendingVideo { video.decode(sb) }
        for sb in pendingAudio where CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb) > start {
            enqueueAudio(sb)
        }
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        synchronizer.setRate(1, time: start, atHostTime: hostNow + CMTime(seconds: latency, preferredTimescale: 1_000_000))
        drift = 1
        lastFeed = DispatchTime.now().uptimeNanoseconds
        playingSince = lastFeed
        state = .playing
    }
}
