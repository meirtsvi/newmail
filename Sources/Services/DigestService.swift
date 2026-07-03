import Foundation
import SwiftData

/// Builds the on-demand Hebrew newsletter digest: collects every newsletter-labeled
/// message no previous digest has covered (across Gmail accounts), has Gemini merge
/// duplicate stories and summarize everything into one RTL Hebrew page — covering
/// every item, with all source links — and delivers it as a real Inbox message via
/// `MIMEBuilder` + `importRawMessage` (the same machinery behind RSS items). A
/// `DigestRecord` remembers the covered messages for the "Delete source mails"
/// button and to keep them out of the next digest.
@MainActor
final class DigestService {

    /// A Gmail account contributing sources: its provider and Newsletter label id.
    struct SourceAccount {
        let accountId: String
        let provider: MailProvider
        let labelId: String
    }

    /// Sender of every digest message; how the reading pane recognizes a digest.
    static let fromAddress = "digest@newmail.local"
    /// Per-item text budget sent to Gemini (full articles can be very long).
    private static let maxItemChars = 2500

    private let store: MailStore
    private let context: ModelContext

    init(store: MailStore, context: ModelContext) {
        self.store = store
        self.context = context
    }

    /// Generates and delivers one digest. Returns nil when there is nothing new
    /// to cover; throws when Gemini or the delivery fails.
    func generate(
        accounts: [SourceAccount],
        destination: MailProvider,
        progress: @escaping (String) -> Void
    ) async throws -> (digestId: String, sourceCount: Int)? {
        // Sources: every newsletter-labeled message a prior digest hasn't covered.
        // No date window — marking a sender labels its whole history, and all of
        // it belongs in the next digest; the covered ledger alone is what makes
        // an immediate re-run find nothing new.
        let records = (try? context.fetch(FetchDescriptor<DigestRecord>())) ?? []
        let covered = Set(records.flatMap { $0.sources.map(\.messageId) })

        var sources: [(account: SourceAccount, header: MessageHeader)] = []
        for account in accounts {
            for header in store.headers(withLabel: account.labelId, accountId: account.accountId,
                                        since: .distantPast)
            where header.from.email != Self.fromAddress && !covered.contains(header.id) {
                sources.append((account, header))
            }
        }
        guard !sources.isEmpty else { return nil }
        sources.sort { $0.header.date < $1.header.date }

        progress("Digest: reading \(sources.count) item\(sources.count == 1 ? "" : "s")…")
        var items: [[String: Any]] = []
        for (index, source) in sources.enumerated() {
            let body = await body(for: source.header, provider: source.account.provider)
            var text = body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty, let html = body?.html { text = Self.stripHTML(html) }
            items.append([
                "index": index,
                "title": source.header.subject,
                "source": source.header.from.display,
                "date": source.header.date.formatted(date: .abbreviated, time: .shortened),
                "link": Self.primaryLink(in: body?.html ?? "") ?? "",
                "text": String(text.prefix(Self.maxItemChars)),
            ])
        }

        progress("Digest: summarizing \(items.count) item\(items.count == 1 ? "" : "s") with Gemini…")
        let output = try await summarize(items)
        let uncovered = sources.enumerated().filter { !output.covered.contains($0.offset) }
        let html = Self.assemble(digestBody: output.html,
                                 itemCount: sources.count,
                                 uncovered: uncovered.map { (items[$0.offset], $0.element.header) })

        progress("Digest: delivering to the Inbox…")
        let to = destination.accountEmail.isEmpty ? Self.fromAddress : destination.accountEmail
        let subject = "סיכום ניוזלטרים — \(sources.count) items"
        let raw = MIMEBuilder.buildHTML(
            from: "\"Newsletter Digest\" <\(Self.fromAddress)>",
            to: to, cc: "", subject: subject, html: html, attachments: []
        )
        let digestId = try await destination.importRawMessage(raw, toFolderId: "INBOX", markUnread: true)

        let sourcesRaw = sources
            .map { "\($0.account.accountId)\u{1}\($0.header.id)" }
            .joined(separator: ",")
        context.insert(DigestRecord(digestMessageId: digestId, sourcesRaw: sourcesRaw))
        try? context.save()
        return (digestId, sources.count)
    }

