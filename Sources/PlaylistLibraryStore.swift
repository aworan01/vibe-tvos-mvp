import Foundation

struct SavedLibrary: Codable, Equatable {
    var channels: [Channel] = []
    var favourites: Set<UUID> = []
}

enum PlaylistLibraryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Apple TV could not save the protected channel library."
    }
}

final class PlaylistLibraryStore {
    private let fileURL: URL
    private let writer: (Data, URL, Data.WritingOptions) throws -> Void

    init(directory: URL? = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first, writer: @escaping (Data, URL, Data.WritingOptions) throws -> Void = {
        data, url, options in
        try data.write(to: url, options: options)
    }) {
        let base = directory ?? FileManager.default.temporaryDirectory
        fileURL = base
            .appendingPathComponent("VibeTV", isDirectory: true)
            .appendingPathComponent("PlaylistLibrary.json")
        self.writer = writer
    }

    func load() throws -> SavedLibrary {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return SavedLibrary()
        }
        return try JSONDecoder().decode(SavedLibrary.self, from: Data(contentsOf: fileURL))
    }

    func save(_ library: SavedLibrary) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(library)
            do {
                try writer(data, fileURL, [.atomic, .completeFileProtection])
            } catch {
                // Apple TV can reject lock-state protection even though the
                // option is available at compile time. The app sandbox remains
                // private, and atomic replacement prevents partial libraries.
                try writer(data, fileURL, .atomic)
            }
        } catch {
            throw PlaylistLibraryError.unavailable
        }
    }
}

