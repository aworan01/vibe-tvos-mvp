import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var channels: [Channel] = []
    @Published var favourites: Set<UUID> = []
    @Published var importMessage: String?

    let epgMatcher: any EPGMatching = PlaceholderEPGMatcher()
    let metadataService: any TMDBMetadataProviding = PlaceholderTMDBService()

    func importPlaylist(data: Data) {
        do {
            channels = try M3UParser().parse(data: data)
            importMessage = "Imported \(channels.count) channels."
        } catch {
            importMessage = "The playlist could not be imported: \(error.localizedDescription)"
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
            guard data.count <= 8_000_000 else {
                importMessage = "The playlist is larger than the 8 MB import limit."
                return
            }
            importPlaylist(data: data)
        } catch {
            importMessage = "The playlist could not be downloaded."
        }
    }

    func toggleFavourite(_ channel: Channel) {
        if favourites.contains(channel.id) { favourites.remove(channel.id) }
        else { favourites.insert(channel.id) }
    }
}

