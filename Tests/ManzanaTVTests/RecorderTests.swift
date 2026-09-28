// SPDX-License-Identifier: GPL-2.0-only
import Foundation
@testable import ManzanaTuner
@testable import ManzanaTV
import Testing

@Suite struct Recorder {
    let channel = Channel(major: 9, minor: 1, name: "MEGA HD", kind: "tv", rf: 27, serviceID: 0x2600)

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mzv-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func writesEverythingInOrder() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = TSRecorder.url(for: channel, in: dir.appendingPathComponent("new folder"))
        let r = try TSRecorder(channel: channel, url: url)
        var expected = Data()
        for i in 0..<50 {
            let chunk = Data(repeating: UInt8(i), count: 188 * 7)
            expected += chunk
            r.write(chunk)
        }
        r.finish()
        r.write(Data(count: 188))  // after finish: ignored
        #expect(try Data(contentsOf: url) == expected)
        #expect(r.bytesWritten == Int64(expected.count))
        #expect(r.error == nil)
    }

    @Test func namesAreReadableAndUnique() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 28, hour: 20, minute: 5))!
        let first = TSRecorder.url(for: channel, in: dir, at: date)
        #expect(first.lastPathComponent == "MEGA HD 9.1 2026-09-28 20.05.ts")
        _ = try TSRecorder(channel: channel, url: first)
        #expect(TSRecorder.url(for: channel, in: dir, at: date).lastPathComponent == "MEGA HD 9.1 2026-09-28 20.05 (2).ts")

        let slashed = Channel(major: 5, minor: 1, name: "A/B: TV", kind: "tv", rf: 20, serviceID: 1)
        #expect(TSRecorder.url(for: slashed, in: dir, at: date).lastPathComponent == "A-B- TV 5.1 2026-09-28 20.05.ts")
    }
}
