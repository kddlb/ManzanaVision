// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaTuner

/// Writes one channel's transport stream to a file as it arrives: the same
/// single-program TS the player gets (PAT listing only that service, its PMT
/// and streams), so VLC, IINA, mpv and ffmpeg play it as is.
///
/// write() is called on the tuner's thread and only queues the data; the
/// file is written on a queue of its own. Gaps (signal loss, unplugging)
/// simply leave nothing in the file for that time.
public final class TSRecorder: @unchecked Sendable {
    public let channel: Channel
    public let url: URL
    public let started: Date

    private let queue = DispatchQueue(label: "mzv.recorder", qos: .utility)
    private let handle: FileHandle
    private let lock = NSLock()
    private var _bytes: Int64 = 0
    private var _error: (any Error)?
    private var closed = false  // queue-confined

    /// Creates the file (and its folder)
    public init(channel: Channel, url: URL, started: Date = .now) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fm.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forWritingTo: url)
        self.channel = channel
        self.url = url
        self.started = started
    }

    /// "MEGA HD 9.1 2026-09-28 20.15.ts" in folder, made unique if needed
    public static func url(for channel: Channel, in folder: URL, at date: Date = .now) -> URL {
        let stamp = date.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)).\(minute: .twoDigits)",
                                             timeZone: .current, calendar: .current))
        let name = "\(channel.name) \(channel.virtual) \(stamp)"
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var url = folder.appendingPathComponent(name).appendingPathExtension("ts")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) (\(n))").appendingPathExtension("ts")
            n += 1
        }
        return url
    }

    public var bytesWritten: Int64 { lock.withLock { _bytes } }
    /// The first write error (disk full, volume gone); nothing more is written after one
    public var error: (any Error)? { lock.withLock { _error } }

    public func write(_ data: Data) {
        queue.async { [self] in
            guard !closed, error == nil else { return }
            do {
                try handle.write(contentsOf: data)
                lock.withLock { _bytes += Int64(data.count) }
            } catch {
                lock.withLock { _error = error }
            }
        }
    }

    /// Writes out what's queued and closes the file
    public func finish() {
        queue.sync {
            guard !closed else { return }
            closed = true
            try? handle.synchronize()
            try? handle.close()
        }
    }
}
