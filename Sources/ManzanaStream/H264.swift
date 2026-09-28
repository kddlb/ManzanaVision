// SPDX-License-Identifier: GPL-2.0-only
// Just enough H.264 parsing to feed VideoToolbox: NAL units, SPS/PPS,
// slice headers (field coding, frame_num, IDR) and recovery-point SEI.

public enum NALType: UInt8, Sendable {
    case slice = 1, sliceA = 2, sliceB = 3, sliceC = 4, idr = 5, sei = 6, sps = 7, pps = 8, aud = 9
    case endOfSequence = 10, endOfStream = 11, filler = 12
}

public struct NALUnit: Sendable {
    public var bytes: [UInt8]  // header byte included, emulation prevention intact
    public var type: UInt8 { bytes.first.map { $0 & 0x1f } ?? 0 }
    public var refIdc: UInt8 { bytes.first.map { $0 >> 5 & 3 } ?? 0 }
    public var isSlice: Bool { (1...5).contains(type) }
}

/// Splits an Annex B byte stream on 00 00 01 / 00 00 00 01 start codes.
public func splitAnnexB(_ data: [UInt8]) -> [NALUnit] {
    var starts: [(code: Int, payload: Int)] = []
    var i = 0
    let n = data.count
    while i + 3 <= n {
        if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
            let code = i > 0 && data[i - 1] == 0 ? i - 1 : i
            starts.append((code, i + 3))
            i += 3
        } else {
            i += 1
        }
    }
    var nals: [NALUnit] = []
    for (k, s) in starts.enumerated() {
        var end = k + 1 < starts.count ? starts[k + 1].code : n
        while end > s.payload && data[end - 1] == 0 { end -= 1 }  // trailing_zero_8bits
        if end > s.payload { nals.append(NALUnit(bytes: Array(data[s.payload..<end]))) }
    }
    return nals
}

public struct SPS: Sendable, Equatable {
    public var id: Int
    public var profileIDC: Int
    public var levelIDC: Int
    public var chromaFormatIDC = 1
    public var separateColourPlane = false
    public var log2MaxFrameNum: Int
    public var picOrderCntType: Int
    public var log2MaxPicOrderCntLsb = 0
    public var deltaPicOrderAlwaysZero = false
    public var frameMbsOnly: Bool
    public var mbAdaptiveFrameField = false
    public var width: Int
    public var height: Int  // in frame lines (both fields)
    public var picStructPresent = false
    public var timeScale: UInt32 = 0
    public var numUnitsInTick: UInt32 = 0

    public var interlaced: Bool { !frameMbsOnly }
}

public struct PPS: Sendable, Equatable {
    public var id: Int
    public var spsID: Int
    public var bottomFieldPicOrderInFramePresent: Bool
}

