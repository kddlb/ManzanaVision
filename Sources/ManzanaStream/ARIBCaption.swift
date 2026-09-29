// SPDX-License-Identifier: GPL-2.0-only
// ISDB-T closed captions: ARIB STD-B24 data groups in private PES (stream_type
// 0x06, data_component_id 0x0008), with the Latin character sets of ABNT
// NBR 15606-1 used in Latin America. The Latin G-set tables and colour map
// follow libaribcaption (MIT, © 2022 magicxqq).

/// A colour from the ARIB 128-entry colour map
public struct CaptionColor: Sendable, Hashable {
    public var red, green, blue, alpha: UInt8

    public init(_ red: UInt8, _ green: UInt8, _ blue: UInt8, _ alpha: UInt8 = 255) {
        (self.red, self.green, self.blue, self.alpha) = (red, green, blue, alpha)
    }

    public static let white = CaptionColor(255, 255, 255)
    public static let clear = CaptionColor(0, 0, 0, 0)

    /// Palette p, index i (0–15); index 8 of palette 0 is transparent
    static func clut(_ palette: Int, _ index: Int) -> CaptionColor {
        table[(palette & 7) * 16 + (index & 15)]
    }

    private static func c(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> CaptionColor { CaptionColor(r, g, b, a) }
    private static let table: [CaptionColor] = [
        c(0, 0, 0, 255), c(255, 0, 0, 255), c(0, 255, 0, 255), c(255, 255, 0, 255),
        c(0, 0, 255, 255), c(255, 0, 255, 255), c(0, 255, 255, 255), c(255, 255, 255, 255),
        c(0, 0, 0, 0), c(170, 0, 0, 255), c(0, 170, 0, 255), c(170, 170, 0, 255),
        c(0, 0, 170, 255), c(170, 0, 170, 255), c(0, 170, 170, 255), c(170, 170, 170, 255),
        c(0, 0, 85, 255), c(0, 85, 0, 255), c(0, 85, 85, 255), c(0, 85, 170, 255),
        c(0, 85, 255, 255), c(0, 170, 85, 255), c(0, 170, 255, 255), c(0, 255, 85, 255),
        c(0, 255, 170, 255), c(85, 0, 0, 255), c(85, 0, 85, 255), c(85, 0, 170, 255),
        c(85, 0, 255, 255), c(85, 85, 0, 255), c(85, 85, 85, 255), c(85, 85, 170, 255),
        c(85, 85, 255, 255), c(85, 170, 0, 255), c(85, 170, 85, 255), c(85, 170, 170, 255),
        c(85, 170, 255, 255), c(85, 255, 0, 255), c(85, 255, 85, 255), c(85, 255, 170, 255),
        c(85, 255, 255, 255), c(170, 0, 85, 255), c(170, 0, 255, 255), c(170, 85, 0, 255),
        c(170, 85, 85, 255), c(170, 85, 170, 255), c(170, 85, 255, 255), c(170, 170, 85, 255),
        c(170, 170, 255, 255), c(170, 255, 0, 255), c(170, 255, 85, 255), c(170, 255, 170, 255),
        c(170, 255, 255, 255), c(255, 0, 85, 255), c(255, 0, 170, 255), c(255, 85, 0, 255),
        c(255, 85, 85, 255), c(255, 85, 170, 255), c(255, 85, 255, 255), c(255, 170, 0, 255),
        c(255, 170, 85, 255), c(255, 170, 170, 255), c(255, 170, 255, 255), c(255, 255, 85, 255),
        c(255, 255, 170, 255), c(0, 0, 0, 128), c(255, 0, 0, 128), c(0, 255, 0, 128),
        c(255, 255, 0, 128), c(0, 0, 255, 128), c(255, 0, 255, 128), c(0, 255, 255, 128),
        c(255, 255, 255, 128), c(170, 0, 0, 128), c(0, 170, 0, 128), c(170, 170, 0, 128),
        c(0, 0, 170, 128), c(170, 0, 170, 128), c(0, 170, 170, 128), c(170, 170, 170, 128),
        c(0, 0, 85, 128), c(0, 85, 0, 128), c(0, 85, 85, 128), c(0, 85, 170, 128),
        c(0, 85, 255, 128), c(0, 170, 85, 128), c(0, 170, 255, 128), c(0, 255, 85, 128),
        c(0, 255, 170, 128), c(85, 0, 0, 128), c(85, 0, 85, 128), c(85, 0, 170, 128),
        c(85, 0, 255, 128), c(85, 85, 0, 128), c(85, 85, 85, 128), c(85, 85, 170, 128),
        c(85, 85, 255, 128), c(85, 170, 0, 128), c(85, 170, 85, 128), c(85, 170, 170, 128),
        c(85, 170, 255, 128), c(85, 255, 9, 128), c(85, 255, 85, 128), c(85, 255, 170, 128),
        c(85, 255, 255, 128), c(170, 0, 85, 128), c(170, 0, 255, 128), c(170, 85, 0, 128),
        c(170, 85, 85, 128), c(170, 85, 170, 128), c(170, 85, 255, 128), c(170, 170, 85, 128),
        c(170, 170, 255, 128), c(170, 255, 0, 128), c(170, 255, 85, 128), c(170, 255, 170, 128),
        c(170, 255, 255, 128), c(255, 0, 85, 128), c(255, 0, 170, 128), c(255, 85, 9, 128),
        c(255, 85, 85, 128), c(255, 85, 170, 128), c(255, 85, 255, 128), c(255, 170, 0, 128),
        c(255, 170, 85, 128), c(255, 170, 170, 128), c(255, 170, 255, 128), c(255, 255, 85, 128),
    ]
}

/// Characters of one style, laid out left to right
public struct CaptionRun: Sendable, Equatable {
    public var text: String
    public var foreground: CaptionColor
    public var background: CaptionColor
    /// Glyph height on the caption plane
    public var fontSize: Int
    public var underline = false
    public var bold = false
    public var italic = false
}

/// A row of text starting at one position on the caption plane
public struct CaptionLine: Sendable, Equatable {
    /// Top-left of the first character cell, in caption plane pixels
    public var x: Int
    public var y: Int
    /// Cell height (character plus line spacing)
    public var height: Int
    public var runs: [CaptionRun]
    /// Where the next character in line would go
    var nextX: Int

