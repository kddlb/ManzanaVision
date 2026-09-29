// SPDX-License-Identifier: GPL-2.0-only
import Foundation
@testable import ManzanaStream
import Testing

/// Builds caption PES payloads the way ISDB-T sends them
enum CaptionPES {
    /// One data group (0 = management, 1… = statement for that language) in a PES_data_packet
    static func group(_ id: UInt8, _ data: [UInt8]) -> [UInt8] {
        var g: [UInt8] = [id << 2, 0, 0, UInt8(data.count >> 8), UInt8(data.count & 0xff)] + data
        let crc = ARIBCaptionDecoder.crc16(g[...])
        g += [UInt8(crc >> 8), UInt8(crc & 0xff)]
        return [0x80, 0xff, 0xf0] + g
    }

    static func dataUnit(_ body: [UInt8]) -> [UInt8] {
        [0x1f, 0x20, 0, UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body
    }

    static func loop(_ units: [UInt8]) -> [UInt8] {
        [UInt8(units.count >> 16), UInt8(units.count >> 8 & 0xff), UInt8(units.count & 0xff)] + units
    }

    /// Management for one language: DMF auto display, format 960×540 horizontal (SWF 7), 8-bit code
    static func management(_ language: String) -> [UInt8] {
        group(0, [0x3f, 1, 0x1a] + Array(language.utf8) + [0x80] + loop([]))
    }

    static func statement(_ body: [UInt8]) -> [UInt8] {
        group(1, [0x3f] + loop(dataUnit(body)))
    }

    /// CSI P1;P2 SP F
    static func csi(_ params: [Int], _ f: UInt8) -> [UInt8] {
        [0x9b] + Array(params.map(String.init).joined(separator: ";").utf8) + [0x20, f]
    }

    /// What Mega's caption encoder sends before each screen: SWF 7, a
    /// 478×133 area at (237, 403), 24-dot characters, NSZ, white on black
    static let megaHeader: [UInt8] = [0x0c] + csi([7], 0x53) + csi([478, 133], 0x56) + csi([237, 403], 0x5f)
        + csi([24, 24], 0x57) + csi([0], 0x58) + csi([0], 0x59) + [0x8a, 0x87, 0x90, 0x50]
}

@Suite struct ClosedCaptions {
    @Test func latinStatement() throws {
        var d = ARIBCaptionDecoder()
        #expect(d.decode(CaptionPES.management("spa")) == nil)
        // "INFECCIÓN" / "A ÉL Y" with the accents in GR (Latin extension)
        let body = CaptionPES.megaHeader + [0x1c, 0x40, 0x40] + Array("INFECCI".utf8) + [0xd3] + Array("N".utf8)
            + [0x0d] + Array("A ".utf8) + [0xc9] + Array("L Y".utf8)
        let decoded = d.decode(CaptionPES.statement(body))
        let page = try #require(decoded)
        #expect(page.text == "INFECCIÓN\nA ÉL Y")
        #expect(page.language == "spa")
        #expect(d.encoding == .latin)
        #expect((page.width, page.height) == (960, 540))
        #expect(page.lines.count == 2)
        let first = page.lines[0], second = page.lines[1]
        #expect((first.x, first.y, first.height) == (237, 403, 24))
        #expect((second.x, second.y) == (237, 427))
        let run = try #require(first.runs.first)
        #expect(run.fontSize == 24)
        #expect(run.foreground == .white)
        #expect(run.background == CaptionColor(0, 0, 0))
    }

    @Test func latinLinesDontWrapOnTheNormalSizeGrid() throws {
        // 31 characters in a 478-dot area: on a 24-dot grid that would wrap
        // after 19, on the half-width grid Latin receivers use it fits
        var d = ARIBCaptionDecoder()
        let text = "PARA BRINDARLE UNA AYUDA SOCIAL"
        let decoded = d.decode(CaptionPES.statement(CaptionPES.megaHeader + [0x1c, 0x40, 0x40] + Array(text.utf8)))
        let page = try #require(decoded)
        #expect(page.lines.count == 1)
        #expect(page.text == text)
    }

    @Test func clearScreenAlone() throws {
        var d = ARIBCaptionDecoder()
        _ = d.decode(CaptionPES.statement(CaptionPES.megaHeader + Array("HOLA".utf8)))
        let decoded = d.decode(CaptionPES.statement([0x0c]))
        let page = try #require(decoded)
        #expect(page.isEmpty)
        #expect(page.text.isEmpty)
    }

