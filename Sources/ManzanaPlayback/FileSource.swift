// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaCore

/// Seeded, reproducible damage for testing recovery
public struct FaultPlan: Sendable {
    public var seed: UInt64 = 1
    /// Per-packet probabilities
    public var drop = 0.0
    public var transportError = 0.0
    public var corrupt = 0.0
    /// Every `gapEvery` seconds, deliver nothing for `gapLength` (content keeps
    /// advancing, as when a live signal drops out)
    public var gapEvery: Double?
    public var gapLength = 3.0
    /// Every `jumpEvery` seconds, skip `jumpLength` of content at once (a
    /// timestamp jump within the same epoch)
    public var jumpEvery: Double?
    public var jumpLength = 5.0
    /// Pacing speed relative to the stream clock (1.0005 = source clock 500 ppm fast)
    public var clockRatio = 1.0

    public init() {}

    /// "drop=0.01,tei=0.001,corrupt=0.001,gap=10:3,jump=15:5,clock=1.0005,seed=7"
    public init?(parsing spec: String) {
        for item in spec.split(separator: ",") {
            let kv = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { return nil }
            let v = kv[1].split(separator: ":").compactMap { Double($0) }
            guard !v.isEmpty else { return nil }
            switch kv[0] {
            case "drop": drop = v[0]
            case "tei": transportError = v[0]
            case "corrupt": corrupt = v[0]
            case "gap": gapEvery = v[0]; if v.count > 1 { gapLength = v[1] }
            case "jump": jumpEvery = v[0]; if v.count > 1 { jumpLength = v[1] }
            case "clock": clockRatio = v[0]
            case "seed": seed = UInt64(v[0])
            default: return nil
            }
        }
    }
}

/// SplitMix64: small, seedable, good enough for fault injection
struct SeededRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9e3779b97f4a7c15
        var z = state
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
    mutating func chance(_ p: Double) -> Bool { p > 0 && Double(next() >> 11) / Double(1 << 53) < p }
}

/// Plays a recording as if it were live: filters one service with the core's
/// program filter and paces packets by the program's PCR against the host
/// clock. Loops at the end, starting a new epoch each time.
public final class FileSource: @unchecked Sendable {
    public let url: URL
    public let serviceID: UInt16
    public var loop = true
    /// Packets per delivery (like the tuner's USB batches)
    public var batchPackets = 256
    public var faults = FaultPlan()

    private let lock = NSLock()
    private var running = false
    private var thread: Thread?

    public init(url: URL, serviceID: UInt16) {
        self.url = url
        self.serviceID = serviceID
    }

    /// Delivers (packets, epoch) and PMT updates on a background thread
    public func start(packets: @escaping @Sendable (Data, UInt32) -> Void,
                      program: @escaping @Sendable ([ProgramStream]) -> Void) {
        lock.withLock { running = true }
        let t = Thread { [self] in run(packets: packets, program: program) }
        t.qualityOfService = .userInteractive
        t.name = "mzv.filesource"
        thread = t
        t.start()
    }

    public func stop() {
        lock.withLock { running = false }
    }

    private var isRunning: Bool { lock.withLock { running } }

