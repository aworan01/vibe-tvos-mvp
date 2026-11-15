import Foundation

enum M3UParserError: LocalizedError {
    case invalidEncoding
    case noEntries
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidEncoding: return "The file is not valid UTF-8."
        case .noEntries: return "No complete playlist entries were found."
        case .tooLarge: return "The playlist is larger than the 8 MB import limit."
        }
    }
}

struct M3UParser {
    static let maximumBytes = 8_388_608

    func parse(data: Data) throws -> [Channel] {
        guard data.count <= Self.maximumBytes else { throw M3UParserError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw M3UParserError.invalidEncoding }
        return try parse(text)
    }

    func parse(_ text: String) throws -> [Channel] {
        var result: [Channel] = []
        var pending: PendingEntry?

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.uppercased().hasPrefix("#EXTINF:") {
                pending = parseEXTINF(line)
            } else if line.uppercased().hasPrefix("#EXTVLCOPT:") {
                pending?.appendOption(line, prefix: "#EXTVLCOPT:", toKodi: false)
            } else if line.uppercased().hasPrefix("#KODIPROP:") {
                pending?.appendOption(line, prefix: "#KODIPROP:", toKodi: true)
            } else if !line.hasPrefix("#"), var item = pending, let url = URL(string: line),
                      let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                result.append(item.channel(url: url))
                pending = nil
            }
        }
        guard !result.isEmpty else { throw M3UParserError.noEntries }
        return result
    }

    private func parseEXTINF(_ line: String) -> PendingEntry {
        let body = String(line.dropFirst("#EXTINF:".count))
        let split = splitMetadataAndName(body)
        let metadata = split.0
        let name = split.1.trimmingCharacters(in: .whitespaces)
        let firstSpace = metadata.firstIndex(of: " ")
        let durationText = firstSpace.map { String(metadata[..<$0]) } ?? metadata
        let attributeText = firstSpace.map { String(metadata[metadata.index(after: $0)...]) } ?? ""
        return PendingEntry(name: name.isEmpty ? "Untitled Channel" : name,
                            duration: Double(durationText), attributes: parseAttributes(attributeText),
                            rawMetadataLines: [line])
    }

    private func splitMetadataAndName(_ value: String) -> (String, String) {
        var quoted = false
        for index in value.indices {
            if value[index] == "\"" { quoted.toggle() }
            if value[index] == ",", !quoted {
                return (String(value[..<index]), String(value[value.index(after: index)...]))
            }
        }
        return (value, "")
    }

    private func parseAttributes(_ text: String) -> [String: String] {
        var output: [String: String] = [:]
        let pattern = #"([A-Za-z0-9_-]+)\s*=\s*(?:\"([^\"]*)\"|([^\s]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return output }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let valueIndex = match.range(at: 2).location != NSNotFound ? 2 : 3
            guard let valueRange = Range(match.range(at: valueIndex), in: text) else { continue }
            output[String(text[keyRange]).lowercased()] = String(text[valueRange])
        }
        return output
    }
}

private struct PendingEntry {
    var name: String
    var duration: Double?
    var attributes: [String: String]
    var vlcOptions: [String: String] = [:]
    var kodiProperties: [String: String] = [:]
    var rawMetadataLines: [String]

    mutating func appendOption(_ line: String, prefix: String, toKodi: Bool) {
        rawMetadataLines.append(line)
        let body = String(line.dropFirst(prefix.count))
        let parts = body.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        if toKodi { kodiProperties[parts[0].lowercased()] = parts[1] }
        else { vlcOptions[parts[0].lowercased()] = parts[1] }
    }

    func channel(url: URL) -> Channel {
        Channel(id: UUID(), name: name, streamURL: url, duration: duration,
                attributes: attributes, vlcOptions: vlcOptions,
                kodiProperties: kodiProperties, rawMetadataLines: rawMetadataLines)
    }
}

