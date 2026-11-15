import Foundation

final class ClearKeyPlayback {
    let url: URL
    private let relay: OpaquePointer

    init?(source: URL, configuration: ClearKeyConfiguration) {
        var port: UInt16 = 0
        let route = "/\(UUID().uuidString)/stream.ts"
        guard let relay = iptv_relay_create(&port) else { return nil }
        guard let localURL = URL(string: "http://127.0.0.1:\(port)\(route)") else {
            iptv_relay_destroy(relay)
            return nil
        }
        self.relay = relay
        url = localURL
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            iptv_relay_run(self.relay, route, source.absoluteString, configuration.ffmpegKeys,
                           configuration.userAgent ?? "")
        }
    }

    var status: IPTVRelayStatus { iptv_relay_status(relay) }

    func cancel() { iptv_relay_cancel(relay) }

    deinit { iptv_relay_destroy(relay) }
}

extension IPTVRelayStatus {
    func message(timedOut: Bool) -> String {
        let phase: String
        switch stage {
        case IPTVRelayConnectingPlayer: phase = "connecting to the Apple TV player"
        case IPTVRelayOpeningManifest: phase = "opening the DASH manifest"
        case IPTVRelayReadingMedia: phase = "reading DASH media segments"
        case IPTVRelaySelectingVideo: phase = "selecting a supported DASH video track"
        case IPTVRelayCheckingVideo: phase = "decrypting or decoding the first video frames"
        case IPTVRelaySendingVideo: phase = "sending video to the Apple TV player"
        default: phase = "starting DASH playback"
        }
        if http_status > 0 {
            return "ClearKey: the server returned HTTP \(http_status) while \(phase)."
        }
        if timedOut {
            return "ClearKey: startup timed out while \(phase)."
        }
        if source_error != 0 {
            let reason: String
            switch URLError.Code(rawValue: Int(network_error)) {
            case .cannotFindHost, .dnsLookupFailed: reason = "DNS could not find the source"
            case .cannotConnectToHost: reason = "Apple TV could not connect to the source"
            case .timedOut: reason = "the source request timed out"
            case .notConnectedToInternet, .networkConnectionLost: reason = "the network connection was unavailable"
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                reason = "the HTTPS connection could not be verified"
            case .dataLengthExceedsMaximum: reason = "the source response exceeded the 32 MB limit"
            case .cannotParseResponse: reason = "the source returned an invalid byte range"
            default: reason = "the source connection failed (network code \(network_error))"
            }
            return "ClearKey: \(reason) while \(phase)."
        }
        return "ClearKey failed while \(phase)."
    }
}

