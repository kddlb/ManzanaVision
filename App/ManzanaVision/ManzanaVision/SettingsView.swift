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
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 280)
    }
}
