// SPDX-License-Identifier: GPL-2.0-only
import ManzanaTuner
import SwiftUI

struct ScanSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("scanFrom") private var from = 14
    @AppStorage("scanTo") private var to = 51

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan for Channels").font(.title2.bold())
            if let scan = model.scan {
                ScanProgressView(scan: scan)
            } else {
                Text("Tunes each UHF channel in the range and saves the services it finds. Playback stops while scanning.")
                    .foregroundStyle(.secondary)
                HStack {
                    Stepper("From RF \(from)", value: $from, in: 14...to)
                    Stepper("To RF \(to)", value: $to, in: from...69)
                }
            }
            HStack {
                Spacer()
                if let scan = model.scan, scan.running {
                    Button("Stop", role: .cancel) { scan.cancel() }
                } else {
                    Button(model.scan == nil ? "Cancel" : "Done") {
                        model.scan = nil
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    if model.scan == nil {
                        Button("Scan") { model.startScan(from: from, to: to) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .frame(minHeight: 200)
    }
}

struct ScanProgressView: View {
    let scan: ScanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: scan.running ? scan.progress : 1) {
                if scan.running, let rf = scan.current {
                    Text("RF \(rf) of \(scan.from)–\(scan.to)…")
                } else if let failure = scan.failure {
                    Text("Scan stopped: \(failure)").foregroundStyle(.red)
                } else {
                    Text("Found \(scan.found.reduce(0) { $0 + ($1.mux?.services.count ?? 0) }) channels on \(scan.found.count) frequencies.")
                }
            }
            List(scan.rows.reversed()) { row in
                if let m = row.mux {
                    ScanRow(mux: m)
                }
            }
            .frame(height: 260)
        }
    }
}

struct ScanRow: View {
    let mux: Mux

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("RF \(mux.rf)").monospacedDigit().frame(width: 52, alignment: .leading)
            if mux.signal.hasLock {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text(mux.services.map { "\($0.virtual) \($0.name)" }.joined(separator: " · "))
                        .lineLimit(2)
                    Text([mux.signal.snr > 0 ? String(format: "SNR %.1f dB", mux.signal.snr) : nil,
                          mux.hasPAT ? nil : "HD layer not decoding"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "minus.circle").foregroundStyle(.secondary)
                Text(mux.signal.hasSignal ? "Signal, no lock" : "Nothing").foregroundStyle(.secondary)
            }
        }
    }
}
