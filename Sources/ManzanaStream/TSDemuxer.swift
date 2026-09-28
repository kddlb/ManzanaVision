// SPDX-License-Identifier: GPL-2.0-only

public let tsPacketSize = 188

/// One PES packet, reassembled from TS packets
public struct PESPacket: Sendable {
    public var pid: UInt16
    public var streamID: UInt8
    public var pts: UInt64?          // 33-bit, 90 kHz, as transmitted
    public var dts: UInt64?
    public var payload: [UInt8]      // elementary stream bytes
    /// A continuity gap, transport error or truncation hit this PES
    public var damaged: Bool
    /// The adaptation field flagged a discontinuity or random access at its start
    public var discontinuity: Bool
    public var randomAccess: Bool
}

public enum DemuxEvent: Sendable {
    case pes(PESPacket)
    /// 27 MHz program clock reference
    case pcr(pid: UInt16, value: UInt64, discontinuity: Bool)
}

/// Statistics the HUD shows
public struct DemuxStats: Sendable, Equatable {
    public var packets = 0
    public var continuityErrors = 0
    public var transportErrors = 0
    public var droppedPES = 0
}

/// Reassembles PES for a set of PIDs, tracking continuity per PID.
public struct TSDemuxer {
    private struct PIDState {
        var cc: Int = -1
        var buffer: [UInt8] = []
        var collecting = false      // a PES start has been seen
        var damaged = false
        var discontinuity = false
        var randomAccess = false
        var expectedLength = 0      // PES_packet_length + 6, 0 = unbounded
    }

    private var states: [UInt16: PIDState] = [:]
    public private(set) var pcrPID: UInt16?
    public private(set) var stats = DemuxStats()

    public init(pids: some Sequence<UInt16>, pcrPID: UInt16? = nil) {
        for pid in pids { states[pid] = PIDState() }
        self.pcrPID = pcrPID
    }

    public mutating func setPIDs(_ pids: some Sequence<UInt16>, pcrPID: UInt16?) {
        var next: [UInt16: PIDState] = [:]
        for pid in pids { next[pid] = states[pid] ?? PIDState() }
        states = next
        self.pcrPID = pcrPID
    }

    /// Drops partial PES and continuity history (use on epoch changes)
    public mutating func reset() {
        for pid in states.keys { states[pid] = PIDState() }
    }

    public mutating func feed(_ packets: UnsafeRawBufferPointer, emit: (DemuxEvent) -> Void) {
        var off = 0
        while off + tsPacketSize <= packets.count {
            feed(packet: UnsafeRawBufferPointer(rebasing: packets[off..<off + tsPacketSize]), emit: emit)
            off += tsPacketSize
        }
    }

    public mutating func feed(_ packets: [UInt8], emit: (DemuxEvent) -> Void) {
        packets.withUnsafeBytes { feed($0, emit: emit) }
    }

    /// Emits whatever is still buffered (end of input)
    public mutating func flush(emit: (DemuxEvent) -> Void) {
        for pid in Array(states.keys) {
            finish(pid: pid, truncated: false, emit: emit)
        }
    }

