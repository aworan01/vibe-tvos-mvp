import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var favourites: Set<UUID> = []
    @Published var recentChannelIDs: [UUID] = []
    @Published var lastChannelID: UUID?
    @Published var guideURL: URL?
    @Published var programmes: [EPGProgramme] = []
    @Published var importMessage: String?

    let epgMatcher: any EPGMatching = PlaceholderEPGMatcher()
    let metadataService: any TMDBMetadataProviding = PlaceholderTMDBService()
    private let libraryStore: PlaylistLibraryStore

    init(libraryStore: PlaylistLibraryStore = PlaylistLibraryStore()) {
        self.libraryStore = libraryStore
        do {
            apply(try libraryStore.load())
        } catch {
            importMessage = "The saved channel library could not be opened: \(error.localizedDescription)"
        }
    }

    var recentChannels: [Channel] {
        recentChannelIDs.compactMap { id in channels.first { $0.id == id } }
    }

    var lastChannel: Channel? {
        lastChannelID.flatMap { id in channels.first { $0.id == id } }
    }

    @discardableResult
    func importPlaylist(data: Data) -> Result<String, Error> {
        do {
            let embeddedGuideURL = M3UParser.guideURL(in: data)
            let parsed = try M3UParser().parse(data: data)
            channels = parsed
            favourites = []
            recentChannelIDs = []
            lastChannelID = nil
            if let embeddedGuideURL { guideURL = embeddedGuideURL }
            try persist()
            let message = "Saved \(parsed.count) channels."
            importMessage = message
            if let embeddedGuideURL {
                Task { await importGuide(from: embeddedGuideURL.absoluteString) }
            }
            return .success(message)
        } catch {
            importMessage = "The playlist could not be imported: \(error.localizedDescription)"
            return .failure(error)
        }
    }

    func importPlaylist(from address: String) async {
        guard let url = webURL(address) else {
            importMessage = "Enter a valid HTTP or HTTPS playlist address."
            return
        }
        do {
            let data = try await download(url, maximumBytes: M3UParser.maximumBytes)
            importPlaylist(data: data)
        } catch {
            importMessage = "The playlist could not be downloaded: \(error.localizedDescription)"
        }
    }

    func importGuide(from address: String) async {
        guard let url = webURL(address) else {
            importMessage = "Enter a valid HTTP or HTTPS XMLTV address."
            return
        }
        do {
            let data = try await download(url, maximumBytes: XMLTVParser.maximumBytes)
            let parsed = try await Task.detached {
                try XMLTVParser.parse(data)
            }.value
            guideURL = url
            programmes = parsed.sorted { $0.start < $1.start }
            try persist()
            importMessage = "Saved \(programmes.count) guide programmes."
        } catch {
            importMessage = "The XMLTV guide could not be imported: \(error.localizedDescription)"
        }
    }

    func refreshGuide() async {
        guard let guideURL else {
            importMessage = "Add an XMLTV guide URL first."
            return
        }
        await importGuide(from: guideURL.absoluteString)
    }

    func toggleFavourite(_ channel: Channel) {
        let previous = favourites
        if favourites.contains(channel.id) { favourites.remove(channel.id) }
        else { favourites.insert(channel.id) }
        do {
            try persist()
        } catch {
            favourites = previous
            importMessage = "The favourite could not be saved."
        }
    }

    func recordPlayback(_ channel: Channel) {
        lastChannelID = channel.id
        recentChannelIDs.removeAll { $0 == channel.id }
        recentChannelIDs.insert(channel.id, at: 0)
        recentChannelIDs = Array(recentChannelIDs.prefix(20))
        try? persist()
    }

    func channel(relativeTo channel: Channel, offset: Int) -> Channel? {
        guard !channels.isEmpty,
              let index = channels.firstIndex(where: { $0.id == channel.id }) else {
            return nil
        }
        let next = (index + offset % channels.count + channels.count) % channels.count
        return channels[next]
    }

    func programmes(for channel: Channel) -> [EPGProgramme] {
        let tvgID = channel.tvgID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let channelName = normalized(channel.name)
        return programmes.filter { programme in
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
        channels = library.channels
        favourites = library.favourites
        recentChannelIDs = library.recentChannelIDs
        lastChannelID = library.lastChannelID
        guideURL = library.guideURL
        programmes = library.programmes
    }

    private func snapshot() -> SavedLibrary {
        SavedLibrary(
            channels: channels,
            favourites: favourites,
            recentChannelIDs: recentChannelIDs,
            lastChannelID: lastChannelID,
            guideURL: guideURL,
            programmes: programmes
        )
    }

    private func persist() throws {
        try libraryStore.save(snapshot())
    }

    private func webURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func download(_ url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              200...299 ~= http.statusCode else {
            throw URLError(.badServerResponse)
        }
        guard http.expectedContentLength <= Int64(maximumBytes) else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        var data = Data()
        data.reserveCapacity(max(0, Int(http.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < maximumBytes else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            data.append(byte)
        }
        return data
    }

    private func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "",
            options: .regularExpression
        )
    }
}

