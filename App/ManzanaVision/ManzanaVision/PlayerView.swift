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
        let lost = if case .signalLost = model.status { true } else { false }
        ZStack {
            // the picture stays in the detail area; only the black extends under the sidebar
            Color.black.ignoresSafeArea()
            // the frozen picture slowly blurs and fades while re-tuning, and snaps back on recovery
            VideoLayerView(layer: model.layer)
                .blur(radius: lost ? 30 : 0, opaque: true)
                .saturation(lost ? 0.2 : 1)
                .brightness(lost ? -0.2 : 0)
                .animation(lost ? .easeIn(duration: 4) : .easeOut(duration: 0.4), value: lost)
                .allowsHitTesting(false)
            StatusOverlay(showingScan: $showingScan)
            VStack {
                HStack(alignment: .top) {
                    ChannelOSD()
                    Spacer()
                    if model.showHUD {
                        SignalHUD().modifier(SlideIn(edge: .trailing))
                    }
                }
                Spacer()
                ReceptionBadge()
            }
            .padding()
            .animation(.snappy, value: model.showHUD)
        }
        .background(.black)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
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
            // cancels a channel number being typed, else leaves full screen
            if !model.entry.isEmpty {
                model.cancelEntry()
            } else if let window = NSApp.keyWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
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
                      Text("ManzanaVision plays TV from a DiBcom STK8096GP USB tuner. Connect it to start watching."))
            case .tunerBusy:
                panel("Tuner In Use", "exclamationmark.lock",
                      Text("Another program is using the tuner (for example the manzanavision command-line tool). Close it to watch here."))
            case .firmwareProblem(let why):
                panel("Tuner Firmware Problem", "exclamationmark.triangle", Text(firmwareMessage(why)))
            case .starting:
                progress("Starting the tuner…")
            case .tuning(let c):
                progress("Tuning \(c.virtual) \(c.name)…")
            case .noSignal(let c):
                panel("No Signal", "antenna.radiowaves.left.and.right.slash",
                      Text("Nothing is being received on RF \(c.rf). Check the antenna, or scan again."))
            case .signalLost:
                // the last picture stays up (blurred); say why it's frozen
                VStack {
                    Spacer()
                    Label("Signal lost — re-tuning", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .padding(10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 48)
                }
                .modifier(SlideIn(edge: .bottom))
            case .disconnected:
                panel("Tuner Unplugged", "cable.connector.slash",
                      Text("Plug the tuner back in to continue watching."))
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
        .animation(.smooth, value: model.status)
    }

    private func panel(_ title: LocalizedStringKey, _ symbol: String, _ text: Text) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: text)
            .foregroundStyle(.white)
            .background(.black.opacity(0.6))
            .transition(.opacity)
    }

    private func progress(_ text: LocalizedStringKey) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(text).foregroundStyle(.white)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .transition(.scale(0.9).combined(with: .opacity))
    }
}

/// Channel banner after a zap, or the number being typed
struct ChannelOSD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !model.entry.isEmpty {
                box {
                    Text(model.entry + "_")
                        .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                }
                .transition(.opacity)
            } else if let c = model.banner {
                box {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.virtual).font(.system(size: 36, weight: .semibold, design: .rounded).monospacedDigit())
                        Text(c.name).font(.title3)
                    }
                }
                .id(c.id)  // a zap replaces the banner rather than editing it
                .modifier(SlideIn(edge: .leading))
            }
        }
        .animation(.snappy, value: model.banner)
        .animation(.snappy(duration: 0.2), value: model.entry)
    }

    private func box(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A small warning when watching through bad reception
struct ReceptionBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let warning: Reception? = if case .playing(_, let r) = model.status, r != .good { r } else { nil }
        HStack {
            if let r = warning {
                Label(r == .poor ? LocalizedStringKey("Poor reception") : "Weak reception",
                      systemImage: r == .poor ? "wifi.exclamationmark" : "wifi")
                    .contentTransition(.symbolEffect(.replace))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(r == .poor ? .orange : .yellow)
                    .modifier(SlideIn(edge: .bottom))
            }
            Spacer()
        }
        .animation(.snappy, value: warning)
    }
}

/// Slides an overlay in from its edge, or just fades it with Reduce Motion on
struct SlideIn: ViewModifier {
    let edge: Edge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity))
    }
}

/// FirmwareStore and the core report these in English; say them in the user's language
func firmwareMessage(_ why: String) -> String {
    switch why {
    case "firmware file not found":
        String(localized: "The tuner firmware file is missing. Reinstall ManzanaVision.")
    case "firmware file doesn't match the expected checksum":
        String(localized: "The tuner firmware file is damaged. Reinstall ManzanaVision.")
    case "rejected by the tuner":
        String(localized: "The tuner rejected its firmware. Unplug it and plug it back in.")
    default:
        why
    }
}