    @Test func statementsAddToTheScreenUntilCleared() throws {
        var d = ARIBCaptionDecoder()
        _ = d.decode(CaptionPES.statement(CaptionPES.megaHeader + [0x1c, 0x40, 0x40] + Array("UNO".utf8)))
        let decoded = d.decode(CaptionPES.statement([0x1c, 0x41, 0x40] + Array("DOS".utf8)))
        let page = try #require(decoded)
        #expect(page.text == "UNO\nDOS")
    }

    @Test func coloursAndSpecialCharacters() throws {
        var d = ARIBCaptionDecoder()
        // yellow text, then ♪ from G3 through SS3, then red
        let body = CaptionPES.megaHeader + [0x83] + Array("LA".utf8) + [0x1d, 0x21] + [0x81] + Array("X".utf8)
        let decoded = d.decode(CaptionPES.statement(body))
        let page = try #require(decoded)
        #expect(page.text == "LA♪X")
        let runs = try #require(page.lines.first?.runs)
        #expect(runs.map(\.text) == ["LA♪", "X"])
        #expect(runs[0].foreground == CaptionColor(255, 255, 0))
        #expect(runs[1].foreground == CaptionColor(255, 0, 0))
    }

    @Test func rejectsCorruptGroups() {
        var d = ARIBCaptionDecoder()
        var pes = CaptionPES.statement(CaptionPES.megaHeader + Array("HOLA".utf8))
        pes[pes.count - 5] ^= 0x01
        #expect(d.decode(pes) == nil)
        // superimposed text (data_identifier 0x81) isn't captions
        var superimpose = CaptionPES.statement(Array("HOLA".utf8))
        superimpose[0] = 0x81
        #expect(d.decode(superimpose) == nil)
        // truncated
        #expect(d.decode(Array(CaptionPES.statement(Array("HOLA".utf8)).prefix(9))) == nil)
    }

    @Test func otherLanguagesAreSkipped() {
        var d = ARIBCaptionDecoder()
        var pes = CaptionPES.statement(Array("HOLA".utf8))
        pes[3] = 2 << 2  // language 2
        #expect(d.decode(pes) == nil)
    }

    @Test func utf8Captions() throws {
        var d = ARIBCaptionDecoder()
        // TCS = 1: UCS in UTF-8, as the Philippines sends
        _ = d.decode(CaptionPES.group(0, [0x3f, 1, 0x1a] + Array("eng".utf8) + [0x84] + CaptionPES.loop([])))
        #expect(d.encoding == .utf8)
        let decoded = d.decode(CaptionPES.statement([0x0c] + Array("Café ♪".utf8)))
        let page = try #require(decoded)
        #expect(page.text == "Café ♪")
    }

    @Test func malformedInputDoesNotCrash() {
        var d = ARIBCaptionDecoder()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            let body = (0..<Int.random(in: 0..<80, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            _ = d.decode(CaptionPES.statement(body))
        }
    }
}

@Suite(.enabled(if: Fixtures.available, "set MANZANA_FIXTURES (scripts/make-fixtures.sh)"))
struct RecordedCaptions {
    @Test func megaCaptions() throws {
        let (ts, _) = try Fixtures.load("rf27-5min-20s")
        var demux = TSDemuxer(pids: [0x68])  // 9.1's caption stream
        var decoder = ARIBCaptionDecoder()
        var pages: [CaptionPage] = []
        var lastPTS: UInt64 = 0
        var monotonic = true
        ts.withUnsafeBytes { raw in
            demux.feed(raw) { ev in
                guard case .pes(let pes) = ev, let page = decoder.decode(pes.payload) else { return }
                if let pts = pes.pts {
                    monotonic = monotonic && pts >= lastPTS
                    lastPTS = pts
                }
                pages.append(page)
            }
        }
        #expect(decoder.page.language == "spa")
        #expect(pages.count > 20)
        #expect(monotonic)
        // live captions: every screen is text in the lower part of the picture, and
        // accented capitals come through the Latin extension
        #expect(pages.allSatisfy { $0.isEmpty || $0.lines.allSatisfy { $0.y > 270 && $0.x + 10 < 960 } })
        #expect(pages.contains { $0.text.contains("Ó") })
        #expect(!pages.contains { $0.text.contains("\u{3013}") || $0.text.contains("\u{FFFD}") })
    }
}
