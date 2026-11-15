import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var favourites: Set<UUID> = []
    @Published var importMessage: String?

    let epgMatcher: any EPGMatching = PlaceholderEPGMatcher()
    let metadataService: any TMDBMetadataProviding = PlaceholderTMDBService()
    private let libraryStore: PlaylistLibraryStore

    init(libraryStore: PlaylistLibraryStore = PlaylistLibraryStore()) {
        self.libraryStore = libraryStore
        do {
            let library = try libraryStore.load()
            channels = library.channels
            favourites = library.favourites
        } catch {
            importMessage = "The saved channel library could not be opened."
        }
    }

    @discardableResult
    func importPlaylist(data: Data) -> Result<String, Error> {
        do {
            let parsed = try M3UParser().parse(data: data)
            try libraryStore.save(SavedLibrary(channels: parsed, favourites: []))
            channels = parsed
            favourites = []
            let message = "Saved \(parsed.count) channels."
            importMessage = message
            return .success(message)
        } catch {
            importMessage = "The playlist could not be imported: \(error.localizedDescription)"
            return .failure(error)
        }
    }

    func importPlaylist(from address: String) async {
        guard let url = URL(string: address),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            importMessage = "Enter a valid HTTP or HTTPS playlist address."
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, 200...299 ~= http.statusCode else {
                importMessage = "The playlist server returned an error."
                return
            }
            guard data.count <= M3UParser.maximumBytes else {
                importMessage = "The playlist is larger than the 8 MB import limit."
                return
            }
            importPlaylist(data: data)
        } catch {
            importMessage = "The playlist could not be downloaded."
        }
    }

    func toggleFavourite(_ channel: Channel) {
        let previous = favourites
        if favourites.contains(channel.id) { favourites.remove(channel.id) }
        else { favourites.insert(channel.id) }
        do {
            try libraryStore.save(SavedLibrary(channels: channels, favourites: favourites))
        } catch {
            favourites = previous
            importMessage = "The favourite could not be saved."
        }
    }
}

