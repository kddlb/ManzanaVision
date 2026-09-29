// SPDX-License-Identifier: GPL-2.0-only
import ManzanaPlayback
import ManzanaStream
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
            if model.pictureInPicture {
                // the video layer is sized for the PiP panel meanwhile
                ContentUnavailableView("Playing in Picture in Picture", systemImage: "pip",
                                       description: Text("Choose Channel → Picture in Picture to bring it back."))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .transition(.opacity)
            }
            CaptionOverlay()
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
                HStack(alignment: .bottom) {
                    ReceptionBadge()
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        ExportBadge()
                        RecordingBadge()
                    }
                }
            }
            .padding()
            .animation(.snappy, value: model.showHUD)
        }
        .background(.black)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.recording != nil {
                    Button("Stop Recording", systemImage: "stop.circle.fill") { model.stopRecording() }
                        .foregroundStyle(.red)
                        .help("Stop recording")
                } else {
                    Button("Record", systemImage: "record.circle") { model.startRecording() }
                        .disabled(!model.canRecord)
                        .help("Record this channel")
                }
            }
        }
        .confirmationDialog("Stop Recording?", isPresented: Binding(get: { model.pendingZap != nil },
                                                                   set: { if !$0 { model.pendingZap = nil } }),
                            presenting: model.pendingZap) { channel in
            Button("Stop Recording and Watch \(channel.virtual) \(channel.name)", role: .destructive) { model.confirmZap() }
            Button("Keep Recording", role: .cancel) {}
        } message: { _ in
            Text("There's only one tuner, so changing channel ends the recording.")
        }
        .alert("Recording Stopped", isPresented: Binding(get: { model.recordingError != nil },
                                                         set: { if !$0 { model.recordingError = nil } }),
               presenting: model.recordingError) { _ in
            Button("OK") {}
        } message: { why in
            Text(why)
        }
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

/// Closed captions, laid out on the picture where the broadcaster placed them
struct CaptionOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let page = model.caption
        let playing = if case .playing = model.status { true } else { false }
        GeometryReader { geo in
            // in Picture in Picture the captions are in the picture instead
            if model.showCaptions, !model.pictureInPicture, playing, !page.isEmpty {
                let picture = pictureRect(in: geo.size)
                let scale = picture.height / CGFloat(page.height)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(page.lines.enumerated()), id: \.offset) { _, line in
                        CaptionLineView(line: line, scale: scale)
                            .frame(maxWidth: max(0, picture.maxX - picture.minX - CGFloat(line.x) * scale), alignment: .leading)
                            .offset(x: picture.minX + CGFloat(line.x) * scale, y: picture.minY + CGFloat(line.y) * scale)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(page.text)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .allowsHitTesting(false)
    }

    /// Where the picture is drawn: aspect-fit, like the video layer
    private func pictureRect(in size: CGSize) -> CGRect {
        let video = model.stats.videoSize
        let aspect = video.width > 0 && video.height > 0 ? video.width / video.height
            : CGFloat(model.caption.width) / CGFloat(model.caption.height)
        let width = min(size.width, size.height * aspect)
        let height = width / aspect
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }
}

/// One caption row: its runs in their colours, on the broadcaster's background
struct CaptionLineView: View {
    let line: CaptionLine
    let scale: CGFloat

    var body: some View {
        let background = line.runs.first?.background ?? .clear
        let uniform = line.runs.allSatisfy { $0.background == background }
        let fontSize = CGFloat(line.runs.map(\.fontSize).max() ?? 24) * scale
        Text(attributed(perRunBackground: !uniform))
            .font(.system(size: fontSize * 0.9, weight: .medium))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, uniform && background.alpha > 0 ? fontSize * 0.2 : 0)
            .frame(height: CGFloat(line.height) * scale)
            .background(uniform ? Color(background) : .clear)
            // captions with no box of their own still need to stand out from the picture
            .shadow(color: .black.opacity(background.alpha == 0 ? 0.9 : 0), radius: 2)
    }

    private func attributed(perRunBackground: Bool) -> AttributedString {
        var text = AttributedString()
        for run in line.runs {
            var part = AttributedString(run.text)
            part.foregroundColor = Color(run.foreground)
            if perRunBackground { part.backgroundColor = Color(run.background) }
            if run.underline { part.underlineStyle = .single }
            if run.italic || run.bold {
                part.font = .system(size: CGFloat(run.fontSize) * scale * 0.9,
                                    weight: run.bold ? .bold : .medium).italic(run.italic)
            }
            text += part
        }
        return text
    }
}

extension Color {
    init(_ c: CaptionColor) {
        self.init(.sRGB, red: Double(c.red) / 255, green: Double(c.green) / 255, blue: Double(c.blue) / 255,
                  opacity: Double(c.alpha) / 255)
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
        ZStack {
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
        }
        .animation(.snappy, value: warning)
    }
}

/// An export's progress, then its result
struct ExportBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let job = model.export {
                HStack(spacing: 8) {
                    switch job.state {
                    case .running(let p):
                        ProgressView(value: p).frame(width: 90)
                        Text("Exporting \(job.name)").lineLimit(1).truncationMode(.middle)
                        Text(p.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Cancel Export", systemImage: "xmark.circle.fill") { model.dismissExport() }
                    case .done:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("Exported \(job.name)").lineLimit(1).truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([job.destination]) }
                        Button("Dismiss", systemImage: "xmark.circle.fill") { model.dismissExport() }
                    case .failed(let why):
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Export failed: \(why)").lineLimit(2)
                        Button("Dismiss", systemImage: "xmark.circle.fill") { model.dismissExport() }
                    }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.white)
                .frame(maxWidth: 520, alignment: .trailing)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .modifier(SlideIn(edge: .bottom))
            }
        }
        .animation(.snappy, value: model.export?.phase)  // not on every progress tick
        .animation(.snappy, value: model.export == nil)
    }
}

/// "● REC 0:12:34 · 1.2 GB" while recording
struct RecordingBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if let rec = model.recording {
                TimelineView(.periodic(from: rec.recorder.started, by: 1)) { context in
                    let elapsed = Duration.seconds(max(0, context.date.timeIntervalSince(rec.recorder.started).rounded(.down)))
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse)
                        Text("REC").fontWeight(.bold)
                        Text(elapsed.formatted(.time(pattern: .hourMinuteSecond)))
                        Text(model.recordedBytes.formatted(.byteCount(style: .file)))
                            .foregroundStyle(.secondary)
                        if let stopAt = rec.stopAt {
                            Text("until \(stopAt.formatted(date: .omitted, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .modifier(SlideIn(edge: .bottom))
            }
        }
        .animation(.snappy, value: model.recording == nil)
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