public enum H264Parse {
    public static func sps(_ nal: NALUnit) throws -> SPS {
        var r = BitReader(unescapeRBSP(nal.bytes.dropFirst()))
        let profile = try r.u(8)
        try r.skip(8)  // constraint flags + reserved
        let level = try r.u(8)
        let id = try r.ue()
        var chroma = 1
        var separate = false
        if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(profile) {
            chroma = try r.ue()
            if chroma == 3 { separate = try r.bit() }
            _ = try r.ue()  // bit_depth_luma_minus8
            _ = try r.ue()  // bit_depth_chroma_minus8
            try r.skip(1)   // qpprime_y_zero_transform_bypass_flag
            if try r.bit() {  // seq_scaling_matrix_present_flag
                for i in 0..<(chroma != 3 ? 8 : 12) where try r.bit() {
                    try skipScalingList(&r, size: i < 6 ? 16 : 64)
                }
            }
        }
        let log2MaxFrameNum = try r.ue() + 4
        let pocType = try r.ue()
        var log2MaxPocLsb = 0
        var deltaAlwaysZero = false
        if pocType == 0 {
            log2MaxPocLsb = try r.ue() + 4
        } else if pocType == 1 {
            deltaAlwaysZero = try r.bit()
            _ = try r.se()
            _ = try r.se()
            let cycle = try r.ue()
            for _ in 0..<cycle { _ = try r.se() }
        }
        _ = try r.ue()  // max_num_ref_frames
        try r.skip(1)   // gaps_in_frame_num_value_allowed_flag
        let widthMbs = try r.ue() + 1
        let heightMapUnits = try r.ue() + 1
        let frameMbsOnly = try r.bit()
        var mbaff = false
        if !frameMbsOnly { mbaff = try r.bit() }
        try r.skip(1)  // direct_8x8_inference_flag
        var width = widthMbs * 16
        var height = heightMapUnits * 16 * (frameMbsOnly ? 1 : 2)
        if try r.bit() {  // frame_cropping_flag
            let l = try r.ue(), rt = try r.ue(), t = try r.ue(), b = try r.ue()
            let cropX = chroma == 0 || separate ? 1 : (chroma == 3 ? 1 : 2)
            let cropY = (chroma == 1 && !separate ? 2 : 1) * (frameMbsOnly ? 1 : 2)
            width -= (l + rt) * cropX
            height -= (t + b) * cropY
        }
        var sps = SPS(id: id, profileIDC: profile, levelIDC: level, chromaFormatIDC: chroma,
                      separateColourPlane: separate, log2MaxFrameNum: log2MaxFrameNum,
                      picOrderCntType: pocType, log2MaxPicOrderCntLsb: log2MaxPocLsb,
                      deltaPicOrderAlwaysZero: deltaAlwaysZero, frameMbsOnly: frameMbsOnly,
                      mbAdaptiveFrameField: mbaff, width: width, height: height)
        if try r.bit() {  // vui_parameters_present_flag
            try parseVUI(&r, into: &sps)
        }
        return sps
    }

    private static func skipScalingList(_ r: inout BitReader, size: Int) throws {
        var last = 8, next = 8
        for _ in 0..<size where next != 0 {
            next = (last + (try r.se()) + 256) % 256
            if next != 0 { last = next }
        }
    }

    private static func parseVUI(_ r: inout BitReader, into sps: inout SPS) throws {
        if try r.bit() {  // aspect_ratio_info_present_flag
            if try r.u(8) == 255 { try r.skip(32) }
        }
        if try r.bit() { try r.skip(1) }  // overscan
        if try r.bit() {  // video_signal_type_present_flag
            try r.skip(4)
            if try r.bit() { try r.skip(24) }
        }
        if try r.bit() {  // chroma_loc_info_present_flag
            _ = try r.ue()
            _ = try r.ue()
        }
        if try r.bit() {  // timing_info_present_flag
            sps.numUnitsInTick = UInt32(try r.bits(32))
            sps.timeScale = UInt32(try r.bits(32))
            try r.skip(1)
        }
        let nal = try r.bit()
        if nal { try skipHRD(&r) }
        let vcl = try r.bit()
        if vcl { try skipHRD(&r) }
        if nal || vcl { try r.skip(1) }  // low_delay_hrd_flag
        sps.picStructPresent = try r.bit()
    }

    private static func skipHRD(_ r: inout BitReader) throws {
        let count = try r.ue() + 1
        try r.skip(8)
        for _ in 0..<count {
            _ = try r.ue()
            _ = try r.ue()
            try r.skip(1)
        }
        try r.skip(20)
    }

    public static func pps(_ nal: NALUnit) throws -> PPS {
        var r = BitReader(unescapeRBSP(nal.bytes.dropFirst()))
        let id = try r.ue()
        let spsID = try r.ue()
        try r.skip(1)  // entropy_coding_mode_flag
        let bottomField = try r.bit()
        return PPS(id: id, spsID: spsID, bottomFieldPicOrderInFramePresent: bottomField)
    }

