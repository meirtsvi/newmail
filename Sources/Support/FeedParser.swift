import Foundation

/// Parses RSS 2.0 and Atom feeds into a common shape using Foundation's built-in
/// `XMLParser` (no third-party dependency). Tolerant by design: unknown elements
/// are ignored and a missing/unparseable date falls back to "now".
enum FeedParser {
    struct FeedItem {
        var title: String
        var link: String
        /// The item's rich HTML content (content:encoded / atom content / description / summary).
        var html: String
        /// Stable per-item identity used for de-duplication.
        var guid: String
        var date: Date
    }

    struct ParsedFeed {
        var title: String
        var items: [FeedItem]
    }

    static func parse(_ data: Data) -> ParsedFeed? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return ParsedFeed(title: delegate.feedTitle, items: delegate.items)
    }

    // MARK: Date parsing

    private static let rfc822Formatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, dd MMM yyyy HH:mm Z",
            "dd MMM yyyy HH:mm:ss Z",
        ]
        return formats.map { fmt in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            return f
        }
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func parseDate(_ raw: String) -> Date {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return Date() }
        if let d = isoFormatter.date(from: s) { return d }
        if let d = isoFractionalFormatter.date(from: s) { return d }
        for f in rfc822Formatters {
            if let d = f.date(from: s) { return d }
        }
        return Date()
    }
}

// MARK: - XMLParserDelegate

private final class Delegate: NSObject, XMLParserDelegate {
    var feedTitle = ""
    var items: [FeedParser.FeedItem] = []

    private var text = ""
    private var inItem = false
    private var isAtom = false

    // Accumulators for the item currently being parsed.
    private var curTitle = ""
    private var curLink = ""          // RSS <link> text
    private var curDescription = ""
    private var curContentEncoded = ""
    private var curContent = ""       // Atom <content>
    private var curSummary = ""
    private var curGuid = ""          // RSS <guid>
    private var curId = ""            // Atom <id>
    private var curDate = ""
    private var atomAlternateLink = ""
    private var atomFirstLink = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = elementName.lowercased()
        text = ""

        switch name {
        case "feed":
            isAtom = true
        case "item", "entry":
            inItem = true
            if name == "entry" { isAtom = true }
            resetItem()
        case "link" where inItem && isAtom:
            let href = attributes["href"] ?? ""
            guard !href.isEmpty else { break }
            let rel = attributes["rel"] ?? "alternate"
            if rel == "alternate", atomAlternateLink.isEmpty { atomAlternateLink = href }
            if atomFirstLink.isEmpty { atomFirstLink = href }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let s = String(data: CDATABlock, encoding: .utf8) { text += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if inItem {
            switch name {
            case "title": curTitle = value
            case "link": if !isAtom { curLink = value }
            case "description": curDescription = value
            case "content:encoded": curContentEncoded = value
            case "content": if isAtom { curContent = value }
            case "summary": curSummary = value
            case "guid": curGuid = value
            case "id": curId = value
            case "pubdate": curDate = value
            case "dc:date": if curDate.isEmpty { curDate = value }
            case "updated": curDate = value
            case "published": if curDate.isEmpty { curDate = value }
            case "item", "entry":
                finalizeItem()
                inItem = false
            default:
                break
            }
        } else if name == "title", feedTitle.isEmpty {
            feedTitle = value
        }

        text = ""
    }

    private func resetItem() {
        curTitle = ""; curLink = ""; curDescription = ""; curContentEncoded = ""
        curContent = ""; curSummary = ""; curGuid = ""; curId = ""; curDate = ""
        atomAlternateLink = ""; atomFirstLink = ""
    }

    private func finalizeItem() {
        let html = [curContentEncoded, curContent, curDescription, curSummary]
            .first { !$0.isEmpty } ?? ""
        let link = isAtom ? (atomAlternateLink.isEmpty ? atomFirstLink : atomAlternateLink) : curLink
        var guid = [curGuid, curId, link].first { !$0.isEmpty } ?? ""
        if guid.isEmpty { guid = "\(curTitle)|\(curDate)" }
        items.append(FeedParser.FeedItem(
            title: curTitle,
            link: link,
            html: html,
            guid: guid,
            date: FeedParser.parseDate(curDate)
        ))
    }
}
