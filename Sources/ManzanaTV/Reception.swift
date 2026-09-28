// SPDX-License-Identifier: GPL-2.0-only
import ManzanaTuner

/// How watchable the signal is, for a reception indicator
public enum Reception: Int, Sendable, Comparable, CustomStringConvertible {
    /// Only the robust one-seg layer decodes (HD layer lost), or nothing clean
    case poor
    /// The channel's layer decodes but uncorrectable errors come in bursts:
    /// the picture breaks up now and then
    case marginal
    case good

    public static func < (a: Reception, b: Reception) -> Bool { a.rawValue < b.rawValue }

    public var description: String {
        switch self {
        case .poor: "poor"
        case .marginal: "marginal"
        case .good: "good"
        }
    }
}

/// Judges reception from per-layer lock and error bursts, not SNR alone: the
/// SNR a channel needs depends on its modulation and code rate (18.9 dB is
/// comfortable on 64QAM 3/4, marginal on 5/6). Degrades quickly, improves
/// slowly, so the indicator doesn't flicker.
public struct ReceptionClassifier: Sendable {
    /// Signal readings arrive every 250 ms
    public static let samplesPerSecond = 4

    /// The layer carrying this channel: B (bit 1) for full-seg HD/SD, A (bit 0) for one-seg
    public let layerMask: UInt8
    /// Errors/s above which a reading counts as "breaking up"
    public var errorThreshold: Double = 5
    /// Consecutive worse readings before degrading (~0.5 s)
    public var degradeAfter = 2
    /// Consecutive better readings before improving (~5 s)
    public var improveAfter = 20

    public private(set) var reception: Reception = .good
    private var recent: [Reception] = []

    public init(oneSeg: Bool) {
        layerMask = oneSeg ? 0b001 : 0b010
    }

    /// What one reading says on its own
    public func instant(_ s: Signal) -> Reception {
        guard s.hasLock, s.layerLock & layerMask != 0 else { return .poor }
        return s.errorsPerSecond > errorThreshold ? .marginal : .good
    }

    /// Feeds a reading; returns the (hysteresis-filtered) reception
    @discardableResult
    public mutating func update(_ s: Signal) -> Reception {
        recent.append(instant(s))
        if recent.count > max(degradeAfter, improveAfter) { recent.removeFirst() }

        let worst = recent.suffix(degradeAfter)
        if worst.count == degradeAfter, let w = worst.max(), w < reception {
            // every one of the last few readings was worse: degrade to the best of them
            reception = w
        } else if recent.count >= improveAfter, let floor = recent.suffix(improveAfter).min(), floor > reception {
            // consistently better for a while: improve to what all of them reached
            reception = floor
        }
        return reception
    }

    public mutating func reset() {
        reception = .good
        recent.removeAll()
    }
}
