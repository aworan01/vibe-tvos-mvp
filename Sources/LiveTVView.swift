import SwiftUI

struct LiveTVView: View {
    @EnvironmentObject private var model: AppModel
    @State private var importing = false
    @State private var playlistAddress = ""
    @State private var uploadServer: PlaylistUploadServer?
    @State private var uploadStatus = "Starting local upload…"

    var body: some View {
        NavigationStack {
            Group {
                if model.channels.isEmpty {
                    ContentUnavailableView {
                        Label("No Channels", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Add a playlist URL or upload an M3U file from another device.")
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
                        Section("Upload from this network") {
                            Text(uploadStatus)
                            Text("Open the address on a phone or computer connected to the same trusted network, then enter the displayed code.")
                                .foregroundStyle(.secondary)
                        }
                        Section("Or add a playlist URL") {
                            TextField("https://provider.example/playlist.m3u", text: $playlistAddress)
                                .textContentType(.URL)
                            Button("Import URL") {
                                let address = playlistAddress
                                importing = false
                                Task { await model.importPlaylist(from: address) }
                            }
                            .disabled(playlistAddress.isEmpty)
                        }
                        Text("Imported playlist data is stored inside the app using Apple file protection. URLs and DRM values are never logged.")
                            .foregroundStyle(.secondary)
                    }
                    .navigationTitle("Add Playlist")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { importing = false }
                        }
                    }
                    .onAppear { startUploadServer() }
                    .onDisappear { stopUploadServer() }
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

    private func startUploadServer() {
        guard uploadServer == nil else { return }
        do {
            uploadServer = try PlaylistUploadServer(address: { message in
                Task { @MainActor in uploadStatus = message }
            }, upload: { data, completion in
                Task { @MainActor in
                    let result = model.importPlaylist(data: data)
                    completion(result)
                }
            })
        } catch {
            uploadStatus = "Local upload could not start. Check Local Network access."
        }
    }

    private func stopUploadServer() {
        uploadServer?.stop()
        uploadServer = nil
        uploadStatus = "Starting local upload…"
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