    public struct SliceHeader: Sendable, Equatable {
        public var firstMb: Int
        public var sliceType: Int
        public var ppsID: Int
        public var frameNum: Int
        public var fieldPic: Bool
        public var bottomField: Bool
        public var idr: Bool
    }

    public static func sliceHeader(_ nal: NALUnit, spsByID: [Int: SPS], ppsByID: [Int: PPS]) throws -> SliceHeader {
        // the first bytes are enough; unescape a bounded prefix
        var r = BitReader(unescapeRBSP(nal.bytes.dropFirst().prefix(48)))
        let firstMb = try r.ue()
        let sliceType = try r.ue() % 5
        let ppsID = try r.ue()
        guard let pps = ppsByID[ppsID], let sps = spsByID[pps.spsID] else {
            throw BitstreamError.invalid("slice references unknown PPS \(ppsID)")
        }
        if sps.separateColourPlane { try r.skip(2) }
        let frameNum = try r.u(sps.log2MaxFrameNum)
        var field = false, bottom = false
        if !sps.frameMbsOnly {
            field = try r.bit()
            if field { bottom = try r.bit() }
        }
        return SliceHeader(firstMb: firstMb, sliceType: sliceType, ppsID: ppsID, frameNum: frameNum,
                           fieldPic: field, bottomField: bottom, idr: nal.type == NALType.idr.rawValue)
    }

    /// True if the SEI NAL carries a recovery_point message (payload type 6)
    public static func hasRecoveryPoint(_ nal: NALUnit) -> Bool {
        let b = unescapeRBSP(nal.bytes.dropFirst())
        var i = 0
        while i < b.count, b[i] != 0x80 {
            var type = 0, size = 0
            while i < b.count, b[i] == 0xff { type += 255; i += 1 }
            guard i < b.count else { break }
            type += Int(b[i]); i += 1
            while i < b.count, b[i] == 0xff { size += 255; i += 1 }
            guard i < b.count else { break }
            size += Int(b[i]); i += 1
            if type == 6 { return true }
            i += size
        }
        return false
    }
}

/// One coded picture: a frame, or a single field (PAFF)
public struct H264AccessUnit: Sendable {
    public var nalus: [NALUnit]
    public var pts: Int64?          // unwrapped 90 kHz
    public var dts: Int64?
    public var slice: H264Parse.SliceHeader
    public var isIDR: Bool { slice.idr }
    public var recoveryPoint: Bool
    public var damaged: Bool
    public var spsID: Int
    public var ppsID: Int
}

/// A decodable sample: a frame, or a complementary field pair joined together
public struct H264Frame: Sendable {
    public var nalus: [NALUnit]     // VCL + SEI, no AUD/SPS/PPS
    public var pts: Int64?
    public var dts: Int64?
    /// The sequence is interlaced (frame_mbs_only_flag = 0), whatever this picture's coding
    public var interlaced: Bool
    /// This sample is a complementary field pair (PAFF), not a frame picture
    public var fieldPair: Bool
    public var topFieldFirst: Bool
    public var isSyncPoint: Bool    // IDR or recovery point: decoding may start here
    public var hasIDR: Bool
    public var damaged: Bool
    public var sps: SPS
    public var spsBytes: [UInt8]
    public var ppsBytes: [UInt8]
}

/// Turns video PES into access units and complementary-field frames.
public struct H264Assembler {
    public private(set) var spsByID: [Int: SPS] = [:]
    public private(set) var ppsByID: [Int: PPS] = [:]
    private var spsBytes: [Int: [UInt8]] = [:]
    private var ppsBytes: [Int: [UInt8]] = [:]
    private var ptsUnwrap = TimestampUnwrapper()
    private var dtsUnwrap = TimestampUnwrapper()
    private var pendingField: H264AccessUnit?
    public private(set) var accessUnits = 0
    public private(set) var unpairedFields = 0
    public private(set) var parseErrors = 0

    public init() {}

