// SPDX-License-Identifier: GPL-2.0-only
import ManzanaPlayback
import ManzanaTuner
import ManzanaTV
import SwiftUI

struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Binding var showingScan: Bool
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // the picture stays in the detail area; only the black extends under the sidebar
            Color.black.ignoresSafeArea()
            VideoLayerView(layer: model.layer)
            StatusOverlay(showingScan: $showingScan)
            VStack {
                HStack(alignment: .top) {
                    ChannelOSD()
                    Spacer()
                    if model.showHUD { SignalHUD() }
                }
                Spacer()
                ReceptionBadge()
            }
            .padding()
        }
        .background(.black)
        .navigationTitle(model.current.map { "\($0.virtual) \($0.name)" } ?? "ManzanaVision")
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(characters: .decimalDigits.union(CharacterSet(charactersIn: ".")), phases: .down) { press in
            press.characters.forEach { model.type($0) }
            return .handled
        }
        .onKeyPress(.return) {
            model.commitEntry()
            return .handled
        }
        .onKeyPress(.escape) {
            model.cancelEntry()
            return .handled
        }
        .onKeyPress(.pageUp) {
            model.step(-1)
            return .handled
        }
        .onKeyPress(.pageDown) {
            model.step(1)
            return .handled
        }
    }
}

/// Full-picture explanations for every state that isn't "playing"
struct StatusOverlay: View {
    @Environment(AppModel.self) private var model
    @Binding var showingScan: Bool

    var body: some View {
        Group {
            switch model.status {
            case .playing:
                EmptyView()
            case .noTuner:
                panel("Plug In Your Tuner", "cable.connector",
                      "ManzanaVision plays TV from a DiBcom STK8096GP USB tuner. Connect it to start watching.")
            case .tunerBusy:
                panel("Tuner In Use", "exclamationmark.lock",
                      "Another program is using the tuner (for example the manzanavision command-line tool). Close it to watch here.")
            case .firmwareProblem(let why):
                panel("Tuner Firmware Problem", "exclamationmark.triangle", why.capitalizedFirst)
            case .starting:
                progress("Starting the tuner…")
            case .tuning(let c):
                progress("Tuning \(c.virtual) \(c.name)…")
            case .noSignal(let c):
                panel("No Signal", "antenna.radiowaves.left.and.right.slash",
                      "Nothing is being received on RF \(c.rf). Check the antenna, or scan again.")
            case .signalLost:
                // the last picture stays up; say why it's frozen
                VStack {
                    Spacer()
                    Label("Signal lost — re-tuning", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 48)
                }
            case .disconnected:
                panel("Tuner Unplugged", "cable.connector.slash",
                      "Plug the tuner back in to continue watching.")
            case .scanning(let rf):
                progress("Scanning RF \(rf)…")
            case .stopped:
                if model.visibleChannels.isEmpty {
                    ContentUnavailableView {
                        Label("No Channels Yet", systemImage: "tv")
                    } description: {
                        Text("Scan to find the channels you can receive.")
                    } actions: {
                        Button("Scan…") { showingScan = true }
                    }
                    .foregroundStyle(.white)
                }
            }
        }
        .animation(.default, value: model.status)
    }

    private func panel(_ title: String, _ symbol: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(text))
            .foregroundStyle(.white)
            .background(.black.opacity(0.6))
    }

    private func progress(_ text: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Channel banner after a zap, or the number being typed
struct ChannelOSD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.entry.isEmpty {
                Text(model.entry + "_")
                    .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
            } else if let c = model.banner {
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.virtual).font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(c.name).font(.title3)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(model.entry.isEmpty && model.banner == nil ? 0 : 1),
                    in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.2), value: model.banner)
        .animation(.easeOut(duration: 0.1), value: model.entry)
    }
}

/// A small warning when watching through bad reception
struct ReceptionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if case .playing(_, let r) = model.status, r != .good {
            HStack {
                Label(r == .poor ? "Poor reception" : "Weak reception",
                      systemImage: r == .poor ? "wifi.exclamationmark" : "wifi")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(r == .poor ? .orange : .yellow)
                Spacer()
            }
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
