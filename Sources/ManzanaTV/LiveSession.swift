// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaPlayback
import ManzanaTuner

/// Everything the GUI needs to say about live TV, in one value
public enum LiveStatus: Sendable, Equatable {
    /// No STK8096GP connected: "Plug in your tuner"
    case noTuner
    /// Another program (e.g. the manzanavision CLI) holds the stick
    case tunerBusy
    case firmwareProblem(String)
    /// Opening the stick (a cold one gets its firmware first)
    case starting
    case tuning(Channel)
    /// Tuned but never locked: "No signal on RF 23"
    case noSignal(Channel)
    /// Was playing; lock or data lost, re-tuning; the picture is frozen
    case signalLost(Channel)
    case playing(Channel, Reception)
    /// Pulled out mid-play; waiting for it to come back
    case disconnected
    /// Scanning for channels (playback stopped)
    case scanning(rf: Int)
    case stopped

    public var channel: Channel? {
        switch self {
        case .tuning(let c), .noSignal(let c), .signalLost(let c), .playing(let c, _): c
        default: nil
        }
    }
}

/// Plays channels from the tuner into a PlaybackEngine, and keeps going
/// through unplug/replug, a busy stick, no signal and signal loss, reporting
/// all of it as LiveStatus.
public final class LiveSession: TVSession, @unchecked Sendable {
    public let engine: PlaybackEngine
    public let tuner: TunerService
    public let monitor: DeviceMonitor
    /// Status changes, newest wins if nobody's listening
    public let statusUpdates: AsyncStream<LiveStatus>
    private let continuation: AsyncStream<LiveStatus>.Continuation
    /// Signal readings (4 Hz while streaming) for meters; only the newest is kept
    public let signalUpdates: AsyncStream<Signal>
    private let signalContinuation: AsyncStream<Signal>.Continuation
    /// Transmission parameters after each lock
    public let tmccUpdates: AsyncStream<TMCC>
    private let tmccContinuation: AsyncStream<TMCC>.Continuation

    private let lock = NSLock()
    private var _status: LiveStatus = .stopped
    private var _signal: Signal?
    private var _deviceInfo: DeviceInfo?
    private var classifier = ReceptionClassifier(oneSeg: false)
    private var task: Task<Void, Never>?
    private var watcher: Task<Void, Never>?
    private var session: UInt32 = 0

