import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var playlists: [IPTVPlaylist] = []
    @Published private(set) var channels: [Channel] = []
    @Published var favourites: Set<UUID> = []
    @Published var recentChannelIDs: [UUID] = []
    @Published var lastChannelID: UUID?
    @Published private(set) var programmes: [EPGProgramme] = []
    @Published var importMessage: String?

    let epgMatcher: any EPGMatching = PlaceholderEPGMatcher()
    let metadataService: any TMDBMetadataProviding = PlaceholderTMDBService()
    private let libraryStore: PlaylistLibraryStore

    init(libraryStore: PlaylistLibraryStore = PlaylistLibraryStore()) {
        self.libraryStore = libraryStore
        do { apply(try libraryStore.load()) }
        catch { importMessage = "The saved channel library could not be opened: \(error.localizedDescription)" }
    }

    var recentChannels: [Channel] {
        recentChannelIDs.compactMap { id in channels.first { $0.id == id } }
    }

    var lastChannel: Channel? {
        lastChannelID.flatMap { id in channels.first { $0.id == id } }
    }

    func playlist(containing channel: Channel) -> IPTVPlaylist? {
        playlists.first { playlist in playlist.channels.contains { $0.id == channel.id } }
    }

    @discardableResult
    func importPlaylist(data: Data, name requestedName: String? = nil, sourceURL: URL? = nil) -> Result<String, Error> {
        do {
            let parsed = try M3UParser().parse(data: data)
            let fingerprint = Self.fingerprint(data)
            let embeddedGuideURL = M3UParser.guideURL(in: data)
            let name = uniquePlaylistName(cleanName(requestedName, sourceURL: sourceURL))

            if let index = duplicateIndex(sourceURL: sourceURL, fingerprint: fingerprint) {
                let oldIDs = Set(playlists[index].channels.map(\.id))
                let old = playlists[index]
                playlists[index] = IPTVPlaylist(
                    id: old.id,
                    name: requestedName.map { cleanName($0) } ?? old.name,
                    sourceURL: sourceURL ?? old.sourceURL,
                    fingerprint: fingerprint,
                    isEnabled: old.isEnabled,
                    channels: parsed,
                    guideURL: embeddedGuideURL ?? old.guideURL,
                    programmes: old.programmes
                )
                favourites.subtract(oldIDs)
                recentChannelIDs.removeAll { oldIDs.contains($0) }
                if lastChannelID.map(oldIDs.contains) == true { lastChannelID = nil }
                sortPlaylists(); rebuildCollections(); try persist()
                importMessage = "Updated \(old.name) with \(parsed.count) channels."
                if let guide = embeddedGuideURL ?? old.guideURL {
                    Task { await importGuide(from: guide.absoluteString, for: old.id) }
                }
                return .success(importMessage!)
            }

            let playlist = IPTVPlaylist(name: name, sourceURL: sourceURL, fingerprint: fingerprint,
                                        channels: parsed, guideURL: embeddedGuideURL)
            playlists.append(playlist)
            sortPlaylists(); rebuildCollections(); try persist()
            importMessage = "Added \(name) with \(parsed.count) channels."
            if let embeddedGuideURL {
                Task { await importGuide(from: embeddedGuideURL.absoluteString, for: playlist.id) }
            }
            return .success(importMessage!)
        } catch {
            importMessage = "The playlist could not be imported: \(error.localizedDescription)"
            return .failure(error)
        }
    }

    func importPlaylist(from address: String, name: String? = nil) async {
        guard let url = webURL(address) else {
            importMessage = "Enter a valid HTTP or HTTPS playlist address."
            return
        }
        do {
            let data = try await download(url, maximumBytes: M3UParser.maximumBytes)
            importPlaylist(data: data, name: name, sourceURL: url)
        } catch { importMessage = "The playlist could not be downloaded: \(error.localizedDescription)" }
    }

    func importGuide(from address: String, for playlistID: UUID) async {
        guard let url = webURL(address), let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            importMessage = "Choose a playlist and enter a valid HTTP or HTTPS XMLTV address."
            return
        }
        do {
            let data = try await download(url, maximumBytes: XMLTVParser.maximumBytes)
            let parsed = try await Task.detached { try XMLTVParser.parse(data) }.value
            playlists[index].guideURL = url
            playlists[index].programmes = parsed.sorted { $0.start < $1.start }
            rebuildCollections(); try persist()
            importMessage = "Saved \(parsed.count) guide programmes for \(playlists[index].name)."
        } catch { importMessage = "The XMLTV guide could not be imported: \(error.localizedDescription)" }
    }

    func refreshGuide(for playlistID: UUID? = nil) async {
        let targets = playlists.filter { playlistID == nil ? $0.isEnabled : $0.id == playlistID }
        let guides = targets.compactMap { playlist in playlist.guideURL.map { (playlist.id, $0) } }
        guard !guides.isEmpty else {
            importMessage = "Add an XMLTV guide URL to the selected playlist first."
            return
        }
        for (id, url) in guides { await importGuide(from: url.absoluteString, for: id) }
    }

    func setPlaylistEnabled(_ id: UUID, enabled: Bool) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].isEnabled = enabled
        rebuildCollections(); try? persist()
    }

    func deletePlaylist(_ id: UUID) {
        guard let playlist = playlists.first(where: { $0.id == id }) else { return }
        let ids = Set(playlist.channels.map(\.id))
        playlists.removeAll { $0.id == id }
        favourites.subtract(ids)
        recentChannelIDs.removeAll { ids.contains($0) }
        if lastChannelID.map(ids.contains) == true { lastChannelID = nil }
        rebuildCollections()
        do { try persist() } catch { importMessage = "The playlist could not be removed from storage." }
    }

    func toggleFavourite(_ channel: Channel) {
        let previous = favourites
        if favourites.contains(channel.id) { favourites.remove(channel.id) } else { favourites.insert(channel.id) }
        do { try persist() } catch { favourites = previous; importMessage = "The favourite could not be saved." }
    }

    func recordPlayback(_ channel: Channel) {
        lastChannelID = channel.id
        recentChannelIDs.removeAll { $0 == channel.id }
        recentChannelIDs.insert(channel.id, at: 0)
        recentChannelIDs = Array(recentChannelIDs.prefix(20))
        try? persist()
    }

    func channel(relativeTo channel: Channel, offset: Int) -> Channel? {
        guard !channels.isEmpty, let index = channels.firstIndex(where: { $0.id == channel.id }) else { return nil }
        return channels[(index + offset % channels.count + channels.count) % channels.count]
    }

    func programmes(for channel: Channel) -> [EPGProgramme] {
        let source = playlist(containing: channel)?.programmes ?? []
        let tvgID = channel.tvgID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelName = normalized(channel.name)
        return source.filter { programme in
            if let tvgID, !tvgID.isEmpty, programme.channelID == tvgID { return true }
            if normalized(programme.channelID) == channelName { return true }
            return programme.channelName.map(normalized) == channelName
        }
    }

    func nowProgramme(for channel: Channel, at date: Date = Date()) -> EPGProgramme? {
        programmes(for: channel).first { $0.start <= date && $0.end > date }
    }

    func nextProgramme(for channel: Channel, at date: Date = Date()) -> EPGProgramme? {
        programmes(for: channel).first { $0.start > date }
    }

    private func apply(_ library: SavedLibrary) {
        if library.playlists.isEmpty, !library.channels.isEmpty {
            playlists = [IPTVPlaylist(name: "Imported Playlist", fingerprint: "legacy",
                                      channels: library.channels, guideURL: library.guideURL,
                                      programmes: library.programmes)]
        } else { playlists = library.playlists }
        favourites = library.favourites
        recentChannelIDs = library.recentChannelIDs
        lastChannelID = library.lastChannelID
        sortPlaylists(); rebuildCollections()
        if library.playlists.isEmpty, !library.channels.isEmpty { try? persist() }
    }

    private func snapshot() -> SavedLibrary {
        SavedLibrary(playlists: playlists, favourites: favourites,
                     recentChannelIDs: recentChannelIDs, lastChannelID: lastChannelID)
    }

    private func rebuildCollections() {
        channels = playlists.filter(\.isEnabled).flatMap(\.channels).sorted(by: Self.channelSort)
        programmes = playlists.filter(\.isEnabled).flatMap(\.programmes).sorted { $0.start < $1.start }
        let valid = Set(playlists.flatMap(\.channels).map(\.id))
        favourites.formIntersection(valid)
        recentChannelIDs.removeAll { !valid.contains($0) }
        if lastChannelID.map({ !valid.contains($0) }) == true { lastChannelID = nil }
    }

    private func duplicateIndex(sourceURL: URL?, fingerprint: String) -> Int? {
        playlists.firstIndex {
            (sourceURL != nil && $0.sourceURL?.absoluteString == sourceURL?.absoluteString) || $0.fingerprint == fingerprint
        }
    }

    private func cleanName(_ requested: String?, sourceURL: URL? = nil) -> String {
        let trimmed = requested?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return String(trimmed.prefix(80)) }
        return sourceURL?.host ?? "IPTV Playlist"
    }

    private func uniquePlaylistName(_ base: String) -> String {
        var candidate = base; var suffix = 2
        let used = Set(playlists.map { $0.name.lowercased() })
        while used.contains(candidate.lowercased()) { candidate = "\(base) \(suffix)"; suffix += 1 }
        return candidate
    }

    private func sortPlaylists() {
        playlists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func persist() throws { try libraryStore.save(snapshot()) }

    private func webURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host?.isEmpty == false else { return nil }
        return url
    }

    private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else { throw URLError(.badServerResponse) }
        guard http.expectedContentLength <= Int64(maximumBytes) else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data(); data.reserveCapacity(max(0, Int(http.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "", options: .regularExpression)
    }

    private static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in data { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }

    private static func channelSort(_ lhs: Channel, _ rhs: Channel) -> Bool {
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : comparison == .orderedAscending
    }
}