    public var text: String { runs.map(\.text).joined() }
}

/// What the caption screen shows after a statement
public struct CaptionPage: Sendable, Equatable {
    /// The caption plane the positions refer to (960×540 unless SWF says otherwise)
    public var width = 960
    public var height = 540
    public var lines: [CaptionLine] = []
    /// ISO 639-2 language of the caption stream ("spa", "por"), once known
    public var language: String?

    public init() {}

    /// Nothing but blanks: take the captions off the screen
    public var isEmpty: Bool {
        lines.allSatisfy { $0.text.allSatisfy(\.isWhitespace) }
    }

    /// The text, one screen row per line, top to bottom
    public var text: String {
        let rows = Dictionary(grouping: lines.filter { !$0.text.allSatisfy(\.isWhitespace) }, by: \.y)
        return rows.keys.sorted().map { y in
            rows[y]!.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
                .trimmingSpaces()
        }.joined(separator: "\n")
    }
}

extension String {
    fileprivate func trimmingSpaces() -> String {
        var s = Substring(self)
        while s.first == " " { s.removeFirst() }
        while s.last == " " { s.removeLast() }
        return String(s)
    }
}

/// Decodes caption PES into caption screens. Keeps the screen between
/// statements, since a statement only adds to it unless it clears it first.
public struct ARIBCaptionDecoder: Sendable {
    public enum Encoding: Sendable, Equatable {
        /// ABNT NBR 15606-1: ASCII in GL, Latin-1-like extension in GR
        case latin
        /// ARIB STD-B24 for Japan (kanji shows as 〓: the JIS tables aren't included)
        case japanese
        /// TCS = 1 (UCS/UTF-8), e.g. the Philippines
        case utf8
    }

    private enum GSet: Equatable {
        case alphanumeric, latinExtension, latinSpecial, hiragana, katakana
        case kanji           // 2-byte, not mapped
        case drcs(bytes: Int)
        case macro
        case other(bytes: Int)

        var bytes: Int {
            switch self {
            case .kanji: 2
            case .drcs(let n), .other(let n): n
            default: 1
            }
        }
    }

    public private(set) var encoding: Encoding = .latin
    public private(set) var page = CaptionPage()
    /// Statement data groups carry this language number (1–8)
    public var languageNumber = 1

