// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaCore

public enum StreamEvent: Sendable, Equatable {
    case locked, lockLost, retuning, relocked
}

/// Where a stream's output goes. Callbacks run on the tuner's thread, inside
/// USB event handling, so they must only copy and hand off.
public final class StreamSink: @unchecked Sendable {
    public struct ElementaryStream: Sendable, Equatable {
        public var pid: UInt16
        public var streamType: UInt8
    }

    let packets: @Sendable (Data, UInt32) -> Void
    let program: @Sendable ([ElementaryStream]) -> Void
    let signal: @Sendable (Signal) -> Void
    let tmcc: @Sendable (TMCC) -> Void
    let event: @Sendable (StreamEvent, UInt32) -> Void

    public init(packets: @escaping @Sendable (Data, UInt32) -> Void,
                program: @escaping @Sendable ([ElementaryStream]) -> Void = { _ in },
                signal: @escaping @Sendable (Signal) -> Void = { _ in },
                tmcc: @escaping @Sendable (TMCC) -> Void = { _ in },
                event: @escaping @Sendable (StreamEvent, UInt32) -> Void = { _, _ in }) {
        self.packets = packets
        self.program = program
        self.signal = signal
        self.tmcc = tmcc
        self.event = event
    }
}

/// Holds the device pointer for the one call that may come from any thread
final class CancelHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var device: OpaquePointer?

    func set(_ d: OpaquePointer?) { lock.withLock { device = d } }
    func cancel() { lock.withLock { if let device { mzv_cancel(device) } } }
}

/// The STK8096GP. Every C call runs on this actor's own serial queue, because
/// the core drives the stick through global state from a single thread.
/// Blocking there is fine: it's not the cooperative pool.
public actor TunerService {
    private let queue = DispatchSerialQueue(label: "mzv.tuner", qos: .userInteractive)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var device: OpaquePointer?
    private let cancelHandle = CancelHandle()
    public private(set) var info: DeviceInfo?

    public init() {}

    public var isOpen: Bool { device != nil }

    /// Opens the stick, uploading firmware if it's cold (a few seconds)
    public func open(firmware: URL) throws(TunerError) -> DeviceInfo {
        if let info, device != nil { return info }
        var dev: OpaquePointer?
        let st = mzv_open(firmware.path, &dev)
        guard st == MZV_OK.rawValue, let dev else { throw TunerError(code: st) }
        device = dev
        cancelHandle.set(dev)
        var raw = mzv_device_info()
        mzv_get_info(dev, &raw)
        let i = DeviceInfo(firmwareVersion: raw.firmware_version, firmwareUploaded: raw.firmware_uploaded,
                           demodRevision: raw.demod_revision)
        info = i
        return i
    }

    public func close() {
        guard let device else { return }
        cancelHandle.set(nil)
        mzv_close(device)
        self.device = nil
        info = nil
    }

    /// Makes the current blocking call (stream, scan) return soon; any thread
    public nonisolated func cancel() {
        cancelHandle.cancel()
    }

    private func dev() throws(TunerError) -> OpaquePointer {
        guard let device else { throw TunerError.notOpen }
        mzv_reset_cancel(device)
        return device
    }

    public func tune(rf: Int) throws(TunerError) -> Signal {
        let d = try dev()
        var s = mzv_signal()
        let st = mzv_tune(d, Int32(rf), &s)
        guard st == MZV_OK.rawValue else { throw TunerError(code: st) }
        return Signal(s)
    }

    public func readSignal() throws(TunerError) -> Signal {
        guard let device else { throw TunerError.notOpen }
        var s = mzv_signal()
        mzv_read_signal(device, &s)
        return Signal(s)
    }

    /// Tunes rf and, if it locks, collects its services
    public func scan(rf: Int, psiTimeout: Duration = .seconds(5)) throws(TunerError) -> Mux {
        let d = try dev()
        var m = mzv_mux()
        let ms = UInt32(psiTimeout.components.seconds * 1000 + psiTimeout.components.attoseconds / 1_000_000_000_000_000)
        let st = mzv_scan_rf(d, Int32(rf), ms, &m)
        guard st == MZV_OK.rawValue else { throw TunerError(code: st) }
        return Mux(m)
    }

    /// Streams one service (or the whole mux with serviceID 0) into sink
    /// until cancel(), re-tuning by itself on lock loss. Blocks this actor.
    public func stream(rf: Int, serviceID: UInt16, sink: StreamSink,
                       signalInterval: Duration = .milliseconds(250)) throws(TunerError) {
        let d = try dev()
        var opts = mzv_stream_options()
        opts.rf = Int32(rf)
        opts.service_id = serviceID
        opts.rewrite_pat = true
        opts.signal_interval_ms = UInt32(signalInterval.components.attoseconds / 1_000_000_000_000_000
                                         + signalInterval.components.seconds * 1000)
        opts.skip_tune_if_locked = true

        let box = Unmanaged.passRetained(sink)
        defer { box.release() }
        var cb = mzv_stream_callbacks()
        cb.ctx = box.toOpaque()
        cb.packets = { pkts, count, epoch, ctx in
            let sink = Unmanaged<StreamSink>.fromOpaque(ctx!).takeUnretainedValue()
            sink.packets(Data(bytes: pkts!, count: count * 188), epoch)
            return 0
        }
        cb.program = { prog, ctx in
            let sink = Unmanaged<StreamSink>.fromOpaque(ctx!).takeUnretainedValue()
            let p = prog!.pointee
            let es = withUnsafeBytes(of: p.es) { raw in
                raw.bindMemory(to: mzv_es.self).prefix(Int(p.nes)).map {
                    StreamSink.ElementaryStream(pid: $0.pid, streamType: $0.stream_type)
                }
            }
            sink.program(es)
        }
        cb.signal = { sig, ctx in
            Unmanaged<StreamSink>.fromOpaque(ctx!).takeUnretainedValue().signal(Signal(sig!.pointee))
        }
        cb.tmcc = { t, ctx in
            Unmanaged<StreamSink>.fromOpaque(ctx!).takeUnretainedValue().tmcc(TMCC(t!.pointee))
        }
        cb.event = { ev, epoch, ctx in
            let e: StreamEvent
            switch ev {
            case MZV_EVENT_LOCKED: e = .locked
            case MZV_EVENT_LOCK_LOST: e = .lockLost
            case MZV_EVENT_RETUNING: e = .retuning
            default: e = .relocked
            }
            Unmanaged<StreamSink>.fromOpaque(ctx!).takeUnretainedValue().event(e, epoch)
        }
        let st = mzv_stream(d, &opts, &cb)
        let error = TunerError(code: st)
        if st != MZV_OK.rawValue && error != .cancelled && error != .noLock {
            // unplugged, or in an unknown state: drop the handle so the next
            // open() really reopens (and uploads firmware to a cold stick)
            close()
        }
        guard st == MZV_OK.rawValue else { throw error }
    }
}
