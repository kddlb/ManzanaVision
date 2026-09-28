// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaCore

public enum TunerError: Error, Sendable, Equatable {
    case noDevice
    case busy
    case firmware(String)
    case io
    case noFrontend
    case cancelled
    case noLock
    case gone
    case invalid
    case notOpen

    init(code: Int32) {
        switch code {
        case MZV_ERR_NO_DEVICE.rawValue: self = .noDevice
        case MZV_ERR_BUSY.rawValue: self = .busy
        case MZV_ERR_FIRMWARE.rawValue: self = .firmware("rejected by the tuner")
        case MZV_ERR_NO_FRONTEND.rawValue: self = .noFrontend
        case MZV_ERR_CANCELLED.rawValue: self = .cancelled
        case MZV_ERR_NO_LOCK.rawValue: self = .noLock
        case MZV_ERR_GONE.rawValue: self = .gone
        case MZV_ERR_INVALID.rawValue: self = .invalid
        default: self = .io
        }
    }
}

public struct DeviceInfo: Sendable, Equatable {
    public var firmwareVersion: UInt32
    public var firmwareUploaded: Bool
    public var demodRevision: UInt16
}

public struct Signal: Sendable, Equatable {
    public var hasSignal: Bool
    public var hasLock: Bool
    /// MPEG lock per layer: bit 0 = A, 1 = B, 2 = C
    public var layerLock: UInt8
    public var strengthPercent: Int
    public var snr: Double          // dB
    public var errorsPerSecond: Double

    public init(hasSignal: Bool, hasLock: Bool, layerLock: UInt8, strengthPercent: Int, snr: Double,
                errorsPerSecond: Double) {
        self.hasSignal = hasSignal
        self.hasLock = hasLock
        self.layerLock = layerLock
        self.strengthPercent = strengthPercent
        self.snr = snr
        self.errorsPerSecond = errorsPerSecond
    }

    init(_ s: mzv_signal) {
        hasSignal = s.has_signal
        hasLock = s.has_lock
        layerLock = s.layer_lock
        strengthPercent = Int(s.strength_pct)
        snr = s.snr_db
        errorsPerSecond = s.errors_per_s
    }

    public func layerLocked(_ layer: Int) -> Bool { layerLock >> layer & 1 == 1 }
}

public struct TMCC: Sendable, Equatable {
    public struct Layer: Sendable, Equatable {
        public var segments: Int
        public var modulation: String
        public var codeRate: String
        public var interleaving: Int
    }
    public var mode: Int
    public var guardInterval: String
    public var layers: [Layer]  // A, B, C (segments == 0 when unused)

    init(_ t: mzv_tmcc) {
        mode = Int(t.mode)
        guardInterval = String(cString: mzv_guard_interval_name(t.guard_interval))
        layers = withUnsafeBytes(of: t.layer) { raw in
            raw.bindMemory(to: mzv_layer.self).map {
                Layer(segments: Int($0.segments), modulation: String(cString: mzv_modulation_name($0.modulation)),
                      codeRate: String(cString: mzv_code_rate_name($0.fec)), interleaving: Int($0.interleaving))
            }
        }
    }
}

func string<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

public struct Service: Sendable, Equatable, Hashable {
    public var serviceID: UInt16
    public var pmtPID: UInt16
    public var major: Int
    public var minor: Int
    public var kind: String
    public var name: String
    public var virtual: String { "\(major).\(minor)" }
}

public struct Mux: Sendable, Equatable {
    public var rf: Int
    public var frequency: UInt32
    public var signal: Signal
    public var tmcc: TMCC?
    public var hasPAT: Bool
    public var networkName: String
    public var tsName: String
    public var services: [Service]  // the listed ones
    /// The C struct, for merging into the channel list
    let raw: mzv_mux

    init(_ m: mzv_mux) {
        raw = m
        rf = Int(m.rf)
        frequency = m.frequency
        signal = Signal(m.signal)
        tmcc = m.have_tmcc ? TMCC(m.tmcc) : nil
        hasPAT = m.have_pat
        networkName = string(m.network_name)
        tsName = string(m.ts_name)
        services = withUnsafeBytes(of: m.services) { raw in
            raw.bindMemory(to: mzv_service.self).prefix(Int(m.nservices)).filter(\.listed).map {
                Service(serviceID: $0.service_id, pmtPID: $0.pmt_pid, major: Int($0.major), minor: Int($0.minor),
                        kind: string($0.kind), name: string($0.name))
            }
        }
    }

    /// The services of a recording (PSI from its first 16 MB); no signal or TMCC
    public static func fromRecording(_ url: URL, rf: Int) throws -> Mux {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = handle.readData(ofLength: 16 << 20)
        var m = mzv_mux()
        data.withUnsafeBytes { raw in
            mzv_mux_from_packets(raw.bindMemory(to: UInt8.self).baseAddress, data.count / 188, Int32(rf), &m)
        }
        m.signal.has_lock = true
        m.signal.has_signal = true
        return Mux(m)
    }

    public static func == (a: Mux, b: Mux) -> Bool {
        a.rf == b.rf && a.signal == b.signal && a.services == b.services && a.tmcc == b.tmcc
    }
}

/// A saved channel
public struct Channel: Sendable, Equatable, Hashable, Identifiable, Codable {
    public var major: Int
    public var minor: Int
    public var name: String
    public var kind: String
    public var rf: Int
    public var serviceID: UInt16
    public var id: String { "\(rf):\(serviceID)" }
    public var virtual: String { "\(major).\(minor)" }
    public var isOneSeg: Bool { kind == "1seg" }

    public init(major: Int, minor: Int, name: String, kind: String, rf: Int, serviceID: UInt16) {
        self.major = major
        self.minor = minor
        self.name = name
        self.kind = kind
        self.rf = rf
        self.serviceID = serviceID
    }
}

/// The channel list shared with the CLI (channels.tsv)
public enum ChannelStore {
    public static var defaultURL: URL { URL(fileURLWithPath: String(cString: mzv_channels_default_path())) }

    public static func load(from url: URL = defaultURL) throws(TunerError) -> [Channel] {
        var list = mzv_channel_list()
        defer { mzv_channels_free(&list) }
        let st = mzv_channels_load(url.path, &list)
        guard st == MZV_OK.rawValue else { throw TunerError(code: st) }
        return (0..<Int(list.count)).map {
            let c = list.items[$0]
            return Channel(major: Int(c.major), minor: Int(c.minor), name: string(c.name), kind: string(c.kind),
                           rf: Int(c.rf), serviceID: c.service_id)
        }
    }

    /// Merges scan results (same rules as `manzanavision scan`) and saves
    @discardableResult
    public static func merge(_ muxes: [Mux], into url: URL = defaultURL) throws(TunerError) -> Int {
        var list = mzv_channel_list()
        defer { mzv_channels_free(&list) }
        var st = mzv_channels_load(url.path, &list)
        guard st == MZV_OK.rawValue else { throw TunerError(code: st) }
        var changed = 0
        for m in muxes {
            var raw = m.raw
            if mzv_channels_merge_mux(&list, &raw) { changed += 1 }
        }
        if changed > 0 {
            st = mzv_channels_save(url.path, &list)
            guard st == MZV_OK.rawValue else { throw TunerError(code: st) }
        }
        return changed
    }
}