    private mutating func feed(packet p: UnsafeRawBufferPointer, emit: (DemuxEvent) -> Void) {
        guard p[0] == 0x47 else { return }
        stats.packets += 1
        let pid = UInt16(p[1] & 0x1f) << 8 | UInt16(p[2])
        let tei = p[1] & 0x80 != 0
        let pusi = p[1] & 0x40 != 0
        let afc = Int(p[3] >> 4) & 3
        let cc = Int(p[3] & 0x0f)
        var off = 4
        var discontinuity = false
        var randomAccess = false

        if afc & 2 != 0 {
            let afLength = Int(p[4])
            if afLength > 0 && 5 + afLength <= tsPacketSize {
                let flags = p[5]
                discontinuity = flags & 0x80 != 0
                randomAccess = flags & 0x40 != 0
                if flags & 0x10 != 0, afLength >= 7, pid == pcrPID {
                    let base = UInt64(p[6]) << 25 | UInt64(p[7]) << 17 | UInt64(p[8]) << 9
                        | UInt64(p[9]) << 1 | UInt64(p[10]) >> 7
                    let ext = UInt64(p[10] & 1) << 8 | UInt64(p[11])
                    emit(.pcr(pid: pid, value: base * 300 + ext, discontinuity: discontinuity))
                }
            }
            off += 1 + afLength
        }

        guard var st = states[pid] else { return }
        defer { states[pid] = st }

        if tei {
            stats.transportErrors += 1
            st.damaged = true
            return
        }
        guard afc & 1 != 0, off < tsPacketSize else {
            // no payload: CC doesn't advance
            return
        }

        if st.cc >= 0 {
            if cc == st.cc {
                return  // duplicate packet
            }
            if cc != (st.cc + 1) & 0x0f && !discontinuity {
                stats.continuityErrors += 1
                st.damaged = true
            }
        }
        st.cc = cc

        if pusi {
            states[pid] = st
            finish(pid: pid, truncated: true, emit: emit)
            st = states[pid]!
            st.buffer.removeAll(keepingCapacity: true)
            st.collecting = true
            st.damaged = false
            st.discontinuity = discontinuity
            st.randomAccess = randomAccess
            st.expectedLength = 0
        } else if !st.collecting {
            return  // mid-PES and we never saw its start
        }

        st.buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: p[off..<tsPacketSize]))
        if st.expectedLength == 0, st.buffer.count >= 6 {
            let len = Int(st.buffer[4]) << 8 | Int(st.buffer[5])
            st.expectedLength = len == 0 ? -1 : len + 6
        }
        if st.expectedLength > 0 && st.buffer.count >= st.expectedLength {
            states[pid] = st
            finish(pid: pid, truncated: false, emit: emit)
            st = states[pid]!
        }
    }

    /// Parses and emits the buffered PES for pid, if any
    private mutating func finish(pid: UInt16, truncated: Bool, emit: (DemuxEvent) -> Void) {
        guard var st = states[pid], st.collecting else { return }
        defer {
            st.collecting = false
            st.buffer.removeAll(keepingCapacity: true)
            states[pid] = st
        }
        let b = st.buffer
        guard b.count >= 9, b[0] == 0, b[1] == 0, b[2] == 1 else {
            stats.droppedPES += 1
            return
        }
        var damaged = st.damaged
        if st.expectedLength > 0 && b.count < st.expectedLength && truncated {
            damaged = true
        }
        let streamID = b[3]
        var pts: UInt64?
        var dts: UInt64?
        var payloadStart = 6
        // stream ids without the optional PES header (padding, private_2, ECM, ...)
        let noHeader: Set<UInt8> = [0xbc, 0xbe, 0xbf, 0xf0, 0xf1, 0xff, 0xf2, 0xf8]
        if !noHeader.contains(streamID) {
            let flags = b[7]
            let headerLength = Int(b[8])
            payloadStart = 9 + headerLength
            guard payloadStart <= b.count else {
                stats.droppedPES += 1
                return
            }
            if flags & 0x80 != 0, headerLength >= 5 { pts = Self.timestamp(b, 9) }
            if flags & 0xc0 == 0xc0, headerLength >= 10 { dts = Self.timestamp(b, 14) }
        }
        var end = b.count
        if st.expectedLength > 0 { end = min(end, st.expectedLength) }
        emit(.pes(PESPacket(pid: pid, streamID: streamID, pts: pts, dts: dts,
                            payload: Array(b[payloadStart..<end]), damaged: damaged,
                            discontinuity: st.discontinuity, randomAccess: st.randomAccess)))
    }

    private static func timestamp(_ b: [UInt8], _ i: Int) -> UInt64 {
        UInt64(b[i] >> 1 & 0x07) << 30 | UInt64(b[i + 1]) << 22 | UInt64(b[i + 2] >> 1) << 15
            | UInt64(b[i + 3]) << 7 | UInt64(b[i + 4] >> 1)
    }
}

/// Unwraps 33-bit PTS/DTS (and PCR bases) into a monotonic 64-bit timeline.
public struct TimestampUnwrapper: Sendable {
    public static let wrap: Int64 = 1 << 33
    private var last: Int64?

    public init() {}

    public mutating func reset() { last = nil }

    public mutating func unwrap(_ ts: UInt64) -> Int64 {
        var v = Int64(ts & UInt64(Self.wrap - 1))
        if let last {
            // pick the representative of v closest to the previous value
            let base = last - (last % Self.wrap + Self.wrap) % Self.wrap
            v += base
            if v - last > Self.wrap / 2 { v -= Self.wrap }
            if last - v > Self.wrap / 2 { v += Self.wrap }
        }
        last = v
        return v
    }
}