    private var g: [GSet] = []
    private var gl = 0, gr = 2
    private var swf = 7
    private var areaX = 0, areaY = 0, areaW = 960, areaH = 540
    private var charW = 36, charH = 36, hSpacing = 4, vSpacing = 24
    private var hScale = 1.0, vScale = 1.0
    private var posX = 0, posY = 0, posSet = false
    private var palette = 0
    private var fg = CaptionColor.white, bg = CaptionColor.clear
    private var underline = false, bold = false, italic = false
    private var repeatCount = 0
    private var lastManagementGroup: UInt8?

    public init() {
        resetState()
    }

    /// Forgets everything (channel change, discontinuity)
    public mutating func reset() {
        encoding = .latin
        languageNumber = 1
        lastManagementGroup = nil
        page = CaptionPage()
        resetState()
    }

    /// Decodes one caption PES payload. Returns the screen when a caption
    /// statement was decoded (an empty page means clear the captions).
    public mutating func decode(_ payload: [UInt8]) -> CaptionPage? {
        // PES_data_packet: data_identifier 0x80 (0x81 is superimposed text), private_stream_id 0xFF
        guard payload.count >= 3, payload[0] == 0x80, payload[1] == 0xff else { return nil }
        let start = 3 + Int(payload[2] & 0x0f)
        guard start + 5 <= payload.count else { return nil }
        let id = payload[start] >> 2
        let size = Int(payload[start + 3]) << 8 | Int(payload[start + 4])
        let end = start + 5 + size
        guard end + 2 <= payload.count, Self.crc16(payload[start..<end + 2]) == 0 else { return nil }
        let data = Array(payload[start + 5..<end])

        if id & 0x0f == 0 {
            // management: resent every few seconds; each copy of a group (A/B) is the same
            guard id != lastManagementGroup else { return nil }
            lastManagementGroup = id
            management(data)
            return nil
        }
        guard Int(id & 0x0f) == languageNumber else { return nil }
        statement(data)
        return page
    }

    // MARK: - data groups

    private mutating func management(_ d: [UInt8]) {
        var i = 1
        guard d.count >= 2 else { return }
        if d[0] >> 6 == 0b10 { i += 5 }  // OTM
        guard i < d.count else { return }
        let languages = Int(d[i])
        i += 1
        for _ in 0..<languages {
            guard i + 5 <= d.count else { return }
            let tag = Int(d[i] >> 5)
            let dmf = d[i] & 0x0f
            i += 1
            if dmf == 0b1100 || dmf == 0b1101 || dmf == 0b1110 { i += 1 }
            guard i + 4 <= d.count else { return }
            let code = String(decoding: d[i..<i + 3], as: UTF8.self)
            let format = Int(d[i + 3] >> 4)
            let tcs = (d[i + 3] >> 2) & 3
            i += 4
            guard tag + 1 == languageNumber else { continue }
            let next: Encoding = tcs == 1 ? .utf8 : code == "jpn" ? .japanese : .latin
            page.language = code
            if next != encoding {
                encoding = next
                resetState()
            }
            swf = format - 1
            resetGraphicSets()
            resetWritingFormat()
        }
        guard i + 3 <= d.count else { return }
        let length = Int(d[i]) << 16 | Int(d[i + 1]) << 8 | Int(d[i + 2])
        i += 3
        // management may carry a statement body with the writing format; no text is shown from it
        let saved = page
        dataUnits(Array(d[i..<min(d.count, i + length)]))
        page = saved
    }

    private mutating func statement(_ d: [UInt8]) {
        guard !d.isEmpty else { return }
        var i = 1
        let tmd = d[0] >> 6
        if tmd == 0b01 || tmd == 0b10 { i += 5 }  // STM
        guard i + 3 <= d.count else { return }
        let length = Int(d[i]) << 16 | Int(d[i + 1]) << 8 | Int(d[i + 2])
        i += 3
        dataUnits(Array(d[i..<min(d.count, i + length)]))
    }

    private mutating func dataUnits(_ d: [UInt8]) {
        var i = 0
        while i + 5 <= d.count, d[i] == 0x1f {
            let parameter = d[i + 1]
            let size = Int(d[i + 2]) << 16 | Int(d[i + 3]) << 8 | Int(d[i + 4])
            let end = min(d.count, i + 5 + size)
            if parameter == 0x20 {  // statement body; DRCS glyphs (0x30/0x31) aren't drawn
                body(Array(d[i + 5..<end]))
            }
            i = end
        }
    }

    // MARK: - 8-unit code

