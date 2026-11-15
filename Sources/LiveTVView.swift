import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    @State private var playlistAddress = ""

    var body: some View {
        NavigationStack {
            Group {
                if model.channels.isEmpty {
                    ContentUnavailableView {
                        Label("No Channels", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Add the address of an extended M3U playlist.")
                    } actions: {
                        Button("Import Playlist") { importing = true }
                    }
                } else {
                    List(model.channels) { channel in
                        NavigationLink(value: channel) {
                            ChannelRow(channel: channel)
                        }
                    }
                }
            }
            .navigationTitle("Live TV")
            .toolbar { Button("Import", systemImage: "square.and.arrow.down") { importing = true } }
            .navigationDestination(for: Channel.self) { PlayerView(channel: $0) }
            .sheet(isPresented: $importing) {
                NavigationStack {
                    Form {
                        TextField("https://provider.example/playlist.m3u", text: $playlistAddress)
                            .textContentType(.URL)
                        Text("The address and imported metadata stay in app memory and are never logged.")
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Add Playlist")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { importing = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Import") {
                                let address = playlistAddress
                                importing = false
                                Task { await model.importPlaylist(from: address) }
                            }
                            .disabled(playlistAddress.isEmpty)
                        }
                    }
                }
            }
            .alert("Playlist Import", isPresented: Binding(
                get: { model.importMessage != nil },
                set: { if !$0 { model.importMessage = nil } }
            )) { Button("OK") { model.importMessage = nil } } message: {
                Text(model.importMessage ?? "")
            }
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(channel.name).font(.headline)
            Text("\(channel.group) · \(channel.capability.container.rawValue) · \(channel.capability.drm.rawValue)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

