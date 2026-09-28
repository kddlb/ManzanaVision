// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaPlayback
import ManzanaTuner

/// Recordings standing in for the tuner: for developing and testing the app
/// without hardware. Files named like "rf27-….ts" play as RF 27.
public final class RecordingSession: TVSession, @unchecked Sendable {
    public let engine: PlaybackEngine
    public let statusUpdates: AsyncStream<LiveStatus>
    public let signalUpdates: AsyncStream<Signal>
    public let tmccUpdates: AsyncStream<TMCC>
    private let statusC: AsyncStream<LiveStatus>.Continuation
    private let signalC: AsyncStream<Signal>.Continuation
    private let tmccC: AsyncStream<TMCC>.Continuation

    private let recordings: [Int: URL]
    private let lock = NSLock()
    private var _status: LiveStatus = .stopped
    private var source: FileSource?
    private var ticker: Task<Void, Never>?
    private var session: UInt32 = 0
    private var lostUntil: ContinuousClock.Instant?
    private var recorder: TSRecorder?

    /// All "rfNN*.ts" files in a directory (the first per RF wins)
    public init(engine: PlaybackEngine, directory: URL) {
        self.engine = engine
        var found: [Int: URL] = [:]
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch {
            NSLog("RecordingSession: can't list %@: %@", directory.path, "\(error)")
            files = []
        }
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "ts" {
            let name = url.lastPathComponent
            guard name.hasPrefix("rf"), let rf = Int(name.dropFirst(2).prefix { $0.isNumber }) else { continue }
            if found[rf] == nil { found[rf] = url }
        }
        recordings = found
        (statusUpdates, statusC) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (signalUpdates, signalC) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (tmccUpdates, tmccC) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public var status: LiveStatus { lock.withLock { _status } }

    private func publish(_ s: LiveStatus) {
        let changed = lock.withLock {
            defer { _status = s }
            return _status != s
        }
        if changed { statusC.yield(s) }
    }

    public var muxes: [Mux] {
        recordings.keys.sorted().compactMap { rf in try? Mux.fromRecording(recordings[rf]!, rf: rf) }
    }

    public func loadChannels() throws -> [Channel] {
        muxes.flatMap { m in
            m.services.map { Channel(major: $0.major, minor: $0.minor, name: $0.name, kind: $0.kind, rf: m.rf, serviceID: $0.serviceID) }
        }.sorted { ($0.major, $0.minor) < ($1.major, $1.minor) }
    }

    public func play(_ channel: Channel) {
        stopSource()
        guard let url = recordings[channel.rf] else {
            publish(.noSignal(channel))
            return
        }
        publish(.tuning(channel))
        let base = lock.withLock {
            session += 1
            return session << 16
        }
        let src = FileSource(url: url, serviceID: channel.serviceID)
        let engine = self.engine
        src.start(packets: { [self] data, epoch in
                      guard !signalLost else { return }
                      engine.feed(data, epoch: base + epoch)
                      if let r = lock.withLock({ recorder }), r.channel == channel { r.write(data) }
                  },
                  program: { engine.setProgram($0) })
        lock.withLock {
            source = src
            lostUntil = nil
        }
        // a steady synthetic signal, and "playing" once the engine is
        ticker = Task.detached { [self] in
            let signal = Signal(hasSignal: true, hasLock: true, layerLock: channel.isOneSeg ? 0b001 : 0b011,
                                strengthPercent: 70, snr: 24, errorsPerSecond: 0)
            let lost = Signal(hasSignal: true, hasLock: false, layerLock: 0,
                              strengthPercent: 20, snr: 0, errorsPerSecond: 0)
            while !Task.isCancelled {
                if signalLost {
                    signalC.yield(lost)
                    publish(.signalLost(channel))
                } else {
                    signalC.yield(signal)
                    let playing = engine.currentStats().state == .playing
                    switch status {
                    case .tuning, .signalLost: if playing { publish(.playing(channel, .good)) }
                    default: break
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private var signalLost: Bool {
        lock.withLock { lostUntil.map { .now < $0 } ?? false }
    }

    /// Stops the data for a while, as if the antenna were pulled, to see
    /// how the app rides out a dropout
    public func simulateSignalLoss(for duration: Duration) {
        lock.withLock { lostUntil = .now + duration }
    }

    public func setRecorder(_ recorder: TSRecorder?) {
        lock.withLock { self.recorder = recorder }
    }

    private func stopSource() {
        ticker?.cancel()
        lock.withLock {
            source?.stop()
            source = nil
        }
    }

    public func stop() {
        stopSource()
        engine.stop()
        publish(.stopped)
    }

    public func scan(_ rfs: ClosedRange<Int>, psiTimeout: Duration) -> AsyncThrowingStream<ScanProgress, Error> {
        stop()
        return AsyncThrowingStream { cont in
            let job = Task.detached { [self] in
                for rf in rfs {
                    if Task.isCancelled { break }
                    publish(.scanning(rf: rf))
                    cont.yield(.tuning(rf: rf))
                    if let url = recordings[rf], let m = try? Mux.fromRecording(url, rf: rf) {
                        cont.yield(.result(m))
                    }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                cont.yield(.finished(changedMuxes: 0))
                publish(.stopped)
                cont.finish()
            }
            cont.onTermination = { _ in job.cancel() }
        }
    }
}