    private mutating func body(_ d: [UInt8]) {
        var i = 0
        while i < d.count {
            let used: Int?
            let b = d[i]
            if encoding == .utf8 {
                if b < 0x20 {
                    used = c0(d, i)
                } else if b == 0x20 {
                    put(" ")
                    used = 1
                } else if b == 0x7f {
                    used = 1
                } else if b == 0xc2, i + 1 < d.count, (0x80...0x9f).contains(d[i + 1]) {
                    used = c1(d, i + 1).map { $0 + 1 }
                } else {
                    used = utf8(d, i)
                }
            } else if b <= 0x20 {
                used = c0(d, i)
            } else if b < 0x7f {
                used = graphic(d, i, g[gl])
            } else if b <= 0xa0 {
                used = c1(d, i)
            } else if b < 0xff {
                used = graphic(d, i, g[gr])
            } else {
                used = 1
            }
            guard let used else { return }  // truncated or malformed: keep what we have
            i += used
        }
    }

    private mutating func c0(_ d: [UInt8], _ i: Int) -> Int? {
        let left = d.count - i
        switch d[i] {
        case 0x08: move(-1, 0)             // APB
        case 0x09: move(1, 0)              // APF
        case 0x0a: move(0, 1)              // APD
        case 0x0b: move(0, -1)             // APU
        case 0x0c:                         // CS
            let language = page.language
            resetState()
            page = CaptionPage()
            page.language = language
            (page.width, page.height) = plane
        case 0x0d: newline()               // APR
        case 0x0e: gl = 1                  // LS1
        case 0x0f: gl = 0                  // LS0
        case 0x16:                         // PAPF
            guard left >= 2 else { return nil }
            move(Int(d[i + 1] & 0x3f), 0)
            return 2
        case 0x19, 0x1d:                   // SS2, SS3: one character from G2/G3
            guard left >= 2 else { return nil }
            return graphic(d, i + 1, g[d[i] == 0x19 ? 2 : 3]).map { $0 + 1 }
        case 0x1b:                         // ESC
            return designate(d, i + 1).map { $0 + 1 }
        case 0x1c:                         // APS row, column
            guard left >= 3 else { return nil }
            setPosition(column: Int(d[i + 2] & 0x3f), row: Int(d[i + 1] & 0x3f))
            return 3
        case 0x20:                         // SP
            put(encoding == .japanese && hScale >= 1 ? "\u{3000}" : " ")
        default: break                     // NUL, BEL, CAN, RS, US
        }
        return 1
    }

    private mutating func c1(_ d: [UInt8], _ i: Int) -> Int? {
        let left = d.count - i
        switch d[i] {
        case 0x80...0x87: fg = .clut(palette, Int(d[i] - 0x80))  // BKF…WHF
        case 0x88: (hScale, vScale) = (0.5, 0.5)                  // SSZ
        case 0x89: (hScale, vScale) = (0.5, 1)                    // MSZ
        case 0x8a: (hScale, vScale) = (1, 1)                      // NSZ
        case 0x8b:                                                // SZX
            guard left >= 2 else { return nil }
            switch d[i + 1] {
            case 0x41: vScale = 2
            case 0x44: hScale = 2
            case 0x45: (hScale, vScale) = (2, 2)
            default: break
            }
            return 2
        case 0x90:                                                // COL
            guard left >= 2 else { return nil }
            if d[i + 1] == 0x20 {
                guard left >= 3 else { return nil }
                palette = Int(d[i + 2] & 0x07)
                return 3
            }
            switch d[i + 1] & 0xf0 {
            case 0x40: fg = .clut(palette, Int(d[i + 1] & 0x0f))
            case 0x50: bg = .clut(palette, Int(d[i + 1] & 0x0f))
            default: break  // half-tone colours
            }
            return 2
        case 0x91, 0x93, 0x94, 0x97:                              // FLC, POL, WMM, HLC
            guard left >= 2 else { return nil }
            return 2
        case 0x92:                                                // CDC
            guard left >= 2 else { return nil }
            return d[i + 1] == 0x20 ? (left >= 3 ? 3 : nil) : 2
        case 0x98:                                                // RPC
            guard left >= 2 else { return nil }
            let n = Int(d[i + 1] & 0x3f)
            // 0 repeats to the end of the line
            repeatCount = min(128, n > 0 ? n : max(0, (areaX + areaW - posX) / max(1, sectionWidth)))
            return 2
        case 0x99: underline = false                              // SPL
        case 0x9a: underline = true                               // STL
        case 0x9b: return csi(d, i + 1).map { $0 + 1 }            // CSI
        case 0x9d:                                                // TIME
            guard left >= 3 else { return nil }
            return 3
        default: break  // DEL, MACRO (unused in captions)
        }
        return 1
    }

