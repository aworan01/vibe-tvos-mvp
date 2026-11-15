import SwiftUI

private let liveAccent = Color(red: 0.35, green: 0.86, blue: 0.92)
private let livePanel = Color(red: 0.07, green: 0.09, blue: 0.15)

struct LiveTVView: View {
    @EnvironmentObject private var model: AppModel
    @State private var group: String?
    @State private var favouritesOnly = false
    @State private var recentsOnly = false
    @State private var selectedPlaylistID: UUID?
    @State private var searchText = ""
    @State private var playing: Channel?
    @State private var importing = false
    @State private var showingGuide = false

    private var groups: [String] {
        Set(playlistFilteredChannels.map(\.group)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var visibleChannels: [Channel] {
        let base: [Channel]
        if favouritesOnly { base = playlistFilteredChannels.filter { model.favourites.contains($0.id) } }
        else if recentsOnly { base = model.recentChannels.filter(matchesPlaylist) }
        else { base = playlistFilteredChannels.filter { group == nil || $0.group == group } }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return base }
        return base.filter { channel in
            channel.name.localizedCaseInsensitiveContains(query) ||
            channel.group.localizedCaseInsensitiveContains(query) ||
            (model.playlist(containing: channel)?.name.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var playlistFilteredChannels: [Channel] {
        guard let selectedPlaylistID else { return model.channels }
        return model.playlists.first(where: { $0.id == selectedPlaylistID })?.channels ?? []
    }

    private func matchesPlaylist(_ channel: Channel) -> Bool {
        selectedPlaylistID == nil || model.playlist(containing: channel)?.id == selectedPlaylistID
    }

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Divider().overlay(.white.opacity(0.1))
            channelBrowser
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.07, green: 0.13, blue: 0.19), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .fullScreenCover(item: $playing) { PlayerView(channel: $0) }
        .sheet(isPresented: $importing) { ImportSourcesView() }
        .sheet(isPresented: $showingGuide) {
            NavigationStack {
                XMLTVGridView(playing: $playing)
                    .navigationTitle("TV Guide")
                    .toolbar {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            Task { await model.refreshGuide(for: selectedPlaylistID) }
                        }
                        Button("Close") { showingGuide = false }
                    }
            }
        }
        .alert("Import", isPresented: Binding(
            get: { model.importMessage != nil },
            set: { if !$0 { model.importMessage = nil } }
        )) {
            Button("OK") { model.importMessage = nil }
        } message: {
            Text(model.importMessage ?? "")
        }
    }

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Live TV", systemImage: "play.tv.fill")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(liveAccent)
                .padding(.bottom, 20)

            sidebarButton("All Channels", icon: "rectangle.stack", selected: group == nil && !favouritesOnly && !recentsOnly) {
                group = nil; favouritesOnly = false; recentsOnly = false
            }
            sidebarButton("Favourites", icon: "star.fill", selected: favouritesOnly) {
                favouritesOnly = true; recentsOnly = false; group = nil
            }
            sidebarButton("Recent", icon: "clock.fill", selected: recentsOnly) {
                recentsOnly = true; favouritesOnly = false; group = nil
            }
            Divider().overlay(.white.opacity(0.1)).padding(.vertical, 4)
            Text("PLAYLISTS").font(.caption2.bold()).foregroundStyle(.secondary)
            sidebarButton("All Playlists", icon: "square.stack.3d.up", selected: selectedPlaylistID == nil) {
                selectedPlaylistID = nil; group = nil
            }
            ForEach(model.playlists.filter(\.isEnabled)) { playlist in
                sidebarButton(playlist.name, icon: "list.bullet.rectangle",
                              selected: selectedPlaylistID == playlist.id) {
                    selectedPlaylistID = playlist.id; group = nil
                }
            }
            Divider().overlay(.white.opacity(0.1)).padding(.vertical, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(groups, id: \.self) { name in
                        sidebarButton(name, icon: "folder", selected: group == name && !favouritesOnly && !recentsOnly) {
                            group = name; favouritesOnly = false; recentsOnly = false
                        }
                    }
                }
            }
            Spacer()
            Button("TV Guide", systemImage: "calendar") { showingGuide = true }
            Button("Import", systemImage: "square.and.arrow.down") { importing = true }
        }
        .padding(26)
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.3))
        .focusSection()
    }

    private var channelBrowser: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(browserTitle).font(.system(size: 50, weight: .bold))
                    Text("\(visibleChannels.count) channels")
                        .font(.title3).foregroundStyle(.secondary)
                }
                Spacer()
                if let last = model.lastChannel {
                    Button("Resume \(last.name)", systemImage: "play.fill") { playing = last }
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 38)

            TextField("Search channels, groups, or playlists", text: $searchText)
                .font(.body)
                .padding(.horizontal, 44)

            if visibleChannels.isEmpty {
                ContentUnavailableView {
                    Label("No Channels", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text(model.channels.isEmpty
                         ? "Import an M3U playlist to begin."
                         : "No channels match this section.")
                } actions: {
                    if model.channels.isEmpty {
                        Button("Import Playlist") { importing = true }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 285), spacing: 24)],
                        spacing: 24
                    ) {
                        ForEach(visibleChannels) { channel in
                            channelCard(channel)
                        }
                    }
                    .padding(.horizontal, 44)
                    .padding(.bottom, 40)
                }
                .focusSection()
            }
        }
    }

    private var browserTitle: String {
        if favouritesOnly { return "Favourites" }
        if recentsOnly { return "Recently Watched" }
        if let group { return group }
        return model.playlists.first(where: { $0.id == selectedPlaylistID })?.name ?? "All Channels"
    }

    private func sidebarButton(
        _ title: String,
        icon: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                .padding(.horizontal, 15)
                .background(
                    selected ? liveAccent.opacity(0.18) : .clear,
                    in: RoundedRectangle(cornerRadius: 12)
                )
                .foregroundStyle(selected ? liveAccent : .white)
        }
        .buttonStyle(.plain)
    }

    private func channelCard(_ channel: Channel) -> some View {
        let favourite = model.favourites.contains(channel.id)
        return Button {
            playing = channel
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    ChannelLogo(channel: channel).frame(width: 92, height: 70)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(channel.name).font(.headline.bold()).lineLimit(1)
                        Text("\(model.playlist(containing: channel)?.name ?? "Playlist") · \(channel.group)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if favourite {
                        Image(systemName: "star.fill").foregroundStyle(liveAccent)
                    }
                }
                if let now = model.nowProgramme(for: channel) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(now.title).font(.headline).lineLimit(1)
                        ProgressView(
                            value: Date().timeIntervalSince(now.start),
                            total: max(1, now.end.timeIntervalSince(now.start))
                        )
                        .tint(liveAccent)
                        if let next = model.nextProgramme(for: channel) {
                            Text("Next: \(next.title)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                } else {
                    Text("No current guide information")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(livePanel, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.white.opacity(0.1), lineWidth: 1)
            }
        }
        .buttonStyle(.card)
        .contextMenu {
            Button(favourite ? "Remove from Favourites" : "Add to Favourites") {
                model.toggleFavourite(channel)
            }
        }
    }
}

