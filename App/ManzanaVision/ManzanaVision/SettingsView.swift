// SPDX-License-Identifier: GPL-2.0-only
import ManzanaPlayback
import ManzanaTuner
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Picker("Deinterlacing", selection: $model.deinterlace) {
                    Text("Automatic (YADIF, 60 fps)").tag(DeinterlaceMode.auto)
                    Text("YADIF").tag(DeinterlaceMode.yadif)
                    Text("Bob").tag(DeinterlaceMode.bob)
                    Text("Decoder (30 fps, lowest power)").tag(DeinterlaceMode.decoder)
                    Text("Off").tag(DeinterlaceMode.off)
                }
                Toggle("Show one-seg (mobile) channels", isOn: $model.showOneSeg)
            }
            .tabItem { Label("Playback", systemImage: "play.rectangle") }

            Form {
                LabeledContent("Channel list", value: ChannelStore.defaultURL.path)
                LabeledContent("Firmware") {
                    Text((try? FirmwareStore.locate().path) ?? String(localized: "not found"))
                        .textSelection(.enabled)
                }
                if let dir = model.recordingsDirectory {
                    LabeledContent("Playing recordings from", value: dir.path)
                }
                Button("Show Licences") {
                    if let url = Bundle.main.resourceURL?.appendingPathComponent("Licenses") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .tabItem { Label("Tuner", systemImage: "antenna.radiowaves.left.and.right") }

            Form {
                LabeledContent("Save recordings in") {
                    Text(model.recordingsFolder.path).textSelection(.enabled)
                }
                HStack {
                    Button("Choose…") { chooseRecordingsFolder() }
                    Button("Show in Finder") { model.showRecordings() }
                    if model.recordingsFolder != AppModel.defaultRecordingsFolder {
                        Button("Use Default") { model.recordingsFolder = AppModel.defaultRecordingsFolder }
                    }
                }
                Text("Recordings are saved as broadcast, in MPEG-TS, and play in VLC, IINA or mpv. For QuickTime, Photos or an iPhone, use File → Export Recording for QuickTime.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .tabItem { Label("Recordings", systemImage: "record.circle") }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 280)
    }

    private func chooseRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.recordingsFolder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { model.recordingsFolder = url }
    }
}
