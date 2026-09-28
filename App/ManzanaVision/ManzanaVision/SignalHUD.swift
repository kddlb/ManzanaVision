// SPDX-License-Identifier: GPL-2.0-only
import ManzanaPlayback
import ManzanaTuner
import ManzanaTV
import SwiftUI

/// Signal and playback details (⌘I)
struct SignalHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.stats
        VStack(alignment: .leading, spacing: 6) {
            if let c = model.current {
                Text("\(c.virtual) \(c.name) · RF \(c.rf)").font(.headline)
            }
            if let sig = model.signal {
                meter("SNR", value: sig.snr, max: 30, text: String(format: "%.1f dB", sig.snr))
                meter("Level", value: Double(sig.strengthPercent), max: 100, text: "\(sig.strengthPercent)%")
                HStack(spacing: 6) {
                    Text("Layers").frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
                    ForEach(0..<3, id: \.self) { l in
                        layerChip(l, locked: sig.layerLocked(l))
                    }
                }
                row("Errors", String(format: "%.0f packets/s", sig.errorsPerSecond))
            } else {
                row("Signal", "—")
            }
            if let t = model.tmcc {
                row("TMCC", "mode \(t.mode), GI \(t.guardInterval)")
            }
            Divider()
            row("Video", videoText(s))
            row("Audio", s.audioDescription.isEmpty ? "—" : s.audioDescription)
            row("Buffer", String(format: "video %.1f s, audio %.1f s", s.videoBuffer, s.audioBuffer))
            row("Damage", "\(s.continuityErrors) CC errors, \(s.decodeErrors) decode errors")
            row("Recovery", "\(s.restarts) restarts, \(s.stalls) stalls, \(s.rebuffers) rebuffers")
        }
        .font(.caption.monospacedDigit())
        .padding(12)
        .frame(width: 330)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func videoText(_ s: PlaybackStats) -> String {
        guard s.videoSize != .zero else { return "—" }
        var text = "\(Int(s.videoSize.width))×\(Int(s.videoSize.height))\(s.interlaced ? "i" : "p")"
        if s.deinterlace != .off {
            text += " · \(s.deinterlace.rawValue)"
            if s.deinterlaceGPUms > 0 { text += String(format: " %.1f ms", s.deinterlaceGPUms) }
        }
        return text
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func meter(_ label: String, value: Double, max: Double, text: String) -> some View {
        HStack {
            Text(label).frame(width: 58, alignment: .leading).foregroundStyle(.secondary)
            ProgressView(value: min(Swift.max(value, 0), max), total: max)
                .progressViewStyle(.linear)
            Text(text).frame(width: 64, alignment: .trailing)
        }
    }

    private func layerChip(_ layer: Int, locked: Bool) -> some View {
        let name = ["A", "B", "C"][layer]
        let info = model.tmcc?.layers[layer]
        let used = info.map { $0.segments > 0 } ?? (layer < 2)
        let detail = info.map { $0.segments > 0 ? "\($0.modulation) \($0.codeRate)" : "" } ?? ""
        return HStack(spacing: 3) {
            Image(systemName: locked ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(locked ? .green : (used ? .red : .secondary))
            Text(detail.isEmpty ? name : "\(name) \(detail)")
        }
        .opacity(used ? 1 : 0.4)
    }
}