private struct ChannelLogo: View {
    let channel: Channel

    var body: some View {
        if let url = channel.logoURL {
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image.resizable().scaledToFit().padding(8)
                } else {
                    fallback
                }
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Text(String(channel.name.prefix(2)).uppercased())
            .font(.title.bold())
            .foregroundStyle(liveAccent)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ImportSourcesView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var playlistAddress = ""
    @State private var playlistName = ""
    @State private var guideAddress = ""
    @State private var guidePlaylistID: UUID?
    @State private var uploadServer: PlaylistUploadServer?
    @State private var uploadStatus = "Starting local upload…"

    var body: some View {
        NavigationStack {
            Form {
                Section("Upload M3U from this network") {
                    Text(uploadStatus)
                    Text("Open the address on a phone or computer on the same trusted network, then enter the displayed code.")
                        .foregroundStyle(.secondary)
                }
                Section("Playlist URL") {
                    TextField("Playlist name", text: $playlistName)
                    TextField("https://provider.example/playlist.m3u", text: $playlistAddress)
                        .textContentType(.URL)
                    Button("Import Playlist URL") {
                        Task { await model.importPlaylist(from: playlistAddress, name: playlistName) }
                    }
                    .disabled(playlistAddress.isEmpty)
                }
                Section("XMLTV Guide URL") {
                    Picker("Playlist", selection: $guidePlaylistID) {
                        Text("Choose Playlist").tag(UUID?.none)
                        ForEach(model.playlists) { playlist in
                            Text(playlist.name).tag(Optional(playlist.id))
                        }
                    }
                    TextField("https://provider.example/guide.xml", text: $guideAddress)
                        .textContentType(.URL)
                    Button("Import XMLTV Guide") {
                        guard let guidePlaylistID else { return }
                        Task { await model.importGuide(from: guideAddress, for: guidePlaylistID) }
                    }
                    .disabled(guideAddress.isEmpty || guidePlaylistID == nil)
                }
                Section("Saved Playlists") {
                    ForEach(model.playlists) { playlist in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(playlist.name).font(.headline)
                                Text("\(playlist.channels.count) channels")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { playlist.isEnabled },
                                set: { model.setPlaylistEnabled(playlist.id, enabled: $0) }
                            ))
                            Button("Delete", role: .destructive) { model.deletePlaylist(playlist.id) }
                        }
                    }
                }
                Text("Imported sources are stored only inside the app sandbox. URLs, headers, and key data are never logged.")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Add Sources")
            .toolbar { Button("Close") { dismiss() } }
            .onAppear {
                guidePlaylistID = model.playlists.first?.id
                guideAddress = model.playlists.first?.guideURL?.absoluteString ?? ""
                startUploadServer()
            }
            .onChange(of: guidePlaylistID) { _, id in
                guideAddress = model.playlists.first(where: { $0.id == id })?.guideURL?.absoluteString ?? ""
            }
            .onDisappear { stopUploadServer() }
        }
    }

    private func startUploadServer() {
        guard uploadServer == nil else { return }
        do {
            uploadServer = try PlaylistUploadServer(address: { message in
                Task { @MainActor in uploadStatus = message }
            }, upload: { data, completion in
                Task { @MainActor in completion(model.importPlaylist(data: data, name: "Network Upload")) }
            })
        } catch {
            uploadStatus = "Local upload could not start. Check Local Network access."
        }
    }

    private func stopUploadServer() {
        uploadServer?.stop()
        uploadServer = nil
    }
}

