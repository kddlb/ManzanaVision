// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaCore

/// Plays a recording as if it were live: filters one service with the core's
/// program filter and paces packets by the program's PCR against the host
/// clock. Loops at the end, starting a new epoch each time.
public final class FileSource: @unchecked Sendable {
    public let url: URL
    public let serviceID: UInt16
    public var loop = true
    /// Packets per delivery (like the tuner's USB batches)
    public var batchPackets = 256

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

        while isRunning {
            let filter = mzv_filter_new(serviceID, true)
            defer { mzv_filter_free(filter) }
            var generation: UInt32 = 0
            var pcrPID: UInt16 = 0x1fff
            var clockStart: (pcr: Int64, host: UInt64)?
            var out = [UInt8](repeating: 0, count: batchPackets * 188)
            var i = 0

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
                            ProgramStream(pid: $0.pid, streamType: $0.stream_type)
                        }
                    })
                }
                guard kept > 0 else { continue }

                // pace by the last PCR in this batch
                if let pcr = Self.lastPCR(out, count: kept, pid: pcrPID) {
                    let now = DispatchTime.now().uptimeNanoseconds
                    if let start = clockStart {
                        let due = start.host + UInt64(max(0, pcr - start.pcr)) * 1000 / 27
                        if pcr < start.pcr || due > now + 2_000_000_000 {
                            clockStart = (pcr, now)  // PCR jumped: re-anchor
                        } else if due > now {
                            Thread.sleep(forTimeInterval: Double(due - now) / 1e9)
                        }
                    } else {
                        clockStart = (pcr, now)
                    }
                }
                packets(Data(out[0..<kept * 188]), epoch)
            }
            guard loop else { break }
            epoch &+= 1
        }
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
