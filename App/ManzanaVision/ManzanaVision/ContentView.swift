// SPDX-License-Identifier: GPL-2.0-only
import ManzanaTuner
import ManzanaTV
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var showingScan = false

    var body: some View {
        NavigationSplitView {
            ChannelList(showingScan: $showingScan)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            PlayerView(showingScan: $showingScan)
        }
        .sheet(isPresented: $showingScan) {
            ScanSheet()
        }
    }
}

struct ChannelList: View {
    @Environment(AppModel.self) private var model
    @Binding var showingScan: Bool

    var body: some View {
        let selection = Binding<Channel.ID?>(
            get: { model.current?.id },
            set: { id in if let c = model.channels.first(where: { $0.id == id }) { model.play(c) } })
        Group {
            if model.visibleChannels.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "antenna.radiowaves.left.and.right")
                } description: {
                    Text("Scan for channels to fill the list.")
                } actions: {
                    Button("Scan…") { showingScan = true }
                }
            } else {
                List(selection: selection) {
                    ForEach(model.groups, id: \.major) { group in
                        Section(group.title) {
                            ForEach(group.channels) { channel in
                                ChannelRow(channel: channel).tag(channel.id)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Scan", systemImage: "arrow.clockwise") { showingScan = true }
                    .help("Scan for channels")
            }
        }
        .navigationTitle("Channels")
    }
}

struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack {
            Text(channel.virtual)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 40, alignment: .trailing)
            Text(channel.name)
                .lineLimit(1)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    private var badge: String? {
        switch channel.kind {
        case "1seg": "1SEG"
        case "radio": "RADIO"
        case "data": "DATA"
        default: nil
        }
    }
}