    public init(engine: PlaybackEngine, tuner: TunerService = TunerService(), monitor: DeviceMonitor = DeviceMonitor()) {
        self.engine = engine
        self.tuner = tuner
        self.monitor = monitor
        (statusUpdates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
        (signalUpdates, signalContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (tmccUpdates, tmccContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        task?.cancel()
        watcher?.cancel()
        continuation.finish()
        signalContinuation.finish()
        tmccContinuation.finish()
    }

    public var status: LiveStatus { lock.withLock { _status } }
    /// The latest reading (4 Hz while streaming)
    public var signal: Signal? { lock.withLock { _signal } }
    public var deviceInfo: DeviceInfo? { lock.withLock { _deviceInfo } }

    private func publish(_ s: LiveStatus) {
        let changed = lock.withLock {
            defer { _status = s }
            return _status != s
        }
        if changed { continuation.yield(s) }
    }

    /// Starts (or switches to) a channel. Zaps within the same mux skip the re-tune.
    public func play(_ channel: Channel) {
        let previous = lock.withLock { () -> Task<Void, Never>? in
            classifier = ReceptionClassifier(oneSeg: channel.isOneSeg)
            _signal = nil
            return task
        }
        tuner.cancel()
        previous?.cancel()
        let next = Task.detached { [self] in
            await previous?.value
            await run(channel)
        }
        lock.withLock { task = next }
        startWatcher()
    }

    public func loadChannels() throws -> [Channel] {
        try ChannelStore.load()
    }

    public func scan(_ rfs: ClosedRange<Int>, psiTimeout: Duration) -> AsyncThrowingStream<ScanProgress, Error> {
        AsyncThrowingStream { cont in
            let previous = lock.withLock { task }
            tuner.cancel()
            previous?.cancel()
            let job = Task.detached { [self] in
                await previous?.value
                engine.stop()
                do {
                    guard DeviceMonitor.isPresent else { throw TunerError.noDevice }
                    _ = try await tuner.open(firmware: try FirmwareStore.locate())
                    var muxes: [Mux] = []
                    for rf in rfs {
                        try Task.checkCancellation()
                        publish(.scanning(rf: rf))
                        cont.yield(.tuning(rf: rf))
                        let mux = try await tuner.scan(rf: rf, psiTimeout: psiTimeout)
                        muxes.append(mux)
                        cont.yield(.result(mux))
                    }
                    cont.yield(.finished(changedMuxes: try ChannelStore.merge(muxes)))
                    publish(.stopped)
                    cont.finish()
                } catch {
                    publish(.stopped)
                    cont.finish(throwing: error)
                }
            }
            lock.withLock { task = job }
            cont.onTermination = { [self] _ in
                job.cancel()
                tuner.cancel()
            }
        }
    }

    public func stop() {
        let t = lock.withLock { task }
        tuner.cancel()
        t?.cancel()
        watcher?.cancel()
        engine.stop()
        Task.detached { [self] in
            await t?.value
            await tuner.close()
            publish(.stopped)
        }
    }

    /// A frozen picture reads as signal lost even if the tuner still claims lock
    private func startWatcher() {
        guard watcher == nil else { return }
        watcher = Task.detached { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                let stats = engine.currentStats()
                switch status {
                case .playing(let c, _) where stats.state == .stalled:
                    publish(.signalLost(c))
                case .signalLost(let c) where stats.state == .playing:
                    publish(.playing(c, lock.withLock { classifier.reception }))
                default:
                    break
                }
            }
        }
    }

    private func run(_ channel: Channel) async {
        while !Task.isCancelled {
            if !DeviceMonitor.isPresent {
                publish(.noTuner)
                await monitor.waitForArrival()
                try? await Task.sleep(for: .milliseconds(500))  // let it settle
                continue
            }
            do {
                publish(.starting)
                let firmware = try FirmwareStore.locate()
                let info = try await tuner.open(firmware: firmware)
                lock.withLock { _deviceInfo = info }
                try await stream(channel)
                return  // stopped or zapped away
            } catch .gone {
                publish(.disconnected)
                lock.withLock { _signal = nil }
                await monitor.waitForArrival()
                try? await Task.sleep(for: .milliseconds(500))
            } catch .noDevice {
                continue  // loops to the presence check
            } catch .busy {
                publish(.tunerBusy)
                try? await Task.sleep(for: .seconds(2))
            } catch .firmware(let why) {
                publish(.firmwareProblem(why))
                try? await Task.sleep(for: .seconds(5))
            } catch .noLock {
                publish(.noSignal(channel))
                try? await Task.sleep(for: .seconds(2))
            } catch .cancelled {
                return
            } catch {
                // unknown state: the handle was dropped; start over
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func stream(_ channel: Channel) async throws(TunerError) {
        // a new epoch range per stream, so the engine sees each as a discontinuity
        let base = lock.withLock {
            session += 1
            return session << 16
        }
        let engine = self.engine
        let sink = StreamSink(
            packets: { engine.feed($0, epoch: base + $1) },
            program: { es in engine.setProgram(es.map { ProgramStream(pid: $0.pid, streamType: $0.streamType) }) },
            signal: { [self] s in
                let reception = lock.withLock {
                    _signal = s
                    return classifier.update(s)
                }
                signalContinuation.yield(s)
                if case .playing(let c, let r) = status, r != reception { publish(.playing(c, reception)) }
            },
            tmcc: { [self] t in tmccContinuation.yield(t) },
            event: { [self] e, _ in
                switch e {
                case .locked, .relocked:
                    publish(.playing(channel, lock.withLock { classifier.reception }))
                case .lockLost, .retuning:
                    publish(.signalLost(channel))
                }
            })
        publish(.tuning(channel))
        try await tuner.stream(rf: channel.rf, serviceID: channel.serviceID, sink: sink)
    }
}
