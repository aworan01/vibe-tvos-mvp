import Foundation

enum XMLTVError: LocalizedError {
    case tooLarge
    case invalid
    case empty

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "The XMLTV guide is larger than 16 MB."
        case .invalid: return "The XMLTV guide could not be parsed."
        case .empty: return "The XMLTV guide contains no usable programmes."
        }
    }
}

enum XMLTVParser {
    static let maximumBytes = 16_777_216

    static func parse(_ data: Data, now: Date = Date()) throws -> [EPGProgramme] {
        guard data.count <= maximumBytes else { throw XMLTVError.tooLarge }
        let delegate = XMLTVDelegate(
            earliest: now.addingTimeInterval(-12 * 60 * 60),
            latest: now.addingTimeInterval(7 * 24 * 60 * 60)
        )
        let parser = Foundation.XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.error == nil else {
            throw delegate.error ?? XMLTVError.invalid
        }
        guard !delegate.programmes.isEmpty else { throw XMLTVError.empty }
        return delegate.programmes
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    struct Pending {
        let channelID: String
        let start: Date
        let end: Date
        var title = ""
        var subtitle = ""
        var summary = ""
    }

    let earliest: Date
    let latest: Date
    var programmes: [EPGProgramme] = []
    var error: Error?
    private var channelNames: [String: String] = [:]
    private var currentChannelID: String?
    private var currentChannelName = ""
    private var pending: Pending?
    private var field: String?
    private var text = ""

    init(earliest: Date, latest: Date) {
        self.earliest = earliest
        self.latest = latest
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "channel":
            currentChannelID = attributeDict["id"]
            currentChannelName = ""
        case "programme":
            guard let channel = attributeDict["channel"],
                  let start = attributeDict["start"].flatMap(Self.date),
                  let end = attributeDict["stop"].flatMap(Self.date),
                  end > earliest,
                  start < latest else {
                pending = nil
                return
            }
            pending = Pending(channelID: channel, start: start, end: end)
        case "display-name", "title", "sub-title", "desc":
            field = elementName
            text = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field != nil { text += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "display-name":
            if currentChannelName.isEmpty { currentChannelName = value }
        case "channel":
            if let id = currentChannelID, !currentChannelName.isEmpty {
                channelNames[id] = currentChannelName
            }
            currentChannelID = nil
            currentChannelName = ""
        case "title":
            pending?.title = value
        case "sub-title":
            pending?.subtitle = value
        case "desc":
            pending?.summary = value
        case "programme":
            if let item = pending, !item.title.isEmpty, programmes.count < 50_000 {
                programmes.append(EPGProgramme(
                    id: "\(item.channelID)|\(Int(item.start.timeIntervalSince1970))|\(item.title)",
                    channelID: item.channelID,
                    channelName: channelNames[item.channelID],
                    title: item.title,
                    subtitle: item.subtitle.isEmpty ? nil : item.subtitle,
                    summary: item.summary.isEmpty ? nil : item.summary,
                    start: item.start,
                    end: item.end
                ))
            }
            pending = nil
        default:
            break
        }
        if field == elementName {
            field = nil
            text = ""
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }

    private static func date(_ value: String) -> Date? {
        let formats = ["yyyyMMddHHmmss Z", "yyyyMMddHHmmssZ", "yyyyMMddHHmmss"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