    /// Control sequence: P1;P2… 0x20 F
    private mutating func csi(_ d: [UInt8], _ i: Int) -> Int? {
        var params: [Int] = [0]
        var j = i
        while j < d.count, d[j] != 0x20 {
            switch d[j] {
            case 0x30...0x39: params[params.count - 1] = min(9999, params[params.count - 1] * 10 + Int(d[j] - 0x30))
            case 0x3b: params.append(0)
            default: break
            }
            j += 1
        }
        guard j + 1 < d.count else { return nil }
        let p1 = params[0], p2 = params.count > 1 ? params[1] : 0
        switch d[j + 1] {
        case 0x53:                                                // SWF
            swf = p1
            resetWritingFormat()
        case 0x56: (areaW, areaH) = (p1, p2)                      // SDF
        case 0x57: (charW, charH) = (p1, p2)                      // SSM
        case 0x58: hSpacing = p1                                  // SHS
        case 0x59: vSpacing = p1                                  // SVS
        case 0x5f:                                                // SDP
            areaX = p1
            if params.count > 1 { areaY = p2 }
            if !posSet { setPosition(column: 0, row: 0) }
        case 0x61:                                                // ACPS
            (posX, posY, posSet) = (p1, p2, true)
        case 0x64:                                                // MDF
            (bold, italic) = (p1 & 1 != 0, p1 & 2 != 0)
        default: break  // GSM, CCC, PLD, PLU, GAA, SRC, TCC, ORN, CFS, XCS, PRA, ACS, …
        }
        return j + 2 - i
    }

    /// ESC: invocations (LS2, LS3, LS1R–LS3R) and G-set designations
    private mutating func designate(_ d: [UInt8], _ i: Int) -> Int? {
        guard i < d.count else { return nil }
        let left = d.count - i
        switch d[i] {
        case 0x6e: gl = 2; return 1
        case 0x6f: gl = 3; return 1
        case 0x7e: gr = 1; return 1
        case 0x7d: gr = 2; return 1
        case 0x7c: gr = 3; return 1
        case 0x28...0x2b:                          // 1-byte set, or DRCS with 0x20
            guard left >= 2 else { return nil }
            let n = Int(d[i] - 0x28)
            if d[i + 1] == 0x20 {
                guard left >= 3 else { return nil }
                g[n] = d[i + 2] == 0x70 ? .macro : .drcs(bytes: 1)
                return 3
            }
            g[n] = Self.set(final: d[i + 1])
            return 2
        case 0x24:                                 // 2-byte set
            guard left >= 2 else { return nil }
            if (0x28...0x2b).contains(d[i + 1]) {
                guard left >= 3 else { return nil }
                let n = Int(d[i + 1] - 0x28)
                if d[i + 2] == 0x20 {
                    guard left >= 4 else { return nil }
                    g[n] = .drcs(bytes: 2)
                    return 4
                }
                g[n] = Self.set(final: d[i + 2], twoByte: true)
                return 3
            }
            g[0] = Self.set(final: d[i + 1], twoByte: true)
            return 2
        default:
            return 1
        }
    }

    private static func set(final f: UInt8, twoByte: Bool = false) -> GSet {
        switch f {
        case 0x4a, 0x36: .alphanumeric
        case 0x4b: .latinExtension
        case 0x4c: .latinSpecial
        case 0x30, 0x37: .hiragana
        case 0x31, 0x38: .katakana
        case 0x42, 0x39, 0x3a, 0x3b: .kanji
        default: .other(bytes: twoByte ? 2 : 1)
        }
    }

