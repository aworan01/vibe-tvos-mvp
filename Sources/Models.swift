import Foundation

struct Channel: Identifiable, Hashable, Codable {
    let id: UUID
    let name: String
    let streamURL: URL
    let duration: Double?
    let attributes: [String: String]
    let vlcOptions: [String: String]
    let kodiProperties: [String: String]
    let rawMetadataLines: [String]

    var group: String { attributes["group-title"] ?? "Other" }
    var tvgID: String? { attributes["tvg-id"] }
    var logoURL: URL? { attributes["tvg-logo"].flatMap(URL.init(string:)) }
    var capability: StreamCapability { StreamCapability.assess(self) }
    var userAgent: String? { vlcOptions["http-user-agent"] }
    var clearKey: ClearKeyConfiguration? {
        ClearKeyConfiguration(
            license: kodiProperties["inputstream.adaptive.license_key"],
            userAgent: userAgent
        )
    }
}

struct ClearKeyConfiguration: Codable, Hashable {
    let keys: [String: String]
    let userAgent: String?

    var ffmpegKeys: String {
        keys.keys.sorted().compactMap { id in
            keys[id].map { "\(id)=\($0)" }
        }.joined(separator: ":")
    }

    init?(license: String?, userAgent: String?) {
        struct Key: Decodable {
            let kty: String
            let kid: String
            let k: String
        }
        struct License: Decodable { let keys: [Key] }

        guard let license, license.utf8.count <= 8_192 else {
            return nil
        }
        var pairs: [String: String] = [:]
        if let decoded = try? JSONDecoder().decode(License.self, from: Data(license.utf8)) {
            guard !decoded.keys.isEmpty, decoded.keys.count <= 32 else { return nil }
            for key in decoded.keys {
                guard key.kty == "oct", let id = Self.base64Hex(key.kid),
                      let value = Self.base64Hex(key.k), pairs[id] == nil || pairs[id] == value else {
                    return nil
                }
                pairs[id] = value
            }
        } else {
            let entries = license.split(whereSeparator: { $0 == ":" || $0 == "," || $0 == ";" })
            guard entries.count.isMultiple(of: 2), !entries.isEmpty, entries.count <= 64 else { return nil }
            for index in stride(from: 0, to: entries.count, by: 2) {
                let id = String(entries[index]).lowercased()
                let value = String(entries[index + 1]).lowercased()
                guard Self.isHexKey(id), Self.isHexKey(value), pairs[id] == nil || pairs[id] == value else { return nil }
                pairs[id] = value
            }
        }
        if let userAgent {
            guard userAgent.utf8.count <= 1_024,
                  userAgent.utf8.allSatisfy({ (32...126).contains($0) }) else {
                return nil
            }
        }
        keys = pairs
        self.userAgent = userAgent
    }

    private static func base64Hex(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: base64), data.count == 16 else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private static func isHexKey(_ value: String) -> Bool {
        value.count == 32 && value.allSatisfy { $0.isHexDigit }
    }
}

enum StreamContainer: String, Hashable, Codable {
    case hls = "HLS"
    case dash = "MPEG-DASH"
    case unknown = "Unknown"
}

enum DRMSystem: String, Hashable, Codable {
    case none = "None"
    case clearKey = "ClearKey"
    case widevine = "Widevine"
    case unknown = "Unknown DRM"
}

struct StreamCapability: Hashable {
    let container: StreamContainer
    let drm: DRMSystem
    let isNativelyPlayable: Bool
    let explanation: String

    static func assess(_ channel: Channel) -> StreamCapability {
        let path = channel.streamURL.path.lowercased()
        let manifest = channel.kodiProperties["inputstream.adaptive.manifest_type"]?.lowercased()
        let license = channel.kodiProperties["inputstream.adaptive.license_type"]?.lowercased() ?? ""
        let container: StreamContainer = (path.hasSuffix(".m3u8") || manifest == "hls") ? .hls :
            ((path.hasSuffix(".mpd") || manifest == "mpd") ? .dash : .unknown)
        let drm: DRMSystem = license.contains("widevine") ? .widevine :
            (license.contains("clearkey") || license.contains("clear_key") ? .clearKey :
                (license.isEmpty ? .none : .unknown))

        if container == .hls {
            return .init(container: container, drm: drm, isNativelyPlayable: true,
                         explanation: "HLS candidate; AVPlayer will inspect the actual manifest.")
        }
        return .init(container: container, drm: drm, isNativelyPlayable: false,
                     explanation: explanation(container: container, drm: drm))
    }

    private static func explanation(container: StreamContainer, drm: DRMSystem) -> String {
        switch (container, drm) {
        case (.dash, .widevine): return "Widevine DASH requires a licensed third-party tvOS playback SDK."
        case (.dash, .clearKey): return "ClearKey DASH will use the local playback bridge after a clear-media attempt."
        case (.dash, _): return "MPEG-DASH will use the VLC playback path."
        case (_, .widevine): return "Widevine is detected and is not natively supported by AVPlayer."
        case (_, .clearKey): return "ClearKey will use the local playback bridge after a clear-media attempt."
        default: return "The stream type cannot be confirmed as compatible HLS."
        }
    }
}