    /// A source's body: cached, else fetched via its own account (and cached).
    private func body(for header: MessageHeader, provider: MailProvider) async -> MessageBody? {
        if let cached = store.cachedBody(id: header.id) { return cached }
        guard let fetched = try? await provider.fetchBody(id: header.id) else { return nil }
        store.saveBody(fetched)
        return fetched
    }

    // MARK: - Gemini

    private struct DigestOutput: Decodable {
        let html: String
        let covered: [Int]
    }

    /// One structured Gemini call (with a retry): items in, {html, covered} out.
    private func summarize(_ items: [[String: Any]]) async throws -> (html: String, covered: Set<Int>) {
        let data = try JSONSerialization.data(withJSONObject: items)
        let input = String(decoding: data, as: UTF8.self)
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "html": ["type": "STRING"],
                "covered": ["type": "ARRAY", "items": ["type": "INTEGER"]],
            ],
            "required": ["html", "covered"],
        ]
        var lastError: Error = TranslationError.emptyResponse
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                let text = try await TranslationService.shared.geminiGenerate(
                    system: Self.digestSystem, userText: input, responseSchema: schema
                )
                if let parsed = try? JSONDecoder().decode(DigestOutput.self, from: Data(text.utf8)),
                   !parsed.html.isEmpty {
                    return (parsed.html, Set(parsed.covered))
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static let digestSystem = """
    You build a Hebrew digest of newsletter and RSS items. The input is a JSON array of \
    items: {index, title, source, date, link, text}.
    Rules:
    - Write natural, fluent Hebrew prose — do not transliterate. Keep product names, \
    company names, model names, code, CLI commands, and URLs in English.
    - Group related items under short Hebrew topic headings (<h3>).
    - Items that report the SAME story must be merged into ONE entry; that entry's link \
    list must include EVERY merged item's link.
    - Cover EVERY input item exactly once. Do not skip or drop any item.
    - Each entry: a bold title line (<b>), a 1–3 sentence Hebrew summary, then its source \
    links as <a href="...">source name</a>, comma-separated. Skip the link when an item's \
    link field is empty.
    - Return JSON: {"html": "...", "covered": [...]} where html is the digest as HTML \
    body markup (no <html>/<head>/<body> wrapper, no dir attributes — it is wrapped in an \
    RTL container later) and covered lists the index of every input item you included.
    """

    // MARK: - HTML assembly

    /// Wraps Gemini's digest markup in the RTL container, prefixed by a count line
    /// and followed by a fallback list of any items the model failed to cover (so
    /// the digest never silently drops an item).
    private static func assemble(
        digestBody: String, itemCount: Int,
        uncovered: [(item: [String: Any], header: MessageHeader)]
    ) -> String {
        var html = """
        <div dir="rtl" style="text-align:right; line-height:1.6">
        <p style="color:#666">סיכום של \(itemCount) פריטים</p>
        \(digestBody)
        """
        if !uncovered.isEmpty {
            html += "\n<hr><h3>פריטים נוספים</h3><ul>"
            for entry in uncovered {
                let title = TranslationService.htmlEscape(entry.header.subject)
                let source = TranslationService.htmlEscape(entry.header.from.display)
                let link = entry.item["link"] as? String ?? ""
                if link.isEmpty {
                    html += "<li><b>\(title)</b> — \(source)</li>"
                } else {
                    html += "<li><b>\(title)</b> — <a href=\"\(link)\">\(source)</a></li>"
                }
            }
            html += "</ul>"
        }
        return html + "\n</div>"
    }

    /// The item's best "original article" URL: the `<base href>` a full-article
    /// import carries, else a "View original" link, else the first http(s) link.
    private static func primaryLink(in html: String) -> String? {
        guard !html.isEmpty else { return nil }
        if let base = firstMatch("<base\\s+href=[\"']([^\"']+)[\"']", in: html) { return base }
        if let original = firstMatch(
            "<a\\s+href=[\"']([^\"']+)[\"']>\\s*View original\\s*</a>", in: html) { return original }
        return firstMatch("<a\\b[^>]*href=[\"'](https?://[^\"']+)[\"']", in: html)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Crude tag strip for bodies with no plain-text part (style/script dropped
    /// first so their contents don't leak into the summary input).
    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }
}

// MARK: - DigestRecord sources

extension DigestRecord {
    /// Decodes `sourcesRaw` ("accountId\u{1}messageId" pairs joined by ",").
    var sources: [(accountId: String, messageId: String)] {
        sourcesRaw.split(separator: ",").compactMap { pair in
            let parts = pair.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }
}
