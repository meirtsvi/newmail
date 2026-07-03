import Foundation
import SwiftData

/// Builds the on-demand Hebrew newsletter digest from the last week's
/// newsletter-labeled Inbox messages that no previous digest covered.
///
/// Two-stage pipeline with mechanical accounting, so no story inside a
/// newsletter can be *silently* skipped:
/// 1. Each message's text is mechanically split into numbered segments; Gemini
///    extracts every story as `{title_he, summary_he, link, segments:[ids]}`
///    plus `noise:[ids]`. Every segment id must be accounted for — missing ids
///    are re-asked, and whatever still isn't covered becomes a verbatim item.
/// 2. The extracted items are composed into one topic-grouped RTL Hebrew page;
///    every item id must appear in the model's `covered` list — missing items
///    are re-asked, then appended mechanically from their own Hebrew text.
///
/// Guaranteed: every character lands in a segment; every segment is in an item,
/// explicitly classified as noise, or force-included; every item reaches the
/// final HTML. NOT guaranteed: that content-vs-noise classification is always
/// right — a story can only vanish by explicit misclassification, which is why
/// the digest ends with a collapsed, auditable "classified as noise" section.
///
/// Delivery via `MIMEBuilder` + `importRawMessage` (the RSS-import machinery);
/// a `DigestRecord` remembers covered messages for "Delete source mails" and
/// keeps them out of the next digest.
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
    /// How far back sources reach. Marking a sender labels its entire history —
    /// without a window one digest would sweep a year of archived newsletters.
    private static let sourceWindow: TimeInterval = 7 * 24 * 3600

    /// Text budget for RSS full-article messages (one story by construction, so
    /// truncation loses detail of that story, never a separate story).
    private static let rssItemChars = 12_000
    /// Safety ceiling per newsletter message; truncation is noted in the audit.
    private static let messageCeiling = 100_000
    /// Segment size band: blank-line blocks are greedily merged up to the max.
    private static let minSegmentChars = 200
    private static let maxSegmentChars = 1800
    /// Extraction call limits (segments per Gemini call).
    private static let extractionChunkSegments = 50
    private static let extractionChunkChars = 24_000
    /// How many messages extract concurrently.
    private static let extractionConcurrency = 4
    /// Digest-stage call limits (extracted items are short, ~1 call typically).
    private static let digestBatchChars = 60_000
    private static let digestBatchItems = 120

    private let store: MailStore
    private let context: ModelContext

    init(store: MailStore, context: ModelContext) {
        self.store = store
        self.context = context
    }

    // MARK: - Types

    /// One extracted story, carried from extraction into the digest stage.
    private struct SourceItem {
        let id: Int              // global sequential id (digest-stage accounting)
        let sourceIndex: Int
        let titleHe: String
        let summaryHe: String
        let link: String
        let source: String       // From display name
        let date: String
        let forced: Bool         // segment force-included verbatim after re-asks
    }

    private struct ExtractionOutput: Decodable {
        struct Item: Decodable {
            let title_he: String
            let summary_he: String
            let link: String?
            let segments: [Int]
        }
        let items: [Item]
        let noise: [Int]
    }

    private struct DigestOutput: Decodable {
        let html: String
        let covered: [Int]
    }

    /// What extraction produced for one source message.
    private enum PerSource {
        case extracted(items: [(title: String, summary: String, link: String, forced: Bool)],
                       noiseSnippets: [String], truncated: Bool)
        case failed
    }

    // MARK: - Generate

    /// Generates and delivers one digest. Returns nil when there is nothing new
    /// to cover; throws only when nothing at all could be produced or delivered.
    func generate(
        accounts: [SourceAccount],
        destination: MailProvider,
        progress: @escaping (String) -> Void
    ) async throws -> (digestId: String, sourceCount: Int)? {
        // Sources: newsletter-labeled Inbox messages from the last week that no
        // prior digest covered (the ledger keeps an immediate re-run empty).
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

        // Stage 1: extract every story from every message (a few at a time).
        progress("Digest: extracting stories… (0/\(sources.count))")
        var perSource = [PerSource](repeating: .failed, count: sources.count)
        var links = [String](repeating: "", count: sources.count)
        var done = 0
        var window = 0
        while window < sources.count {
            let slice = Array(window..<min(window + Self.extractionConcurrency, sources.count))
            await withTaskGroup(of: (Int, PerSource, String).self) { group in
                for index in slice {
                    let source = sources[index]
                    group.addTask { @MainActor [weak self] in
                        guard let self else { return (index, .failed, "") }
                        return await self.extractSource(source.header, provider: source.account.provider,
                                                        index: index)
                    }
                }
                for await (index, result, link) in group {
                    perSource[index] = result
                    links[index] = link
                    done += 1
                    progress("Digest: extracting stories… (\(done)/\(sources.count))")
                }
            }
            window += Self.extractionConcurrency
        }

        // Flatten to globally-numbered items (source order == date order).
        var items: [SourceItem] = []
        var appendix: [(header: MessageHeader, link: String)] = []
        var audit: [(source: String, snippets: [String], truncated: Bool)] = []
        for (index, source) in sources.enumerated() {
            switch perSource[index] {
            case .extracted(let extracted, let noiseSnippets, let truncated):
                for entry in extracted {
                    items.append(SourceItem(
                        id: items.count, sourceIndex: index,
                        titleHe: entry.title, summaryHe: entry.summary,
                        link: entry.link.isEmpty ? links[index] : entry.link,
                        source: source.header.from.display,
                        date: source.header.date.formatted(date: .abbreviated, time: .shortened),
                        forced: entry.forced
                    ))
                }
                if !noiseSnippets.isEmpty || truncated {
                    audit.append((source.header.from.display, noiseSnippets, truncated))
                }
            case .failed:
                appendix.append((source.header, links[index]))
            }
        }
        guard !items.isEmpty || !appendix.isEmpty else {
            throw TranslationError.emptyResponse
        }

        // Stage 2: compose the digest; every item id is mechanically accounted.
        progress("Digest: composing the digest…")
        let digestBody = items.isEmpty ? "" : await composeDigest(items, progress: progress)

        let html = Self.assemble(
            digestBody: digestBody,
            itemCount: items.count,
            forcedCount: items.filter(\.forced).count,
            appendix: appendix,
            audit: audit
        )

        progress("Digest: delivering to the Inbox…")
        let to = destination.accountEmail.isEmpty ? Self.fromAddress : destination.accountEmail
        let subject = "סיכום ניוזלטרים — \(items.count) items"
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

    // MARK: - Stage 1: extraction

    /// Extracts one source message: RSS full articles get a single-story
    /// summary; newsletters go through segment-accounted extraction. Returns
    /// the message's primary link alongside so the appendix can use it too.
    private func extractSource(
        _ header: MessageHeader, provider: MailProvider, index: Int
    ) async -> (Int, PerSource, String) {
        let body = await body(for: header, provider: provider)
        var text = body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty, let html = body?.html { text = Self.stripHTML(html) }
        let link = Self.primaryLink(in: body?.html ?? "") ?? ""
        guard !text.isEmpty else { return (index, .failed, link) }

        // RSS items are one story per message by construction — no accounting
        // needed to know nothing else hides inside.
        if header.from.email == FeedService.fromAddress {
            if let item = await summarizeSingleArticle(
                title: header.subject, text: String(text.prefix(Self.rssItemChars))
            ) {
                return (index, .extracted(items: [(item.title, item.summary, link, false)],
                                          noiseSnippets: [], truncated: false), link)
            }
            return (index, .failed, link)
        }

        let truncated = text.count > Self.messageCeiling
        if truncated { text = String(text.prefix(Self.messageCeiling)) }
        let segments = Self.segment(text)
        guard !segments.isEmpty else { return (index, .failed, link) }

        guard let output = await extractItems(
            subject: header.subject, source: header.from.display, link: link, segments: segments
        ) else {
            return (index, .failed, link)
        }
        let noiseSnippets = output.noiseIds.sorted().compactMap { id -> String? in
            guard segments.indices.contains(id) else { return nil }
            return String(segments[id].prefix(80))
        }
        return (index, .extracted(items: output.items, noiseSnippets: noiseSnippets,
                                  truncated: truncated), link)
    }

    /// Segment-accounted extraction over one newsletter's segments. Nil only
    /// when a Gemini call failed outright (message falls back to the appendix);
    /// unaccounted segments never disappear — they become verbatim items.
    private func extractItems(
        subject: String, source: String, link: String, segments: [String]
    ) async -> (items: [(title: String, summary: String, link: String, forced: Bool)], noiseIds: Set<Int>)? {
        // Chunk the segment ids into call-sized groups. A story split across a
        // boundary yields two items; the digest stage's dedup merges them.
        var chunks: [[Int]] = []
        var current: [Int] = []
        var chars = 0
        for (id, segment) in segments.enumerated() {
            if !current.isEmpty && (chars + segment.count > Self.extractionChunkChars
                                    || current.count >= Self.extractionChunkSegments) {
                chunks.append(current)
                current = []
                chars = 0
            }
            current.append(id)
            chars += segment.count
        }
        if !current.isEmpty { chunks.append(current) }

        var items: [ExtractionOutput.Item] = []
        var noise: Set<Int> = []
        for chunk in chunks {
            guard let output = await extractionCall(
                subject: subject, source: source, link: link,
                segments: chunk.map { ($0, segments[$0]) }
            ) else { return nil }
            items.append(contentsOf: output.items)
            noise.formUnion(output.noise)
        }

        // Mechanical accounting: every segment id must be in an item or noise.
        // One re-ask with only the missing segments; whatever remains is
        // force-included verbatim so it cannot be silently dropped.
        var accounted = noise
        for item in items { accounted.formUnion(item.segments) }
        var missing = Set(segments.indices).subtracting(accounted)
        if !missing.isEmpty {
            if let retry = await extractionCall(
                subject: subject, source: source, link: link,
                segments: missing.sorted().map { ($0, segments[$0]) }
            ) {
                items.append(contentsOf: retry.items)
                noise.formUnion(retry.noise)
                for item in retry.items { missing.subtract(item.segments) }
                missing.subtract(retry.noise)
            }
        }

        var result = items.map { item in
            (title: item.title_he, summary: item.summary_he, link: item.link ?? "", forced: false)
        }
        for id in missing.sorted() {
            let text = segments[id]
            result.append((title: String(text.prefix(90)), summary: text, link: "", forced: true))
        }
        return (result, noise)
    }

    /// One extraction call (with a retry): numbered segments in, items+noise out.
    private func extractionCall(
        subject: String, source: String, link: String, segments: [(id: Int, text: String)]
    ) async -> ExtractionOutput? {
        let payload: [String: Any] = [
            "title": subject,
            "source": source,
            "link": link,
            "segments": segments.map { ["id": $0.id, "text": $0.text] },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let input = String(decoding: data, as: UTF8.self)
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "items": ["type": "ARRAY", "items": [
                    "type": "OBJECT",
                    "properties": [
                        "title_he": ["type": "STRING"],
                        "summary_he": ["type": "STRING"],
                        "link": ["type": "STRING"],
                        "segments": ["type": "ARRAY", "items": ["type": "INTEGER"]],
                    ],
                    "required": ["title_he", "summary_he", "segments"],
                ] as [String: Any]],
                "noise": ["type": "ARRAY", "items": ["type": "INTEGER"]],
            ],
            "required": ["items", "noise"],
        ]
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let text = try? await TranslationService.shared.geminiGenerate(
                system: Self.extractionSystem, userText: input, responseSchema: schema,
                maxOutputTokens: 8192
            ), let parsed = try? JSONDecoder().decode(ExtractionOutput.self, from: Data(text.utf8)) {
                return parsed
            }
        }
        return nil
    }

    private static let extractionSystem = """
    You extract every distinct news story from ONE newsletter email. The input is JSON: \
    {title, source, link, segments: [{id, text}]} — the segments are consecutive fragments \
    of the email, in reading order. A story may span several segments; a segment may \
    contain several stories (then create several items that all reference that segment's id).
    Return {"items": [{title_he, summary_he, link, segments: [ids]}], "noise": [ids]}.
    Rules:
    - One item per distinct story. title_he: a short Hebrew headline. summary_he: 1–3 \
    sentences of natural, fluent Hebrew. link: the story's URL if one appears in its \
    segments, else "". segments: EVERY id whose text contributed to this item.
    - noise: ids whose text contains NO news content at all — unsubscribe/legal footers, \
    sponsor ads, navigation, greetings, social buttons, "view in browser" chrome.
    - EVERY input id must appear in items[].segments or in noise. When unsure whether a \
    segment is content, create an item for it — never guess noise.
    - Keep product names, company names, model names, code, CLI commands, and URLs in \
    English; do not transliterate. Write idiomatic Hebrew prose.
    """

    /// Single-story Hebrew summary for an RSS full-article message.
    private func summarizeSingleArticle(title: String, text: String) async -> (title: String, summary: String)? {
        struct Out: Decodable { let title_he: String; let summary_he: String }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "title_he": ["type": "STRING"],
                "summary_he": ["type": "STRING"],
            ],
            "required": ["title_he", "summary_he"],
        ]
        let input = "Title: \(title)\n\n\(text)"
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let text = try? await TranslationService.shared.geminiGenerate(
                system: Self.articleSystem, userText: input, responseSchema: schema,
                maxOutputTokens: 4096
            ), let parsed = try? JSONDecoder().decode(Out.self, from: Data(text.utf8)) {
                return (parsed.title_he, parsed.summary_he)
            }
        }
        return nil
    }

    private static let articleSystem = """
    You summarize one news article into Hebrew. Return {"title_he": a short Hebrew \
    headline, "summary_he": 2–4 sentences of natural, fluent Hebrew}. Keep product, \
    company, and model names, code, CLI commands, and URLs in English; do not transliterate.
    """

    // MARK: - Stage 2: digest composition

    /// Composes the final digest from the extracted items. Never loses an item:
    /// coverage is checked by item id, missing items are re-asked once, and
    /// whatever remains is appended mechanically from its own Hebrew text.
    private func composeDigest(_ items: [SourceItem], progress: (String) -> Void) async -> String {
        // Batch by size — extracted items are short, so this is one call in the
        // common case (which is what lets duplicates merge across newsletters);
        // cross-batch duplicates stay unmerged (repetition, never loss).
        var batches: [[SourceItem]] = []
        var current: [SourceItem] = []
        var chars = 0
        for item in items {
            let size = item.titleHe.count + item.summaryHe.count + item.link.count + 60
            if !current.isEmpty && (chars + size > Self.digestBatchChars
                                    || current.count >= Self.digestBatchItems) {
                batches.append(current)
                current = []
                chars = 0
            }
            current.append(item)
            chars += size
        }
        if !current.isEmpty { batches.append(current) }

        var sections: [String] = []
        for (number, batch) in batches.enumerated() {
            if batches.count > 1 {
                progress("Digest: composing part \(number + 1) of \(batches.count)…")
            }
            var pending = batch
            var covered: Set<Int> = []
            for _ in 0..<2 {
                guard let output = await digestCall(pending) else { break }
                sections.append(output.html)
                covered.formUnion(output.covered)
                pending = pending.filter { !covered.contains($0.id) }
                if pending.isEmpty { break }
            }
            // Mechanical fallback: anything the model failed to weave in (or a
            // batch whose calls failed outright) is rendered from its own
            // already-Hebrew title + summary.
            if !pending.isEmpty {
                sections.append(pending.map(Self.renderItem).joined(separator: "\n"))
            }
        }
        return sections.joined(separator: "\n")
    }

    /// One digest-composition call; nil when both attempts fail.
    private func digestCall(_ items: [SourceItem]) async -> DigestOutput? {
        let payload = items.map { item -> [String: Any] in
            ["id": item.id, "title_he": item.titleHe, "summary_he": item.summaryHe,
             "source": item.source, "date": item.date, "link": item.link]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let input = String(decoding: data, as: UTF8.self)
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "html": ["type": "STRING"],
                "covered": ["type": "ARRAY", "items": ["type": "INTEGER"]],
            ],
            "required": ["html", "covered"],
        ]
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let text = try? await TranslationService.shared.geminiGenerate(
                system: Self.digestSystem, userText: input, responseSchema: schema,
                maxOutputTokens: 32768
            ), let parsed = try? JSONDecoder().decode(DigestOutput.self, from: Data(text.utf8)),
               !parsed.html.isEmpty {
                return parsed
            }
        }
        return nil
    }

    private static let digestSystem = """
    You compose a Hebrew news digest from pre-extracted story items. The input is a JSON \
    array of {id, title_he, summary_he, source, date, link}.
    Rules:
    - Items reporting the SAME story must be merged into ONE entry whose source links \
    include EVERY merged item's link.
    - Group entries under short Hebrew topic headings (<h3>).
    - Each entry: a bold title (<b>), a 1–3 sentence Hebrew summary (synthesize the \
    merged items' summaries), then its sources as <a href="...">source name</a>, \
    comma-separated (plain source name when an item's link is empty).
    - Do not drop items, and do not combine unrelated items. "covered" must list the id \
    of every input item whose content appears in the html.
    - Keep product, company, and model names, code, CLI commands, and URLs in English.
    - Return {"html": "...", "covered": [...]}: html is body markup only — no \
    <html>/<head>/<body> wrapper and no dir attributes (it is wrapped in an RTL \
    container later).
    """

    /// Mechanical rendering of one item (digest-stage fallback — already Hebrew).
    private static func renderItem(_ item: SourceItem) -> String {
        let title = TranslationService.htmlEscape(item.titleHe)
        let summary = TranslationService.htmlEscape(item.summaryHe)
        let source = TranslationService.htmlEscape(item.source)
        let attribution = item.link.isEmpty
            ? source
            : "<a href=\"\(item.link)\">\(source)</a>"
        return "<p><b>\(title)</b> — \(summary) \(attribution)</p>"
    }

    // MARK: - Segmentation

    /// Splits message text into numbered segments: blank-line blocks greedily
    /// merged into a size band. The coverage guarantee runs over these ids, so
    /// the only requirement is that no non-whitespace text is lost — story
    /// alignment only affects the granularity of the noise audit.
    static func segment(_ text: String) -> [String] {
        var blocks = split(text, on: "\n[ \t]*\n")
        // No blank lines (hard-wrapped plain text): fall back to single newlines.
        if blocks.count == 1, let only = blocks.first, only.count > maxSegmentChars {
            blocks = split(only, on: "\n")
        }
        // Still one giant run (fully collapsed text): hard-split on sentences.
        blocks = blocks.flatMap { block -> [String] in
            block.count <= maxSegmentChars ? [block] : hardSplit(block)
        }

        // Greedy merge into the size band: a segment closes once it reaches the
        // minimum (keeping audit granularity fine) or when the next block would
        // push it past the maximum.
        var segments: [String] = []
        var current = ""
        for block in blocks {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !current.isEmpty && current.count + trimmed.count > maxSegmentChars {
                segments.append(current)
                current = ""
            }
            current = current.isEmpty ? trimmed : current + "\n" + trimmed
            if current.count >= minSegmentChars {
                segments.append(current)
                current = ""
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func split(_ text: String, on pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let ns = text as NSString
        var parts: [String] = []
        var last = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    /// Splits an oversized block at the sentence boundary nearest each cut mark.
    private static func hardSplit(_ block: String) -> [String] {
        var parts: [String] = []
        var rest = Substring(block)
        while rest.count > maxSegmentChars {
            let window = rest.prefix(maxSegmentChars)
            let cut = window.lastIndex(of: ".").map(rest.index(after:))
                ?? window.lastIndex(of: " ").map(rest.index(after:))
                ?? window.endIndex
            parts.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { parts.append(String(rest)) }
        return parts
    }

    // MARK: - HTML assembly

    /// Count line (+ forced-items note) → digest → appendix of messages whose
    /// extraction failed outright → collapsed noise audit, all in an RTL wrapper.
    private static func assemble(
        digestBody: String, itemCount: Int, forcedCount: Int,
        appendix: [(header: MessageHeader, link: String)],
        audit: [(source: String, snippets: [String], truncated: Bool)]
    ) -> String {
        var countLine = "סיכום של \(itemCount) פריטים"
        if forcedCount > 0 {
            countLine += " (כולל \(forcedCount) שלא סוכמו במלואם)"
        }
        var html = """
        <div dir="rtl" style="text-align:right; line-height:1.6">
        <p style="color:#666">\(countLine)</p>
        \(digestBody)
        """
        if !appendix.isEmpty {
            html += "\n<hr><h3>הודעות שלא עובדו</h3><ul>"
            for entry in appendix {
                let title = TranslationService.htmlEscape(entry.header.subject)
                let source = TranslationService.htmlEscape(entry.header.from.display)
                html += entry.link.isEmpty
                    ? "<li><b>\(title)</b> — \(source)</li>"
                    : "<li><b>\(title)</b> — <a href=\"\(entry.link)\">\(source)</a></li>"
            }
            html += "</ul>"
        }
        if !audit.isEmpty {
            let total = audit.reduce(0) { $0 + $1.snippets.count }
            html += "\n<hr><details><summary style=\"color:#666\">קטעים שסווגו כרעש (\(total))</summary>"
            html += "<ul style=\"color:#888; font-size:0.9em\">"
            for entry in audit {
                let source = TranslationService.htmlEscape(entry.source)
                if entry.truncated {
                    html += "<li><b>\(source)</b>: ההודעה נחתכה מעבר ל-100,000 תווים</li>"
                }
                for snippet in entry.snippets {
                    html += "<li>\(source): \u{201C}\(TranslationService.htmlEscape(snippet))…\u{201D}</li>"
                }
            }
            html += "</ul></details>"
        }
        return html + "\n</div>"
    }

    // MARK: - Body & link helpers

    /// A source's body: cached, else fetched via its own account (and cached).
    private func body(for header: MessageHeader, provider: MailProvider) async -> MessageBody? {
        if let cached = store.cachedBody(id: header.id) { return cached }
        guard let fetched = try? await provider.fetchBody(id: header.id) else { return nil }
        store.saveBody(fetched)
        return fetched
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

    /// Tag strip for bodies with no plain-text part. Block-boundary tags become
    /// blank lines (not spaces) so the segmenter has real structure to split on;
    /// style/script bodies are dropped first so their contents don't leak in.
    static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: "</(p|div|td|tr|li|ul|ol|h1|h2|h3|h4|h5|h6|blockquote|table|section|article)>|<br[^>]*>",
                with: "\n\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
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
