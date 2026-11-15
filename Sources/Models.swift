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

        if container == .hls && drm == .none {
            return .init(container: container, drm: drm, isNativelyPlayable: true,
                         explanation: "Compatible HLS stream; AVPlayer will attempt playback.")
        }
        return .init(container: container, drm: drm, isNativelyPlayable: false,
                     explanation: explanation(container: container, drm: drm))
    }

    private static func explanation(container: StreamContainer, drm: DRMSystem) -> String {
        switch (container, drm) {
        case (.dash, .widevine): return "Widevine DASH requires a licensed third-party tvOS playback SDK."
        case (.dash, .clearKey): return "ClearKey DASH is detected but is not implemented in this AVPlayer MVP."
        case (.dash, _): return "MPEG-DASH is detected but is not supported by this AVPlayer MVP."
        case (_, .widevine): return "Widevine is detected and is not natively supported by AVPlayer."
        case (_, .clearKey): return "ClearKey is detected but its playback path is not implemented."
        default: return "The stream type cannot be confirmed as compatible HLS."
        }
    }
}

