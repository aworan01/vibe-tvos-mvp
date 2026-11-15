import Foundation

struct EPGProgramme: Identifiable, Hashable {
    let id: String
    let channelID: String
    let title: String
    let start: Date
    let end: Date
}

struct EPGMatch: Hashable {
    let channel: Channel
    let programme: EPGProgramme?
    let confidence: Double
}

protocol EPGMatching: Sendable {
    func match(channels: [Channel], programmes: [EPGProgramme]) async -> [EPGMatch]
}

struct PlaceholderEPGMatcher: EPGMatching {
    func match(channels: [Channel], programmes: [EPGProgramme]) async -> [EPGMatch] {
        channels.map { channel in
            let exact = programmes.first { !$0.channelID.isEmpty && $0.channelID == channel.tvgID }
            let normalized = programmes.first {
                $0.title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) ==
                channel.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            }
            return EPGMatch(channel: channel, programme: exact ?? normalized,
                            confidence: exact != nil ? 1 : (normalized != nil ? 0.7 : 0))
        }
    }
}

struct MediaMetadata: Identifiable, Hashable {
    let id: Int
    let title: String
    let overview: String
    let posterURL: URL?
}

protocol TMDBMetadataProviding: Sendable {
    func search(query: String) async throws -> [MediaMetadata]
}

struct PlaceholderTMDBService: TMDBMetadataProviding {
    func search(query: String) async throws -> [MediaMetadata] { [] }
}

