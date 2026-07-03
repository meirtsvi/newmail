import Foundation
import SwiftData

/// Builds the on-demand Hebrew newsletter digest: collects the last week's
/// newsletter-labeled messages still sitting in the Inbox that no previous digest
/// has covered (across Gmail accounts), has Gemini — in small coverage-checked
/// batches — merge duplicate stories into one RTL Hebrew page, and delivers it via
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
    /// Per-message text budget sent to Gemini. Generous: digest-style newsletters
    /// (e.g. a daily AI roundup) pack many distinct stories into one mail, and a
    /// tight cap silently drops the stories in the truncated tail.
    private static let maxItemChars = 12000
    /// How far back sources reach. Marking a sender labels its entire history —
    /// without a window one digest would sweep a year of archived newsletters
    /// (real but ancient stories that read as hallucinations).
    private static let sourceWindow: TimeInterval = 7 * 24 * 3600
    /// Batch limits per Gemini call. One call over dozens of messages exceeds
    /// what the model reliably covers — items silently fall out. Small batches
    /// plus a per-batch coverage retry make message-level coverage dependable.
    private static let maxBatchItems = 8
    private static let maxBatchChars = 60_000

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
        // Sources: newsletter-labeled messages from the last week that no prior
        // digest covered. The ledger keeps an immediate re-run empty; the window
        // keeps a newly-marked sender's multi-year history out.
        let records = (try? context.fetch(FetchDescriptor<DigestRecord>())) ?? []
        let covered = Set(records.flatMap { $0.sources.map(\.messageId) })
        let since = Date().addingTimeInterval(-Self.sourceWindow)

        var sources: [(account: SourceAccount, header: MessageHeader)] = []
        for account in accounts {
            for header in store.headers(withLabel: account.labelId, accountId: account.accountId,
                                        since: since)
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

        // Summarize in small batches, re-asking once per batch for anything the
        // model failed to cover. Coverage is checked per message index, so a
        // dropped message can't slip through silently — the worst case is the
        // (now rare) fallback list, never a missing item.
        let batches = Self.packBatches(items)
        var sections: [String] = []
        var uncoveredIndexes: [Int] = []
        var lastError: Error?
        for (number, batch) in batches.enumerated() {
            progress("Digest: summarizing part \(number + 1) of \(batches.count)…")
            var pending = batch
            for _ in 0..<2 {
                do {
                    let output = try await summarize(pending.map { items[$0] })
                    sections.append(output.html)
                    pending = pending.filter { !output.covered.contains($0) }
                } catch {
                    lastError = error
                    break
                }
                if pending.isEmpty { break }
            }
            uncoveredIndexes.append(contentsOf: pending)
        }
        if sections.isEmpty, let lastError { throw lastError }
        let uncovered = uncoveredIndexes.sorted().map { (items[$0], sources[$0].header) }
        let html = Self.assemble(digestBody: sections.joined(separator: "\n"),
                                 itemCount: sources.count,
                                 uncovered: uncovered)

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

    /// Groups item indexes into batches bounded by item count and total chars
    /// (same idea as the translator's `packBatches`).
    private static func packBatches(_ items: [[String: Any]]) -> [[Int]] {
        var batches: [[Int]] = []
        var current: [Int] = []
        var currentChars = 0
        for (i, item) in items.enumerated() {
            let size = (item["text"] as? String)?.count ?? 0
            if !current.isEmpty && (currentChars + size > maxBatchChars || current.count >= maxBatchItems) {
                batches.append(current)
                current = [i]
                currentChars = size
            } else {
                current.append(i)
                currentChars += size
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

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
                // A many-story digest in Hebrew is long; the default output cap
                // would truncate the JSON mid-string and fail the parse.
                let text = try await TranslationService.shared.geminiGenerate(
                    system: Self.digestSystem, userText: input, responseSchema: schema,
                    maxOutputTokens: 32768
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
    You build a Hebrew news digest from newsletter and RSS messages. The input is a JSON \
    array of messages: {index, title, source, date, link, text}. A single message is often \
    itself a newsletter whose text contains MANY distinct news items.
    Rules:
    - Extract EVERY distinct news item from EVERY message. Never compress a multi-story \
    newsletter into one entry — a message reporting 12 stories yields 12 entries (before \
    merging duplicates). Nothing substantive in the input text may be skipped.
    - Entries that report the SAME story (within or across messages) must be merged into \
    ONE entry; that entry's source list must include EVERY merged source.
    - Group entries under short Hebrew topic headings (<h3>).
    - Each entry: a bold title line (<b>), a 1–3 sentence Hebrew summary, then its sources \
    as <a href="...">source name</a>, comma-separated (use the plain source name when the \
    message's link field is empty).
    - Write natural, fluent Hebrew prose — do not transliterate. Keep product names, \
    company names, model names, code, CLI commands, and URLs in English.
    - Return JSON: {"html": "...", "covered": [...]} where html is the digest as HTML \
    body markup (no <html>/<head>/<body> wrapper, no dir attributes — it is wrapped in an \
    RTL container later) and covered lists the index of every input message whose content \
    you included.
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
