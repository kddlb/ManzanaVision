// SPDX-License-Identifier: GPL-2.0-only
import SwiftUI

@main
struct ManzanaVisionApp: App {
    @State private var model = AppModel()
    @State private var pip = PictureInPicture()

    var body: some Scene {
        Window("ManzanaVision", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 405)
                .onAppear { pip.attach(to: model.layer) }
        }
        .defaultSize(width: 1180, height: 620)
        .commands {
            CommandMenu("Channel") {
                Button("Next Channel") { model.step(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Channel") { model.step(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button(model.showHUD ? "Hide Signal Info" : "Show Signal Info") { model.showHUD.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Picture in Picture") { pip.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .control])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