    public mutating func reset() {
        pendingField = nil
        ptsUnwrap.reset()
        dtsUnwrap.reset()
    }

    /// Feeds one video PES; returns the frames it completes
    public mutating func feed(_ pes: PESPacket) -> [H264Frame] {
        var frames: [H264Frame] = []
        let pts = pes.pts.map { ptsUnwrap.unwrap($0) }
        let dts = pes.dts.map { dtsUnwrap.unwrap($0) } ?? pts
        var current: [NALUnit] = []
        var slice: H264Parse.SliceHeader?
        var recovery = false
        var auIndex = 0

        func close() {
            guard let s = slice, let pps = ppsByID[s.ppsID] else {
                current.removeAll()
                return
            }
            // only the PES's first AU carries its timestamps
            let au = H264AccessUnit(nalus: current, pts: auIndex == 0 ? pts : nil, dts: auIndex == 0 ? dts : nil,
                                    slice: s, recoveryPoint: recovery, damaged: pes.damaged,
                                    spsID: pps.spsID, ppsID: s.ppsID)
            accessUnits += 1
            auIndex += 1
            frames.append(contentsOf: pair(au))
            current.removeAll()
            slice = nil
            recovery = false
        }

        for nal in splitAnnexB(pes.payload) {
            switch nal.type {
            case NALType.aud.rawValue:
                if slice != nil { close() }
            case NALType.sps.rawValue:
                if slice != nil { close() }
                if let s = try? H264Parse.sps(nal) {
                    spsByID[s.id] = s
                    spsBytes[s.id] = nal.bytes
                } else { parseErrors += 1 }
            case NALType.pps.rawValue:
                if slice != nil { close() }
                if let p = try? H264Parse.pps(nal) {
                    ppsByID[p.id] = p
                    ppsBytes[p.id] = nal.bytes
                } else { parseErrors += 1 }
            case NALType.sei.rawValue:
                if slice != nil { close() }
                if H264Parse.hasRecoveryPoint(nal) { recovery = true }
                current.append(nal)
            case 1...5:
                guard let h = try? H264Parse.sliceHeader(nal, spsByID: spsByID, ppsByID: ppsByID) else {
                    parseErrors += 1
                    continue
                }
                if slice != nil && h.firstMb == 0 { close() }  // a new picture starts
                if slice == nil { slice = h }
                current.append(nal)
            default:
                continue
            }
        }
        if slice != nil { close() }
        return frames
    }

    private mutating func pair(_ au: H264AccessUnit) -> [H264Frame] {
        guard au.slice.fieldPic else {
            var out: [H264Frame] = []
            if pendingField != nil {
                unpairedFields += 1
                pendingField = nil
            }
            if let f = makeFrame([au]) { out.append(f) }
            return out
        }
        if let first = pendingField {
            if first.slice.bottomField != au.slice.bottomField && first.slice.frameNum == au.slice.frameNum {
                pendingField = nil
                return makeFrame([first, au]).map { [$0] } ?? []
            }
            unpairedFields += 1
        }
        pendingField = au
        return []
    }

    private func makeFrame(_ aus: [H264AccessUnit]) -> H264Frame? {
        let first = aus[0]
        guard let sps = spsByID[first.spsID], let spsB = spsBytes[first.spsID],
              let ppsB = ppsBytes[first.ppsID] else { return nil }
        return H264Frame(nalus: aus.flatMap(\.nalus),
                         pts: aus.compactMap(\.pts).min(), dts: aus.compactMap(\.dts).min(),
                         interlaced: sps.interlaced, fieldPair: first.slice.fieldPic,
                         topFieldFirst: !first.slice.bottomField,
                         isSyncPoint: aus.contains { $0.isIDR || $0.recoveryPoint },
                         hasIDR: aus.contains(where: \.isIDR),
                         damaged: aus.contains(where: \.damaged), sps: sps, spsBytes: spsB, ppsBytes: ppsB)
    }
}