    private mutating func graphic(_ d: [UInt8], _ i: Int, _ set: GSet) -> Int? {
        guard i + set.bytes <= d.count else { return nil }
        let c = Int(d[i] & 0x7f)
        guard (0x21...0x7e).contains(c) else { return set.bytes }
        switch set {
        case .alphanumeric:
            put(Character(Unicode.Scalar(UInt8(c))))
        case .latinExtension:
            put(Self.scalar(Self.latinExtension[c - 0x21]))
        case .latinSpecial:
            let i = c - 0x21
            if i < Self.latinSpecial.count { put(Self.scalar(Self.latinSpecial[i])) }
        case .hiragana:
            put(Self.scalar(c <= 0x73 ? 0x3041 + UInt32(c - 0x21) : Self.kanaSymbols[c - 0x74]))
        case .katakana:
            let mark: UInt32 = c == 0x77 ? 0x30fd : c == 0x78 ? 0x30fe : c > 0x76 ? Self.kanaSymbols[c - 0x74] : 0
            put(Self.scalar(c <= 0x76 ? 0x30a1 + UInt32(c - 0x21) : mark))
        case .kanji, .drcs, .other:
            put(encoding == .japanese ? "\u{3013}" : " ")  // no glyph for it: keep the spacing
        case .macro:
            break
        }
        return set.bytes
    }

    private mutating func utf8(_ d: [UInt8], _ i: Int) -> Int? {
        let b = d[i]
        let n = b < 0x80 ? 1 : b >> 5 == 0b110 ? 2 : b >> 4 == 0b1110 ? 3 : b >> 3 == 0b11110 ? 4 : 1
        guard i + n <= d.count else { return nil }
        if let s = String(validating: d[i..<i + n], as: UTF8.self), let ch = s.first {
            put(ch)
        }
        return n
    }

    private static func scalar(_ v: UInt32) -> Character {
        Character(Unicode.Scalar(v) ?? "?")
    }

    // MARK: - screen

    private var plane: (Int, Int) {
        switch swf {
        case 5: (1920, 1080)
        case 9, 10: (720, 480)
        default: (960, 540)
        }
    }

    /// Latin text is proportional, laid out on the half-width grid (as MSZ)
    /// even when a broadcaster selects NSZ; a normal-width grid would wrap a
    /// line meant for the display area after half of it.
    private var effectiveHScale: Double {
        encoding == .latin ? max(0.5, hScale / 2) : hScale
    }
    private var sectionWidth: Int { Int((Double(charW + hSpacing) * effectiveHScale).rounded(.down)) }
    private var sectionHeight: Int { Int((Double(charH + vSpacing) * vScale).rounded(.down)) }

    private mutating func put(_ ch: Character) {
        let times = max(1, repeatCount)
        repeatCount = 0
        for _ in 0..<times {
            if !posSet { setPosition(column: 0, row: 0) }
            let top = posY - sectionHeight
            let run = CaptionRun(text: String(ch), foreground: fg, background: bg,
                                 fontSize: Int(Double(charH) * vScale), underline: underline, bold: bold, italic: italic)
            if var line = page.lines.last, line.nextX == posX, line.y == top, line.height == sectionHeight {
                if var last = line.runs.last, last.foreground == fg, last.background == bg, last.fontSize == run.fontSize,
                   last.underline == underline, last.bold == bold, last.italic == italic {
                    last.text.append(ch)
                    line.runs[line.runs.count - 1] = last
                } else {
                    line.runs.append(run)
                }
                line.nextX = posX + sectionWidth
                page.lines[page.lines.count - 1] = line
            } else {
                page.lines.append(CaptionLine(x: posX, y: top, height: sectionHeight, runs: [run], nextX: posX + sectionWidth))
            }
            move(1, 0)
        }
    }

    private mutating func setPosition(column: Int, row: Int) {
        posSet = true
        posX = areaX + column * sectionWidth
        posY = areaY + (row + 1) * sectionHeight  // the cursor sits on the bottom of its cell
    }

    private mutating func newline() {
        if !posSet { setPosition(column: 0, row: 0) }
        posX = areaX
        posY += sectionHeight
    }

    /// Moves the cursor by cells, wrapping within the display area
    private mutating func move(_ dx: Int, _ dy: Int) {
        if !posSet { setPosition(column: 0, row: 0) }
        let w = max(1, sectionWidth), h = max(1, sectionHeight)
        var dy = dy
        for _ in 0..<abs(dx) {
            if dx < 0 {
                posX -= w
                if posX < areaX {
                    posX = areaX + areaW - w
                    dy -= 1
                }
            } else {
                posX += w
                if posX >= areaX + areaW {
                    posX = areaX
                    dy += 1
                }
            }
        }
        for _ in 0..<abs(dy) {
            if dy < 0 {
                posY -= h
                if posY < areaY { posY = areaY + areaH }
            } else {
                posY += h
                if posY > areaY + areaH { posY = areaY + h }
            }
        }
    }

