// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaPlayback
import ManzanaTuner

public enum ScanProgress: Sendable {
    case tuning(rf: Int)
    case result(Mux)
    /// Channels saved to the list (merged by the CLI's rules)
    case finished(changedMuxes: Int)
}

/// What the app drives: live TV from the stick, or recordings standing in for it
public protocol TVSession: AnyObject, Sendable {
    var engine: PlaybackEngine { get }
    /// One consumer each (the app model)
    var statusUpdates: AsyncStream<LiveStatus> { get }
    var signalUpdates: AsyncStream<Signal> { get }
    var tmccUpdates: AsyncStream<TMCC> { get }
    var status: LiveStatus { get }

    func loadChannels() throws -> [Channel]
    /// Starts or switches channel
    func play(_ channel: Channel)
    func stop()
    /// Stops playback and scans rfs, saving what it finds
    func scan(_ rfs: ClosedRange<Int>, psiTimeout: Duration) -> AsyncThrowingStream<ScanProgress, Error>
}