private struct XMLTVGridView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var playing: Channel?
    private let hourWidth: CGFloat = 240
    private let windowHours = 6

    private var windowStart: Date {
        Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
    }

    private var windowEnd: Date {
        windowStart.addingTimeInterval(Double(windowHours) * 3600)
    }

    var body: some View {
        if model.programmes.isEmpty {
            ContentUnavailableView(
                "No Guide Data",
                systemImage: "calendar",
                description: Text("Add an XMLTV URL from Import, then refresh the guide.")
            )
        } else {
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(model.channels) { channel in guideRow(channel) }
                    } header: {
                        timelineHeader
                    }
                }
                .padding(24)
            }
            .background(Color.black.opacity(0.92))
        }
    }

    private var timelineHeader: some View {
        HStack(spacing: 0) {
            Text("Channel").frame(width: 280, alignment: .leading)
            ForEach(0..<windowHours, id: \.self) { hour in
                Text(windowStart.addingTimeInterval(Double(hour) * 3600), style: .time)
                    .frame(width: hourWidth, alignment: .leading)
            }
        }
        .font(.headline)
        .padding(.vertical, 16)
        .background(Color.black)
    }

    private func guideRow(_ channel: Channel) -> some View {
        HStack(spacing: 0) {
            Button {
                playing = channel
            } label: {
                HStack(spacing: 12) {
                    ChannelLogo(channel: channel).frame(width: 68, height: 50)
                    Text(channel.name).lineLimit(1)
                }
                .frame(width: 260, alignment: .leading)
                .padding(.horizontal, 10)
            }
            .buttonStyle(.plain)

            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.035))
                ForEach(visibleProgrammes(channel)) { programme in
                    let start = max(programme.start, windowStart)
                    let end = min(programme.end, windowEnd)
                    let x = CGFloat(start.timeIntervalSince(windowStart) / 3600) * hourWidth
                    let width = max(
                        CGFloat(80),
                        CGFloat(end.timeIntervalSince(start) / 3600) * hourWidth
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(programme.title).font(.headline).lineLimit(1)
                        Text(programme.start, style: .time)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(width: width, height: 78, alignment: .leading)
                    .background(livePanel, in: RoundedRectangle(cornerRadius: 10))
                    .offset(x: x)
                }
                let nowX = CGFloat(Date().timeIntervalSince(windowStart) / 3600) * hourWidth
                if nowX >= 0 && nowX <= CGFloat(windowHours) * hourWidth {
                    Rectangle().fill(.red).frame(width: 3).offset(x: nowX)
                }
            }
            .frame(width: CGFloat(windowHours) * hourWidth, height: 90)
        }
    }

    private func visibleProgrammes(_ channel: Channel) -> [EPGProgramme] {
        model.programmes(for: channel).filter {
            $0.end > windowStart && $0.start < windowEnd
        }
    }
}

