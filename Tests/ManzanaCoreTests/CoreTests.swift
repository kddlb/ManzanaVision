// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ManzanaCore
import Testing

/// Recorded clips from scripts/make-fixtures.sh (broadcast content, kept out of git)
enum Fixtures {
    static let dir: URL? = ProcessInfo.processInfo.environment["MANZANA_FIXTURES"].map {
        URL(fileURLWithPath: $0, isDirectory: true)
    }

    static func url(_ name: String) -> URL? {
        guard let url = dir?.appendingPathComponent(name),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static let rf27 = url("rf27-5min-20s.ts")
    static let rf32 = url("rf32-5min-20s.ts")
}

func services(of mux: mzv_mux) -> [(virtual: String, name: String, kind: String, sid: UInt16)] {
    withUnsafeBytes(of: mux.services) { raw in
        let all = raw.bindMemory(to: mzv_service.self)
        return all.prefix(Int(mux.nservices)).filter(\.listed).map { s in
            var s = s
            let name = withUnsafeBytes(of: &s.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            let kind = withUnsafeBytes(of: &s.kind) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            return ("\(s.major).\(s.minor)", name, kind, s.service_id)
        }
    }
}

func muxFromFile(_ url: URL, rf: Int32) throws -> mzv_mux {
    let data = try Data(contentsOf: url)
    var mux = mzv_mux()
    data.withUnsafeBytes { raw in
        mzv_mux_from_packets(raw.bindMemory(to: UInt8.self).baseAddress, data.count / 188, rf, &mux)
    }
    return mux
}

@Suite struct Frequencies {
    @Test func abntChannelPlan() {
        #expect(mzv_rf_frequency(14) == 473_142_857)
        #expect(mzv_rf_frequency(22) == 521_142_857)
        #expect(mzv_rf_frequency(38) == 617_142_857)
    }

    @Test func tmccNames() {
        #expect(String(cString: mzv_modulation_name(MZV_MOD_QAM64)) == "64QAM")
        #expect(String(cString: mzv_code_rate_name(MZV_FEC_3_4)) == "3/4")
        #expect(String(cString: mzv_guard_interval_name(8)) == "1/8")
    }
}

@Suite(.enabled(if: Fixtures.rf27 != nil && Fixtures.rf32 != nil, "set MANZANA_FIXTURES"))
struct RecordedPSI {
    @Test func megaServices() throws {
        let mux = try muxFromFile(Fixtures.rf27!, rf: 27)
        #expect(mux.have_pat && mux.have_sdt && mux.have_nit)
        #expect(mux.transport_stream_id == 0x0930)
        let s = services(of: mux)
        #expect(s.map(\.virtual) == ["9.1", "9.2", "9.31"])
        #expect(s.map(\.name) == ["MEGA HD", "MEGA 2 HD", "MEGA MOVIL"])
        #expect(s.last?.kind == "1seg")
    }

    @Test func cncServices() throws {
        let mux = try muxFromFile(Fixtures.rf32!, rf: 32)
        let s = services(of: mux)
        #expect(s.map(\.virtual) == ["14.1", "14.2", "14.3", "14.4"])
        #expect(s.map(\.name).contains("Tevex"))
    }
}

@Suite(.enabled(if: Fixtures.rf27 != nil, "set MANZANA_FIXTURES"))
struct ProgramFilter {
    /// Runs the filter over the whole clip and returns the output packets
    func filtered(sid: UInt16) throws -> (out: Data, program: mzv_program?) {
        let data = try Data(contentsOf: Fixtures.rf27!)
        let n = data.count / 188
        var out = Data(count: n * 188)
        let f = mzv_filter_new(sid, true)
        defer { mzv_filter_free(f) }
        let kept = data.withUnsafeBytes { inp in
            out.withUnsafeMutableBytes { outp in
                mzv_filter_feed(f, inp.bindMemory(to: UInt8.self).baseAddress, n,
                                outp.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        out.count = kept * 188
        var prog = mzv_program()
        return (out, mzv_filter_program(f, &prog) ? prog : nil)
    }

    @Test func keepsOnlyTheProgram() throws {
        let (out, program) = try filtered(sid: 0x2600)
        let prog = try #require(program)
        let esPids = withUnsafeBytes(of: prog.es) { raw in
            raw.bindMemory(to: mzv_es.self).prefix(Int(prog.nes)).map(\.pid)
        }
        let allowed = Set([0, prog.pmt_pid, prog.pcr_pid] + esPids)
        var seen = Set<UInt16>()
        out.withUnsafeBytes { raw in
            let b = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: b.count, by: 188) {
                #expect(b[i] == 0x47)
                seen.insert(UInt16(b[i + 1] & 0x1f) << 8 | UInt16(b[i + 2]))
            }
        }
        #expect(prog.pmt_pid == 0x0064)
        #expect(seen.isSubset(of: allowed))
        #expect(seen.contains(0) && seen.contains(prog.pmt_pid))
    }

    @Test func rewrittenPATListsOnlyTheService() throws {
        let (out, _) = try filtered(sid: 0x2600)
        var mux = mzv_mux()
        out.withUnsafeBytes { raw in
            mzv_mux_from_packets(raw.bindMemory(to: UInt8.self).baseAddress, out.count / 188, 0, &mux)
        }
        #expect(mux.have_pat)
        let inPAT = withUnsafeBytes(of: mux.services) { raw in
            raw.bindMemory(to: mzv_service.self).prefix(Int(mux.nservices)).filter(\.in_pat).map(\.service_id)
        }
        #expect(inPAT == [0x2600])
    }
}

@Suite struct ChannelList {
    @Test func saveLoadFind() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("mzv-\(UUID().uuidString)/channels.tsv").path
        var list = mzv_channel_list()
        defer { mzv_channels_free(&list) }

        var mux = mzv_mux()
        mux.rf = 27
        mux.signal.has_lock = true
        mux.have_psi = true
        mux.have_pat = true
        mux.nservices = 2
        withUnsafeMutableBytes(of: &mux.services) { raw in
            let s = raw.bindMemory(to: mzv_service.self)
            for (i, (minor, sid, name)) in [(1, UInt16(0x2600), "MEGA HD"), (31, 0x2618, "MEGA MOVIL")].enumerated() {
                s[i].listed = true
                s[i].in_pat = true
                s[i].major = 9
                s[i].minor = Int32(minor)
                s[i].service_id = sid
                withUnsafeMutableBytes(of: &s[i].name) { n in
                    _ = name.utf8CString.withUnsafeBytes { memcpy(n.baseAddress!, $0.baseAddress!, $0.count) }
                }
            }
        }
        #expect(mzv_channels_merge_mux(&list, &mux))
        #expect(mzv_channels_save(path, &list) == MZV_OK.rawValue)

        var loaded = mzv_channel_list()
        defer { mzv_channels_free(&loaded) }
        #expect(mzv_channels_load(path, &loaded) == MZV_OK.rawValue)
        #expect(loaded.count == 2)
        #expect(mzv_channels_find(&loaded, "9.31")?.pointee.service_id == 0x2618)
        #expect(mzv_channels_find(&loaded, "9")?.pointee.minor == 1)
        #expect(mzv_channels_find(&loaded, "mega hd")?.pointee.service_id == 0x2600)
        #expect(mzv_channels_find(&loaded, "13.1") == nil)
    }

    @Test func missingFileIsEmpty() {
        var list = mzv_channel_list()
        #expect(mzv_channels_load("/nonexistent/channels.tsv", &list) == MZV_OK.rawValue)
        #expect(list.count == 0)
    }
}
