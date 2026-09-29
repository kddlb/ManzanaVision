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
                .onAppear {
                    pip.attach(to: model.layer)
                    pip.activeChanged = { [model] in model.pictureInPicture = $0 }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.applicationWillTerminate()
                }
        }
        .defaultSize(width: 1180, height: 620)
        .commands {
            SidebarCommands()  // the View menu, where macOS adds Enter Full Screen
            CommandGroup(replacing: .importExport) {
                Button("Export Recording for QuickTime…") { model.chooseRecordingToExport() }
                    .keyboardShortcut("e")
                    .disabled(model.export?.isRunning == true)
            }
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
                Toggle("Closed Captions", isOn: Bindable(model).showCaptions)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Divider()
                if model.recording != nil {
                    Button("Stop Recording") { model.stopRecording() }
                        .keyboardShortcut("r")
                } else {
                    Button("Start Recording") { model.startRecording() }
                        .keyboardShortcut("r")
                        .disabled(!model.canRecord)
                }
                Menu("Record For") {
                    ForEach([30, 60, 120, 180], id: \.self) { minutes in
                        Button(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))) {
                            model.startRecording(for: .seconds(minutes * 60))
                        }
                    }
                }
                .disabled(!model.canRecord)
                Button("Show Recordings") { model.showRecordings() }
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
