// SPDX-License-Identifier: GPL-2.0-only
import ManzanaTV
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
            SidebarCommands()  // the View menu, where macOS adds Enter Full Screen
            CommandMenu("Channel") {
                Button("Next Channel") { model.step(1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
                Button("Previous Channel") { model.step(-1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Divider()
                Button(model.showHUD ? LocalizedStringKey("Hide Signal Info") : "Show Signal Info") { model.showHUD.toggle() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("Picture in Picture") { pip.toggle() }
                    .keyboardShortcut("p", modifiers: [.command, .control])
                if let recordings = model.session as? RecordingSession {
                    Divider()
                    Button("Simulate Signal Loss") { recordings.simulateSignalLoss(for: .seconds(6)) }
                        .keyboardShortcut("l", modifiers: [.command, .control])
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