    private mutating func resetState() {
        resetGraphicSets()
        resetWritingFormat()
        (areaX, areaY) = (0, 0)
        (posX, posY, posSet) = (0, 0, false)
        // Latin defaults to the half-width size, Japanese to normal
        (hScale, vScale) = encoding == .latin ? (0.5, 1) : (1, 1)
        palette = 0
        fg = .clut(0, 7)
        bg = .clut(0, 8)
        (underline, bold, italic) = (false, false, false)
        repeatCount = 0
    }

    private mutating func resetGraphicSets() {
        switch encoding {
        case .latin: g = [.alphanumeric, .alphanumeric, .latinExtension, .latinSpecial]
        case .japanese, .utf8: g = [.kanji, .alphanumeric, .hiragana, .macro]
        }
        (gl, gr) = (0, 2)
    }

    private mutating func resetWritingFormat() {
        (areaW, areaH) = plane
        (charW, charH) = (36, 36)
        switch swf {
        case 8: (hSpacing, vSpacing) = (12, 24)
        case 9: (hSpacing, vSpacing) = (4, 16)
        case 10: (hSpacing, vSpacing) = (8, 24)
        default: (hSpacing, vSpacing) = (4, 24)
        }
        if encoding == .latin { (hSpacing, vSpacing) = (2, 16) }
    }

    // MARK: - tables

    /// ABNT NBR 15606-1 Latin extension (G2, F = 0x4B), 0x21–0x7E
    private static let latinExtension: [UInt32] = [
        0x00a1, 0x00a2, 0x00a3, 0x20ac, 0x00a5, 0x0160, 0x00a7, 0x0161,
        0x00a9, 0x00aa, 0x00ab, 0x00ac, 0x00ff, 0x00ae, 0x00af, 0x00b0,
        0x00b1, 0x00b2, 0x00b3, 0x017d, 0x00b5, 0x00b6, 0x00b7, 0x017e,
        0x00b9, 0x00ba, 0x00bb, 0x0152, 0x0153, 0x0178, 0x00bf, 0x00c0,
        0x00c1, 0x00c2, 0x00c3, 0x00c4, 0x00c5, 0x00c6, 0x00c7, 0x00c8,
        0x00c9, 0x00ca, 0x00cb, 0x00cc, 0x00cd, 0x00ce, 0x00cf, 0x00d0,
        0x00d1, 0x00d2, 0x00d3, 0x00d4, 0x00d5, 0x00d6, 0x00d7, 0x00d8,
        0x00d9, 0x00da, 0x00db, 0x00dc, 0x00dd, 0x00de, 0x00df, 0x00e0,
        0x00e1, 0x00e2, 0x00e3, 0x00e4, 0x00e5, 0x00e6, 0x00e7, 0x00e8,
        0x00e9, 0x00ea, 0x00eb, 0x00ec, 0x00ed, 0x00ee, 0x00ef, 0x00f0,
        0x00f1, 0x00f2, 0x00f3, 0x00f4, 0x00f5, 0x00f6, 0x00f7, 0x00f8,
        0x00f9, 0x00fa, 0x00fb, 0x00fc, 0x00fd, 0x00fe,
    ]

    /// ABNT NBR 15606-1 special characters (G3, F = 0x4C), 0x21–0x6E; unassigned codes are "!"
    private static let latinSpecial: [UInt32] = [
        0x266a, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021,
        0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x00a4,
        0x00a6, 0x00a8, 0x00b4, 0x00b8, 0x00bc, 0x00bd, 0x00be, 0x0021,
        0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x2026,
        0x2588, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2122, 0x215b,
        0x215c, 0x215d, 0x215e, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021,
        0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021,
        0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021,
        0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021,
        0x0021, 0x0021, 0x0021, 0x0021, 0x0021, 0x0021,
    ]

    /// Hiragana/katakana sets from 0x74: three unassigned, then ゝゞー。「」、・
    private static let kanaSymbols: [UInt32] = [
        0x3000, 0x3000, 0x3000, 0x309d, 0x309e, 0x30fc, 0x3002, 0x300c, 0x300d, 0x3001, 0x30fb,
    ]

    /// CRC-16 (x¹⁶+x¹²+x⁵+1, initial 0) over a data group including its CRC is 0
    static func crc16(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0
        for b in bytes {
            crc ^= UInt16(b) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 != 0 ? crc << 1 ^ 0x1021 : crc << 1
            }
        }
        return crc
    }
}
