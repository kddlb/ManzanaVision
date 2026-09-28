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
    public enum State: String, Sendable { case idle, buffering, playing }
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
    /// How far ahead of the playback clock the newest enqueued samples are
    public var videoBuffer: Double = 0
    public var audioBuffer: Double = 0
    public var videoSize: CGSize = .zero
    public var interlaced = false
    public var audioDescription = ""
}

/// Demuxes one program's TS, decodes audio, and feeds the video/audio
/// renderers under a shared synchronizer. All work runs on a private serial
/// queue; the public methods are safe from any thread.
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

    private let queue = DispatchQueue(label: "mzv.playback", qos: .userInteractive)
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
    private var stats = PlaybackStats()

    public init(videoRenderer: AVSampleBufferVideoRenderer) {
        self.videoRenderer = videoRenderer
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
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
            if self.epoch != epoch {
                self.epoch = epoch
                stats.epoch = epoch
                restart()
            }
            checkRenderers()
            packets.withUnsafeBytes { raw in
                demux.feed(raw) { handle($0) }
            }
            stats.continuityErrors = demux.stats.continuityErrors
            if state == .buffering { maybeStart() }
        }
    }

    public func currentStats() -> PlaybackStats {
        queue.sync {
            var s = stats
            s.state = state
            let now = synchronizer.currentTime()
            if state == .playing {
                if lastVideoEnd.isValid { s.videoBuffer = (lastVideoEnd - now).seconds }
                if lastAudioEnd.isValid { s.audioBuffer = (lastAudioEnd - now).seconds }
            }
            s.audioConcealed = audioDecoder.concealed
            s.audioReanchors = audioDecoder.reanchors
            return s
        }
    }

    public func stop() {
        queue.sync {
            synchronizer.setRate(0, time: .zero)
            videoRenderer.flush()
            audioRenderer.flush()
            state = .idle
        }
    }

    // MARK: - queue-confined

    /// Drops everything in flight and waits for a fresh start point
    private func restart() {
        synchronizer.setRate(0, time: synchronizer.currentTime())
        videoRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        audioRenderer.flush()
        demux.reset()
        h264.reset()
        aac.reset()
        audioDecoder.reset()
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        lastVideoEnd = .invalid
        lastAudioEnd = .invalid
        haveSync = false
        if state == .playing { stats.restarts += 1 }
        state = .buffering
    }

    private func checkRenderers() {
        guard state == .playing else { return }
        if videoRenderer.status == .failed || videoRenderer.requiresFlushToResumeDecoding
            || audioRenderer.status == .failed {
            stats.videoErrors += 1
            restart()
        }
    }

    private func handle(_ event: DemuxEvent) {
        guard case .pes(let pes) = event else { return }
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
                enqueue(video: sb)
            }
        } else if pes.pid == audioPID {
            for frame in aac.feed(pes) {
                guard let sb = try? audioDecoder.decode(frame) else { continue }
                if stats.audioDescription.isEmpty || stats.audioFrames % 500 == 0 {
                    let c = AudioDecoder.effectiveConfig(frame.config)
                    stats.audioDescription = "\(c.ps ? "HE-AACv2" : c.sbr ? "HE-AAC" : "AAC-LC") \(c.outputSampleRate) Hz \(c.channels) ch"
                }
                enqueue(audio: sb)
            }
        }
    }

    private func enqueue(video sb: CMSampleBuffer) {
        stats.videoFrames += 1
        let end = CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb)
        if end.isValid, !lastVideoEnd.isValid || end > lastVideoEnd { lastVideoEnd = end }
        if state == .playing {
            videoRenderer.enqueue(sb)
        } else {
            pendingVideo.append(sb)
        }
    }

    private func enqueue(audio sb: CMSampleBuffer) {
        stats.audioFrames += 1
        lastAudioEnd = CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb)
        if state == .playing {
            audioRenderer.enqueue(sb)
        } else {
            pendingAudio.append(sb)
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
        for sb in pendingVideo { videoRenderer.enqueue(sb) }
        for sb in pendingAudio where CMSampleBufferGetPresentationTimeStamp(sb) + CMSampleBufferGetDuration(sb) > start {
            audioRenderer.enqueue(sb)
        }
        pendingVideo.removeAll()
        pendingAudio.removeAll()
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        synchronizer.setRate(1, time: start, atHostTime: hostNow + CMTime(seconds: latency, preferredTimescale: 1_000_000))
        state = .playing
    }
}
