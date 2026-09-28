// SPDX-License-Identifier: GPL-2.0-only
@testable import ManzanaTuner
@testable import ManzanaTV
import Testing

func reading(lock: Bool = true, layers: UInt8 = 0b011, errors: Double = 0, snr: Double = 20) -> Signal {
    Signal(hasSignal: true, hasLock: lock, layerLock: layers, strengthPercent: 60, snr: snr, errorsPerSecond: errors)
}

@Suite struct ReceptionClassification {
    @Test func instantJudgement() {
        let hd = ReceptionClassifier(oneSeg: false)
        #expect(hd.instant(reading()) == .good)
        #expect(hd.instant(reading(errors: 40)) == .marginal)
        #expect(hd.instant(reading(layers: 0b001)) == .poor, "HD layer lost, one-seg only")
        #expect(hd.instant(reading(lock: false, layers: 0)) == .poor)

        let oneSeg = ReceptionClassifier(oneSeg: true)
        #expect(oneSeg.instant(reading(layers: 0b001)) == .good, "one-seg only needs layer A")
    }

    @Test func degradesQuicklyImprovesSlowly() {
        var c = ReceptionClassifier(oneSeg: false)
        c.update(reading())
        #expect(c.update(reading(layers: 0b001)) == .good, "one bad reading isn't enough")
        #expect(c.update(reading(layers: 0b001)) == .poor, "two in a row degrade")
        for _ in 0..<19 { #expect(c.update(reading()) == .poor, "needs 5 s of clean signal") }
        #expect(c.update(reading()) == .good)
    }

    @Test func errorBurstsAreMarginal() {
        var c = ReceptionClassifier(oneSeg: false)
        for _ in 0..<5 { c.update(reading()) }
        c.update(reading(errors: 30))
        #expect(c.update(reading(errors: 30)) == .marginal)
        // intermittent clean readings don't flip it back
        for i in 0..<19 { #expect(c.update(reading(errors: i % 3 == 0 ? 30 : 0)) == .marginal) }
    }

    @Test func doesntFlickerOnAlternatingReadings() {
        var c = ReceptionClassifier(oneSeg: false)
        var changes = 0, last = c.reception
        for i in 0..<80 {
            let r = c.update(reading(layers: i % 2 == 0 ? 0b011 : 0b001))
            if r != last { changes += 1 }
            last = r
        }
        #expect(changes <= 1, "flipped \(changes) times")
    }
}
