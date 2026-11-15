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

    init(directory: URL? = FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
    ).first) {
        let base = directory ?? FileManager.default.temporaryDirectory
        fileURL = base
            .appendingPathComponent("VibeTV", isDirectory: true)
            .appendingPathComponent("PlaylistLibrary.json")
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
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw PlaylistLibraryError.unavailable
        }
    }
}

