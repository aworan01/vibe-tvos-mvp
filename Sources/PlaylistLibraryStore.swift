import Foundation

struct SavedLibrary: Codable, Equatable {
    var channels: [Channel] = []
    var favourites: Set<UUID> = []
    var recentChannelIDs: [UUID] = []
    var lastChannelID: UUID?
    var guideURL: URL?
    var programmes: [EPGProgramme] = []

    init(
        channels: [Channel] = [],
        favourites: Set<UUID> = [],
        recentChannelIDs: [UUID] = [],
        lastChannelID: UUID? = nil,
        guideURL: URL? = nil,
        programmes: [EPGProgramme] = []
    ) {
        self.channels = channels
        self.favourites = favourites
        self.recentChannelIDs = recentChannelIDs
        self.lastChannelID = lastChannelID
        self.guideURL = guideURL
        self.programmes = programmes
    }

    private enum CodingKeys: String, CodingKey {
        case channels, favourites, recentChannelIDs, lastChannelID, guideURL, programmes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        channels = try values.decodeIfPresent([Channel].self, forKey: .channels) ?? []
        favourites = try values.decodeIfPresent(Set<UUID>.self, forKey: .favourites) ?? []
        recentChannelIDs = try values.decodeIfPresent([UUID].self, forKey: .recentChannelIDs) ?? []
        lastChannelID = try values.decodeIfPresent(UUID.self, forKey: .lastChannelID)
        guideURL = try values.decodeIfPresent(URL.self, forKey: .guideURL)
        programmes = try values.decodeIfPresent([EPGProgramme].self, forKey: .programmes) ?? []
    }
}

enum PlaylistLibraryError: LocalizedError {
    case encoding
    case unavailable(code: Int?)

    var errorDescription: String? {
        switch self {
        case .encoding:
            return "Apple TV could not prepare the channel library for storage."
        case .unavailable(let code):
            if let code {
                return "Apple TV could not access a writable library location (system code \(code))."
            }
            return "Apple TV could not access a writable library location."
        }
    }
}

final class PlaylistLibraryStore {
    private let fileURLs: [URL]
    private let writer: (Data, URL, Data.WritingOptions) throws -> Void
    private var activeURL: URL?

    init(
        directory: URL? = nil,
        fallbackDirectories: [URL] = [],
        writer: @escaping (Data, URL, Data.WritingOptions) throws -> Void = {
        data, url, options in
        try data.write(to: url, options: options)
    }
    ) {
        let manager = FileManager.default
        let bases: [URL]
        if let directory {
            bases = [directory] + fallbackDirectories
        } else {
            bases = [
                manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
                manager.urls(for: .documentDirectory, in: .userDomainMask).first,
                manager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ].compactMap { $0 }
        }
        var seen = Set<String>()
        fileURLs = bases.compactMap { base in
            let file = base
                .appendingPathComponent("VibeTV", isDirectory: true)
                .appendingPathComponent("PlaylistLibrary.json")
            guard seen.insert(file.path).inserted else { return nil }
            return file
        }
        self.writer = writer
    }

    func load() throws -> SavedLibrary {
        var lastError: Error?
        for fileURL in fileURLs where FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let library = try JSONDecoder().decode(
                    SavedLibrary.self,
                    from: Data(contentsOf: fileURL)
                )
                activeURL = fileURL
                return library
            } catch {
                lastError = error
            }
        }
        guard let lastError else { return SavedLibrary() }
        throw PlaylistLibraryError.unavailable(code: (lastError as NSError).code)
    }

    func save(_ library: SavedLibrary) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(library)
        } catch {
            throw PlaylistLibraryError.encoding
        }

        let destinations = activeURL.map { active in
            [active] + fileURLs.filter { $0 != active }
        } ?? fileURLs
        var lastError: Error?

        for fileURL in destinations {
            do {
                try FileManager.default.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                for options: Data.WritingOptions in [
                    [.atomic, .completeFileProtection],
                    .atomic
                ] {
                    do {
                        try writer(data, fileURL, options)
                        activeURL = fileURL
                        return
                    } catch {
                        lastError = error
                    }
                }
            } catch {
                lastError = error
            }
        }

        throw PlaylistLibraryError.unavailable(code: lastError.map { ($0 as NSError).code })
    }
}