    private func run(packets: @Sendable (Data, UInt32) -> Void, program: @Sendable ([ProgramStream]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return }
        let total = data.count / 188
        var epoch: UInt32 = 0
        var rng = SeededRandom(state: faults.seed)

        while isRunning {
            let filter = mzv_filter_new(serviceID, true)
            defer { mzv_filter_free(filter) }
            var generation: UInt32 = 0
            var pcrPID: UInt16 = 0x1fff
            var clockStart: (pcr: Int64, host: UInt64)?
            var out = [UInt8](repeating: 0, count: batchPackets * 188)
            var i = 0
            let passStart = DispatchTime.now().uptimeNanoseconds
            var nextGap = faults.gapEvery ?? .infinity
            var gapUntil = 0.0
            var nextJump = faults.jumpEvery ?? .infinity

            while isRunning && i < total {
                let n = min(batchPackets, total - i)
                let kept = data.withUnsafeBytes { raw in
                    mzv_filter_feed(filter, raw.bindMemory(to: UInt8.self).baseAddress! + i * 188, n, &out)
                }
                i += n

                var prog = mzv_program()
                if mzv_filter_program(filter, &prog), prog.generation != generation {
                    generation = prog.generation
                    pcrPID = prog.pcr_pid
                    program(withUnsafeBytes(of: prog.es) { raw in
                        raw.bindMemory(to: mzv_es.self).prefix(Int(prog.nes)).map {
                            ProgramStream($0)
                        }
                    })
                }
                guard kept > 0 else { continue }

                // pace by the last PCR in this batch
                let now = DispatchTime.now().uptimeNanoseconds
                if let pcr = Self.lastPCR(out, count: kept, pid: pcrPID) {
                    if let start = clockStart {
                        let elapsed = Double(max(0, pcr - start.pcr)) / 27e6 / faults.clockRatio
                        let due = start.host + UInt64(elapsed * 1e9)
                        if pcr < start.pcr || due > now + 2_000_000_000 {
                            clockStart = (pcr, now)  // PCR jumped: re-anchor
                        } else if due > now {
                            Thread.sleep(forTimeInterval: Double(due - now) / 1e9)
                        }
                    } else {
                        clockStart = (pcr, now)
                    }
                }

                // scheduled faults, by wall time since this pass started
                let t = Double(DispatchTime.now().uptimeNanoseconds - passStart) / 1e9
                if let every = faults.gapEvery, t >= nextGap {
                    nextGap += every
                    gapUntil = t + faults.gapLength
                }
                if t < gapUntil { continue }  // signal lost: content advances, nothing arrives
                if let every = faults.jumpEvery, t >= nextJump {
                    nextJump += every
                    // skip ahead in the content without pacing: a PTS jump, same epoch
                    i = min(total, i + Int(faults.jumpLength * 17.3e6 / 8 / 188))
                    clockStart = nil
                    continue
                }

                var batch = Data(out[0..<kept * 188])
                if faults.drop > 0 || faults.transportError > 0 || faults.corrupt > 0 {
                    batch = damage(batch, &rng)
                }
                packets(batch, epoch)
            }
            guard loop else { break }
            epoch &+= 1
        }
    }

    private func damage(_ batch: Data, _ rng: inout SeededRandom) -> Data {
        var out = Data(capacity: batch.count)
        var pkt = [UInt8](repeating: 0, count: 188)
        for k in 0..<(batch.count / 188) {
            if rng.chance(faults.drop) { continue }
            pkt.withUnsafeMutableBytes { dst in
                batch.withUnsafeBytes { src in dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[k * 188..<(k + 1) * 188])) }
            }
            if rng.chance(faults.transportError) { pkt[1] |= 0x80 }
            if rng.chance(faults.corrupt) {
                for _ in 0..<8 { pkt[4 + Int(rng.next() % 184)] = UInt8(truncatingIfNeeded: rng.next()) }
            }
            out.append(contentsOf: pkt)
        }
        return out
    }

    /// PCR (27 MHz) of the last packet in buf carrying one on pid
    static func lastPCR(_ buf: [UInt8], count: Int, pid: UInt16) -> Int64? {
        var result: Int64?
        for k in 0..<count {
            let p = k * 188
            guard UInt16(buf[p + 1] & 0x1f) << 8 | UInt16(buf[p + 2]) == pid,
                  buf[p + 3] & 0x20 != 0, buf[p + 4] >= 7, buf[p + 5] & 0x10 != 0 else { continue }
            let base = Int64(buf[p + 6]) << 25 | Int64(buf[p + 7]) << 17 | Int64(buf[p + 8]) << 9
                | Int64(buf[p + 9]) << 1 | Int64(buf[p + 10]) >> 7
            let ext = Int64(buf[p + 10] & 1) << 8 | Int64(buf[p + 11])
            result = base * 300 + ext
        }
        return result
    }
}
