import Foundation
import SwiftData

/// Builds the Hebrew newsletter digest from the last week's newsletter-labeled
/// Inbox messages that no previous digest covered.
///
/// Three stages with mechanical accounting, so no story can be *silently* lost:
/// 1. Each message's HTML is rewritten so every `<a href>` leaves a ` [L:n] `
///    marker behind, then split into numbered segments; Gemini extracts every
///    story as `{title_he, summary_he, links:[ids], entities, segments:[ids]}`
///    plus `noise:[ids]`. Every segment id must be accounted for — missing ids
///    are re-asked, a failed call is retried on each half of its chunk, and
///    whatever still isn't covered becomes a verbatim item.
/// 1.5 Items reporting the same story fold into one, then each is matched
///    against the cross-day `StoryRecord` ledger — against every live story,
///    not a shortlist — so a story first reported on Monday is reported on
///    Tuesday only as what changed, and a same-day repeat the in-run matcher
///    missed folds into the item it repeats.
/// 2. The new items are composed into one topic-grouped RTL Hebrew page; every
///    item id must appear in the model's `covered` list — missing items are
///    re-asked, then appended mechanically from their own Hebrew text.
///
/// Guaranteed: every character lands in a segment; every segment is in an item,
/// explicitly classified as noise, or force-included; every item reaches the
/// final HTML; and every URL in that HTML came verbatim from a source message,
/// because no model in the pipeline ever sees or writes a URL — only its id.
/// NOT guaranteed: that content-vs-noise classification is always right — a
/// story can only vanish by explicit misclassification, which is why the digest
/// ends with a collapsed, auditable "classified as noise" section.
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

    /// Story ledger: how long a story stays matchable.
    private static let storyRetention: TimeInterval = 21 * 24 * 3600
    /// Candidate budget for one cross-day match call. Every live story is a
    /// candidate, with its full gist: capping the list by count is exactly what
    /// let a story from the previous evening drop out of range and be reported
    /// as new the next morning. This is a ceiling on prompt size only — at the
    /// ledger's usual density it holds the entire retention window.
    private static let maxCandidateChars = 150_000
    private static let matchBatchItems = 40
    private static let matchBatchChars = 24_000
    /// How much of a candidate's summary the duplicate matcher sees. Enough to
    /// tell two stories apart, short enough that the whole accumulated list
    /// usually fits in one call.
    private static let matchSummaryChars = 220
    /// How much of a story's accumulated gist is kept for tomorrow's matcher.
    private static let maxGistChars = 1200

    private let store: MailStore
    private let context: ModelContext

    init(store: MailStore, context: ModelContext) {
        self.store = store
        self.context = context
    }

    // MARK: - Types

    /// One link kept from a source message: an id into the run's URL table plus
    /// the sentence it appeared in (which reads far better than "Read more").
    private struct LinkRef {
        let id: Int
        let title: String
    }

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
        let links: [LinkRef]     // ids into the run's global URL table
        let entities: [String]   // canonical English names, for the story ledger
        let significance: String // "major" | "normal" | "minor"
    }

    /// One story in the accumulating digest: the unit that survives in-run
    /// deduplication. Several `SourceItem`s from different newsletters fold
    /// into one of these.
    private struct DigestItem {
        var titleHe: String
        var summaryHe: String
        var links: [LinkRef]
        var entities: [String]
        var significance: String
        var sources: [String]      // contributing newsletters, in first-seen order
        var primaryLink: String    // fallback URL when the item kept no links
        var itemIds: [Int]         // the SourceItems folded in (accounting)
    }

    /// One extracted story before global numbering; its link ids are still
    /// local to its own message's URL table.
    private struct ExtractedEntry {
        let title: String
        let summary: String
        let link: String
        let forced: Bool
        let links: [LinkRef]
        let entities: [String]
        let significance: String
    }

    private struct ExtractionOutput: Decodable {
        struct Link: Decodable {
            let id: Int
            let title: String
        }
        struct Item: Decodable {
            let title_he: String
            let summary_he: String
            let link: String?
            let segments: [Int]
            let links: [Link]?
            let entities: [String]?
            let significance: String?
        }
        let items: [Item]
        let noise: [Int]
    }

    private struct MatchIndexOutput: Decodable {
        let match_index: Int
    }

    private struct MergeTextOutput: Decodable {
        let title_he: String
        let summary_he: String
    }

    private struct GroupOutput: Decodable {
        struct Group: Decodable {
            let heading: String
            let item_ids: [Int]
        }
        let groups: [Group]
    }

    /// One entry as it will be rendered — the shape both the model's output and
    /// the mechanical fallback are reduced to, so every piece of markup in the
    /// digest is produced by `renderEntries` and nowhere else. Letting the model
    /// emit HTML meant one uncooperative response ran every entry, summary and
    /// link together into a single wall of text.
    private struct Entry {
        let heading: String
        let titleHe: String
        let summaryHe: String
        let links: [(url: String, title: String)]
    }

    private enum MatchOutput {
        struct Match: Decodable {
            let story_id: String
            let delta_he: String?
            let is_new_info: Bool?
        }
    }

    /// What extraction produced for one source message.
    private enum PerSource {
        case extracted(items: [ExtractedEntry], noiseSnippets: [String], truncated: Bool,
                       urls: [String])
        case failed
    }

    /// Where one item lands relative to the cross-day story ledger.
    private enum Classification {
        case new
        case update(storyId: String, deltaHe: String, firstSeen: Date, firstSource: String)
        case echo(storyId: String)
        /// The same story as an item earlier in this very run — two newsletters
        /// from the same morning that the in-run matcher failed to pair. Folded
        /// into that item rather than printed a second time.
        case duplicate(ofIndex: Int)
    }

    /// A story as resolution sees it: a plain value, so the whole matching pass
    /// can run without touching SwiftData. Only `commitStories` writes, and only
    /// once the digest has actually been delivered — otherwise a failed delivery
    /// would leave the ledger claiming stories were covered, and the retry would
    /// report an almost empty digest.
    private struct PendingStory {
        let record: StoryRecord?   // nil for stories this run created
        var id: String
        var titleHe: String
        var gistHe: String
        var entities: [String]
        var firstSeen: Date
        var lastSeen: Date
        var mentionCount: Int
        var sources: [(vendor: String, url: String)]
        var touched: Bool          // matched this run, so it needs a write
    }

    /// Everything stage 1.5 decided, with its ledger writes still pending.
    private struct Resolution {
        var classification: [Int: Classification] = [:]
        var stories: [String: PendingStory] = [:]
        var expired: [StoryRecord] = []
    }

    /// One story's accumulated updates, for the mechanical updates section.
    private struct Update {
        let item: DigestItem
        let storyId: String
        let deltaHe: String
        let firstSeen: Date
        let firstSource: String
    }

    // MARK: - Generate

    /// Generates and delivers one digest. Returns nil when there is nothing new
    /// to cover; throws only when nothing at all could be produced or delivered.
    /// `archived` lists the sources actually archived, by account, so the caller
    /// can mirror the move in its local cache.
    func generate(
        accounts: [SourceAccount],
        destination: MailProvider,
        progress: @escaping (String) -> Void
    ) async throws -> (digestId: String, sourceCount: Int, archived: [String: [String]])? {
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

        // Flatten to globally-numbered items (source order == date order), and
        // concatenate every message's URL table into one run-wide table so an
        // item's link ids stay meaningful after the merge.
        var items: [SourceItem] = []
        var urls: [String] = []
        var appendix: [(header: MessageHeader, link: String)] = []
        var audit: [(source: String, snippets: [String], truncated: Bool)] = []
        for (index, source) in sources.enumerated() {
            switch perSource[index] {
            case .extracted(let extracted, let noiseSnippets, let truncated, let sourceURLs):
                let base = urls.count
                urls.append(contentsOf: sourceURLs)
                for entry in extracted {
                    items.append(SourceItem(
                        id: items.count, sourceIndex: index,
                        titleHe: entry.title, summaryHe: entry.summary,
                        link: entry.link.isEmpty ? links[index] : entry.link,
                        source: source.header.from.display,
                        date: source.header.date.formatted(date: .abbreviated, time: .shortened),
                        forced: entry.forced,
                        links: entry.links.map { LinkRef(id: base + $0.id, title: $0.title) },
                        entities: entry.entities,
                        significance: entry.significance
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

        // Stage 1.5: fold every repeated report of one story into a single
        // item, then split those against the cross-day story ledger.
        var merged = await mergeRunItems(items, progress: progress)
        let resolution = await resolveStories(merged, urls: urls, progress: progress)
        let classification = resolution.classification

        // Fold the late duplicates first, so the item each belongs to carries
        // their links and sources by the time it is rendered below.
        var folded: Set<Int> = []
        for (index, item) in merged.enumerated() {
            guard case .duplicate(let target) = classification[index] ?? .new,
                  merged.indices.contains(target), target != index else { continue }
            progress("Digest: merging duplicates… (\(folded.count + 1))")
            merged[target] = await fold(item, into: merged[target])
            folded.insert(index)
        }

        var newItems: [DigestItem] = []
        var updates: [Update] = []
        var echoes: [DigestItem] = []
        for (index, item) in merged.enumerated() where !folded.contains(index) {
            switch classification[index] ?? .new {
            case .new:
                newItems.append(item)
            case .update(let storyId, let deltaHe, let firstSeen, let firstSource):
                updates.append(Update(item: item, storyId: storyId, deltaHe: deltaHe,
                                      firstSeen: firstSeen, firstSource: firstSource))
            case .echo:
                echoes.append(item)
            case .duplicate:
                newItems.append(item)   // unfoldable target: report it rather than lose it
            }
        }
        let reportedCount = merged.count - folded.count

        // Stage 2: compose the new items; every item id is mechanically accounted.
        var body = ""
        if !newItems.isEmpty {
            progress("Digest: composing the digest…")
            let composed = await composeDigest(newItems, urls: urls, progress: progress)
            if !composed.isEmpty {
                body = "<h2 style=\"\(Self.headingStyle)\">חדש</h2>" + composed
            }
        }
        body += Self.renderUpdates(updates, urls: urls)
        body += Self.renderEchoes(echoes, urls: urls)

        let html = Self.assemble(
            digestBody: body,
            itemCount: reportedCount,
            mergedAway: items.count - reportedCount,
            forcedCount: items.filter(\.forced).count,
            updateCount: updates.count,
            echoCount: echoes.count,
            appendix: appendix,
            audit: audit
        )

        progress("Digest: delivering to the Inbox…")
        let to = destination.accountEmail.isEmpty ? Self.fromAddress : destination.accountEmail
        let subject = "סיכום ניוזלטרים — \(reportedCount) items"
        let raw = MIMEBuilder.buildHTML(
            from: "\"Newsletter Digest\" <\(Self.fromAddress)>",
            to: to, cc: "", subject: subject, html: html, attachments: []
        )
        let digestId = try await destination.importRawMessage(raw, toFolderId: "INBOX", markUnread: true)

        // A real Gmail label, so digests are findable on every device rather
        // than only recognizable by their From address. Best-effort: the
        // reading pane still identifies the digest without it.
        if let gmail = destination as? GmailProvider,
           let labelId = try? await destination.ensureFolder(named: DigestCategory.labelName) {
            try? await gmail.setLabel(ids: [digestId], labelId: labelId, on: true)
        }

        let sourcesRaw = sources
            .map { "\($0.account.accountId)\u{1}\($0.header.id)" }
            .joined(separator: ",")
        context.insert(DigestRecord(digestMessageId: digestId, sourcesRaw: sourcesRaw))
        commitStories(resolution)
        try? context.save()

        // Clear the sources out of the Inbox once the digest that replaces them
        // exists. Best-effort and non-destructive — everything stays searchable,
        // and "Delete source mails" is still there for an explicit purge.
        var archived: [String: [String]] = [:]
        if DigestPrefs.autoArchiveSources {
            progress("Digest: archiving the sources…")
            var byAccount: [String: [String]] = [:]
            for source in sources {
                byAccount[source.account.accountId, default: []].append(source.header.id)
            }
            for (accountId, ids) in byAccount {
                guard let provider = accounts.first(where: { $0.accountId == accountId })?.provider,
                      (try? await provider.archive(ids: ids)) != nil else { continue }
                archived[accountId] = ids
            }
        }
        return (digestId, sources.count, archived)
    }

    // MARK: - Stage 1: extraction

    /// Extracts one source message: RSS full articles get a single-story
    /// summary; newsletters go through link-marked, segment-accounted
    /// extraction. Returns the message's primary link alongside so the appendix
    /// can use it too.
    private func extractSource(
        _ header: MessageHeader, provider: MailProvider, index: Int
    ) async -> (Int, PerSource, String) {
        let body = await body(for: header, provider: provider)
        let html = body?.html ?? ""
        let link = Self.primaryLink(in: html) ?? ""

        // RSS items are one story per message by construction — no accounting
        // needed to know nothing else hides inside, and `primaryLink` already
        // resolves the article's own URL from its `<base href>`.
        if header.from.email == FeedService.fromAddress {
            var text = body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty, !html.isEmpty { text = Self.stripHTML(html) }
            guard !text.isEmpty else { return (index, .failed, link) }
            if let item = await summarizeSingleArticle(
                title: header.subject, text: String(text.prefix(Self.rssItemChars))
            ) {
                let entry = ExtractedEntry(
                    title: item.title, summary: item.summary, link: link, forced: false,
                    links: [], entities: item.entities, significance: "normal"
                )
                return (index, .extracted(items: [entry], noiseSnippets: [], truncated: false,
                                          urls: []), link)
            }
            return (index, .failed, link)
        }

        // Newsletters go through the HTML, so each story keeps its own links.
        // Plain text is the fallback only when there is no HTML part at all —
        // it carries no hrefs, which is what made the old digest unclickable.
        var text: String
        var urls: [String] = []
        if !html.isEmpty {
            (text, urls) = Self.linkify(html)
        } else {
            text = body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        guard !text.isEmpty else { return (index, .failed, link) }

        let truncated = text.count > Self.messageCeiling
        if truncated { text = String(text.prefix(Self.messageCeiling)) }
        let segments = Self.segment(text)
        guard !segments.isEmpty else { return (index, .failed, link) }

        guard let output = await extractItems(
            subject: header.subject, source: header.from.display, link: link,
            segments: segments, urlCount: urls.count
        ) else {
            return (index, .failed, link)
        }
        let noiseSnippets = output.noiseIds.sorted().compactMap { id -> String? in
            guard segments.indices.contains(id) else { return nil }
            return String(segments[id].prefix(80))
        }
        return (index, .extracted(items: output.items, noiseSnippets: noiseSnippets,
                                  truncated: truncated, urls: urls), link)
    }

    /// Segment-accounted extraction over one newsletter's segments. Nil only
    /// when every Gemini call failed (message falls back to the appendix, as
    /// before — a total outage must not turn a newsletter into a wall of
    /// verbatim text); unaccounted segments never disappear.
    private func extractItems(
        subject: String, source: String, link: String, segments: [String], urlCount: Int
    ) async -> (items: [ExtractedEntry], noiseIds: Set<Int>)? {
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
        var anySucceeded = false
        for chunk in chunks {
            if let output = await extractChunk(
                subject: subject, source: source, link: link,
                segments: chunk.map { ($0, segments[$0]) }
            ) {
                items.append(contentsOf: output.items)
                noise.formUnion(output.noise)
                anySucceeded = true
            }
        }
        guard anySucceeded else { return nil }

        // Mechanical accounting: every segment id must be in an item or noise.
        // One re-ask with only the missing segments; whatever remains is
        // force-included verbatim so it cannot be silently dropped.
        var accounted = noise
        for item in items { accounted.formUnion(item.segments) }
        var missing = Set(segments.indices).subtracting(accounted)
        if !missing.isEmpty {
            if let retry = await extractChunk(
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
            ExtractedEntry(
                title: item.title_he, summary: item.summary_he, link: item.link ?? "",
                forced: false, links: Self.validLinks(item.links, urlCount: urlCount),
                entities: item.entities ?? [],
                significance: item.significance ?? "normal"
            )
        }
        for id in missing.sorted() {
            let text = segments[id]
            result.append(ExtractedEntry(title: String(text.prefix(90)), summary: text, link: "",
                                         forced: true, links: [], entities: [],
                                         significance: "normal"))
        }
        return (result, noise)
    }

    /// One chunk's extraction, halving on failure. A failed call used to cost
    /// the *entire* newsletter (the whole message fell to the appendix); now the
    /// chunk is split and retried down to single segments, so at worst a few
    /// segments end up force-included verbatim.
    private func extractChunk(
        subject: String, source: String, link: String, segments: [(id: Int, text: String)]
    ) async -> ExtractionOutput? {
        if let output = await extractionCall(subject: subject, source: source, link: link,
                                             segments: segments) {
            return output
        }
        guard segments.count > 1 else { return nil }
        let mid = segments.count / 2
        let head = await extractChunk(subject: subject, source: source, link: link,
                                      segments: Array(segments[..<mid]))
        let tail = await extractChunk(subject: subject, source: source, link: link,
                                      segments: Array(segments[mid...]))
        guard head != nil || tail != nil else { return nil }
        return ExtractionOutput(items: (head?.items ?? []) + (tail?.items ?? []),
                                noise: (head?.noise ?? []) + (tail?.noise ?? []))
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
                        "links": ["type": "ARRAY", "items": [
                            "type": "OBJECT",
                            "properties": [
                                "id": ["type": "INTEGER"],
                                "title": ["type": "STRING"],
                            ],
                            "required": ["id", "title"],
                        ] as [String: Any]],
                        "entities": ["type": "ARRAY", "items": ["type": "STRING"]],
                        "significance": ["type": "STRING"],
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

    /// Keeps only ids the message's URL table actually has, deduplicated. This
    /// is what makes an invented, truncated, or edited URL structurally
    /// impossible: the model never sees a URL, only an integer we issued.
    private static func validLinks(_ links: [ExtractionOutput.Link]?, urlCount: Int) -> [LinkRef] {
        var seen = Set<Int>()
        return (links ?? []).compactMap { link in
            guard link.id >= 0, link.id < urlCount, seen.insert(link.id).inserted else { return nil }
            let title = link.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return LinkRef(id: link.id, title: title.isEmpty ? "קישור" : title)
        }
    }

    private static var extractionSystem: String {
        """
        You extract every distinct news story from ONE newsletter email. The input is JSON: \
        {title, source, link, segments: [{id, text}]} — the segments are consecutive fragments \
        of the email, in reading order. A story may span several segments; a segment may \
        contain several stories (then create several items that all reference that segment's id).
        The segment text contains markers of the form [L:7] — each one stands for a hyperlink \
        that was at that exact spot, and 7 is its id.
        Return {"items": [{title_he, summary_he, link, segments: [ids], links: [{id, title}], \
        entities: [...], significance}], "noise": [ids]}.
        Rules:
        - One item per distinct story. title_he: a short Hebrew headline. summary_he: 1–3 \
        sentences of natural, fluent Hebrew. link: the story's URL if one appears as bare text \
        in its segments, else "". segments: EVERY id whose text contributed to this item.
        - CRITICAL — round-up sections. Newsletters end with a rapid-fire block of one-line \
        stories under a heading like "Everything else in AI today", "Quick hits", "In other \
        news", "Also happening", or a bare bulleted list. EVERY bullet in such a block is its \
        OWN story and MUST become its own item, even though they all sit in one segment and \
        even when a bullet is a single sentence. A funding round, a product launch, a lawsuit, \
        and a research result are four stories, not one — never fold them into a combined item \
        like "AI industry updates". If a segment holds five bullets, return five items that \
        all list that segment's id.
        - Never create an item that covers more than one company's announcement. If you catch \
        yourself writing a title that is a category ("funding news", "industry updates", \
        "model releases"), you have merged stories that must stay separate — split them.
        - links: one entry for EVERY [L:n] marker that falls inside this item's text. `id` is \
        that marker's number, exactly as written — never invent an id, and never write a URL. \
        `title` is the FULL sentence the marker appeared in, in its original language, trimmed, \
        with the marker itself removed — not the two or three words of anchor text, and never \
        "Read more" or "Click here". Omit markers in noise text (unsubscribe, sponsor, nav).
        - entities: 1–5 canonical names, IN ENGLISH, of the models, products, companies, or \
        papers this story is about — for example ["GPT-5.5", "OpenAI"]. These identify the \
        story across newsletters, so use the common name, not a description.
        - significance: "major" for a launch, release, acquisition, or result that matters \
        beyond one product; "minor" for a tip, a tutorial, or an incremental note; else "normal".
        - noise: ids whose text contains NO news content at all — unsubscribe/legal footers, \
        sponsor ads, navigation, greetings, social buttons, "view in browser" chrome. \
        Advertisements sitting INSIDE a round-up block ("Advertise to 700K+ readers here", \
        "Sponsored", "*Sponsored Listing", a vendor pitch with a signup link) are noise too — \
        never attach their links to a neighbouring story.
        - EVERY input id must appear in items[].segments or in noise. When unsure whether a \
        segment is content, create an item for it — never guess noise.
        - Keep product names, company names, model names, code, CLI commands, and URLs in \
        English; do not transliterate. Write idiomatic Hebrew prose.
        - ALWAYS keep these exact words in English, never translate them: \
        \(TranslationService.skipWordsClause).
        """
    }

    /// Single-story Hebrew summary for an RSS full-article message.
    private func summarizeSingleArticle(
        title: String, text: String
    ) async -> (title: String, summary: String, entities: [String])? {
        struct Out: Decodable { let title_he: String; let summary_he: String; let entities: [String]? }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "title_he": ["type": "STRING"],
                "summary_he": ["type": "STRING"],
                "entities": ["type": "ARRAY", "items": ["type": "STRING"]],
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
                return (parsed.title_he, parsed.summary_he, parsed.entities ?? [])
            }
        }
        return nil
    }

    private static var articleSystem: String {
        """
        You summarize one news article into Hebrew. Return {"title_he": a short Hebrew \
        headline, "summary_he": 2–4 sentences of natural, fluent Hebrew, "entities": 1–5 \
        canonical names IN ENGLISH of the models, products, companies, or papers the article \
        is about}. Keep product, company, and model names, code, CLI commands, and URLs in \
        English; do not transliterate. ALWAYS keep these exact words in English, never \
        translate them: \(TranslationService.skipWordsClause).
        """
    }

    // MARK: - Stage 1.5: in-run deduplication

    /// Folds the run's items into a deduplicated list, one item at a time.
    ///
    /// This is the reference implementation's `add_or_merge_item` loop: each
    /// new item is compared against everything already accumulated, and on a hit
    /// the two are merged into one. Asking the composition prompt to "merge
    /// items reporting the same story" instead does not work — with six
    /// newsletters covering the same launch it reliably emitted the story
    /// several times. Explicit pairwise matching is the part that actually
    /// dedups, so it gets its own stage.
    ///
    /// Accounting: the loop either merges an item into an existing entry or
    /// appends a new one, so every `SourceItem` lands in exactly one
    /// `DigestItem` — a story can be duplicated by a missed match, never lost.
    private func mergeRunItems(
        _ items: [SourceItem], progress: (String) -> Void
    ) async -> [DigestItem] {
        var merged: [DigestItem] = []
        for (number, item) in items.enumerated() {
            progress("Digest: merging duplicates… (\(number + 1)/\(items.count))")
            if let index = await findMatch(item, in: merged),
               Self.mayMerge(merged[index], item) {
                var existing = merged[index]
                // Text first: the merge call sees both versions before either is
                // altered, exactly as the reference does.
                if let text = await mergeTextCall(existing, titleHe: item.titleHe,
                                                  summaryHe: item.summaryHe) {
                    existing.titleHe = text.title_he
                    existing.summaryHe = text.summary_he
                }
                var seenLinks = Set(existing.links.map(\.id))
                for link in item.links where seenLinks.insert(link.id).inserted {
                    existing.links.append(link)
                }
                var seenEntities = Set(existing.entities.map(Self.normalize))
                for entity in item.entities
                where seenEntities.insert(Self.normalize(entity)).inserted {
                    existing.entities.append(entity)
                }
                if item.significance == "major" { existing.significance = "major" }
                if !existing.sources.contains(item.source) { existing.sources.append(item.source) }
                if existing.primaryLink.isEmpty { existing.primaryLink = item.link }
                existing.itemIds.append(item.id)
                merged[index] = existing
            } else {
                merged.append(DigestItem(
                    titleHe: item.titleHe, summaryHe: item.summaryHe, links: item.links,
                    entities: item.entities, significance: item.significance,
                    sources: [item.source], primaryLink: item.link, itemIds: [item.id]
                ))
            }
        }
        return merged
    }

    /// Folds one item into the item that already covers its story — the same
    /// fold `mergeRunItems` performs, reached later, when it was the cross-day
    /// matcher that spotted the pair the in-run matcher had missed.
    private func fold(_ item: DigestItem, into target: DigestItem) async -> DigestItem {
        var target = target
        if let text = await mergeTextCall(target, titleHe: item.titleHe,
                                          summaryHe: item.summaryHe) {
            target.titleHe = text.title_he
            target.summaryHe = text.summary_he
        }
        var seenLinks = Set(target.links.map(\.id))
        for link in item.links where seenLinks.insert(link.id).inserted {
            target.links.append(link)
        }
        var seenEntities = Set(target.entities.map(Self.normalize))
        for entity in item.entities where seenEntities.insert(Self.normalize(entity)).inserted {
            target.entities.append(entity)
        }
        if item.significance == "major" { target.significance = "major" }
        for source in item.sources where !target.sources.contains(source) {
            target.sources.append(source)
        }
        if target.primaryLink.isEmpty { target.primaryLink = item.primaryLink }
        target.itemIds.append(contentsOf: item.itemIds)
        return target
    }

    /// Mechanical veto on a proposed merge: two items that name entirely
    /// different things are not the same story, whatever the matcher says.
    /// Etched raising $700M and Groq raising $350M are both "AI funding", and a
    /// matcher will cheerfully fuse them into one umbrella entry — every merge
    /// after that makes the entry broader and its link list longer. This is
    /// what stops the slide, and unlike a prompt it cannot be talked out of it.
    ///
    /// Vetoes only when BOTH sides named entities; an untagged item falls back
    /// to the matcher's judgement rather than being force-split.
    private static func mayMerge(_ existing: DigestItem, _ item: SourceItem) -> Bool {
        let a = Set(existing.entities.map(normalize)).subtracting([""])
        let b = Set(item.entities.map(normalize)).subtracting([""])
        guard !a.isEmpty, !b.isEmpty else { return true }
        return !a.isDisjoint(with: b)
    }

    /// Compares one new item against everything accumulated so far, newest
    /// first, and returns the index of the entry covering the same story.
    /// Batched, and — like the reference — the first batch that reports a match
    /// wins, so the common case (a story reported twice this morning) costs a
    /// single call.
    private func findMatch(_ item: SourceItem, in merged: [DigestItem]) async -> Int? {
        guard !merged.isEmpty else { return nil }
        // Most recent first: same-day cross-newsletter repeats are what this
        // catches most often, and they sit at the end of the list.
        let order = Array(merged.indices.reversed())
        var batch: [Int] = []
        var chars = 0
        var batches: [[Int]] = []
        for index in order {
            let size = merged[index].titleHe.count + Self.matchSummaryChars + 40
            if !batch.isEmpty && (chars + size > Self.matchBatchChars
                                  || batch.count >= Self.matchBatchItems) {
                batches.append(batch)
                batch = []
                chars = 0
            }
            batch.append(index)
            chars += size
        }
        if !batch.isEmpty { batches.append(batch) }

        for candidateIndices in batches {
            let payload: [String: Any] = [
                "new_item": [
                    "title_he": item.titleHe,
                    "summary_he": item.summaryHe,
                    "entities": item.entities,
                ],
                "existing_items": candidateIndices.map { index -> [String: Any] in
                    [
                        "index": index,
                        "title_he": merged[index].titleHe,
                        "summary_he": String(merged[index].summaryHe.prefix(Self.matchSummaryChars)),
                        "entities": merged[index].entities,
                    ]
                },
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let schema: [String: Any] = [
                "type": "OBJECT",
                "properties": ["match_index": ["type": "INTEGER"]],
                "required": ["match_index"],
            ]
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
                guard let text = try? await TranslationService.shared.geminiGenerate(
                    system: Self.matchSystem, userText: String(decoding: data, as: UTF8.self),
                    responseSchema: schema, maxOutputTokens: 512
                ), let parsed = try? JSONDecoder().decode(MatchIndexOutput.self,
                                                          from: Data(text.utf8)) else { continue }
                if parsed.match_index >= 0 && candidateIndices.contains(parsed.match_index) {
                    return parsed.match_index
                }
                break   // a clean "-1": ask the next batch, don't retry this one
            }
        }
        return nil
    }

    private static var matchSystem: String {
        """
        You compare a NEW newsletter item against a list of EXISTING digest items to detect \
        duplicates. The input is JSON: {new_item: {title_he, summary_he, entities}, \
        existing_items: [{index, title_he, summary_he, entities}]}. The text is Hebrew; the \
        entities are the products, models, companies, or papers each item is about.
        Two items are duplicates when they report the SAME underlying news story, \
        announcement, release, or result — even if phrased differently, at a different length, \
        or by a different newsletter. Ignore superficial wording differences.
        Two items about the same company or the same product are NOT duplicates unless they \
        are about the same event: a model's launch, its benchmark results, and its pricing \
        change are three different stories.
        Two different companies are never the same story. Etched raising $700M and Groq \
        raising $350M are both funding news, and both are AI news, and they are still two \
        separate stories — "the same category of news" is NOT a duplicate.
        If an existing item reads like an umbrella over several stories at once ("AI industry \
        updates", "funding news", "model releases"), answer -1: adding to it makes it worse.
        Respond with the `index` of the existing item covering the same story, or -1 when none \
        does. When in doubt, answer -1 — a repeated story is a much smaller problem than two \
        different stories fused into one paragraph.
        Respond as JSON: {"match_index": <int>}.
        """
    }

    /// Combines two reports of one story into a single non-redundant version.
    private func mergeTextCall(
        _ a: DigestItem, titleHe: String, summaryHe: String
    ) async -> MergeTextOutput? {
        let payload: [String: Any] = [
            "item_a": ["title_he": a.titleHe, "summary_he": a.summaryHe],
            "item_b": ["title_he": titleHe, "summary_he": summaryHe],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "title_he": ["type": "STRING"],
                "summary_he": ["type": "STRING"],
            ],
            "required": ["title_he", "summary_he"],
        ]
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let text = try? await TranslationService.shared.geminiGenerate(
                system: Self.mergeSystem, userText: String(decoding: data, as: UTF8.self),
                responseSchema: schema, maxOutputTokens: 2048
            ), let parsed = try? JSONDecoder().decode(MergeTextOutput.self, from: Data(text.utf8)),
               !parsed.title_he.isEmpty, !parsed.summary_he.isEmpty {
                return parsed
            }
        }
        return nil
    }

    private static var mergeSystem: String {
        """
        You merge two versions of the same news item — `item_a` and `item_b` — describing the \
        same underlying story from two different newsletters, into one combined, \
        non-redundant version in Hebrew.
        Combine the unique facts and details from both without repeating the same point twice, \
        keep it concise (1–4 sentences), resolve any phrasing conflicts smoothly, and write \
        natural, fluent Hebrew. Do not invent anything neither version states.
        title_he must still name THIS specific story — the product, company, or result it is \
        about. Never widen it into a category heading such as "עדכוני AI" or "גיוסי הון \
        בתעשייה"; if the two versions seem too different to share one specific title, keep \
        item_a's title and summary unchanged.
        Keep product, company, and model names, code, CLI commands, and URLs in English. \
        ALWAYS keep these exact words in English, never translate them: \
        \(TranslationService.skipWordsClause).
        Respond as JSON: {"title_he": ..., "summary_he": ...}.
        """
    }

    // MARK: - Stage 1.5: story resolution

    /// Splits the run's items against the cross-day `StoryRecord` ledger, and
    /// updates the ledger as it goes. Items are resolved one source message at a
    /// time so the index stays live: the fourth newsletter to report a launch
    /// sees the record the first one created.
    ///
    /// Accounting: any item the model fails to answer for defaults to `.new`. A
    /// duplicated story is a far cheaper failure than a lost one, which is the
    /// same stance the extraction stage takes.
    private func resolveStories(
        _ items: [DigestItem], urls: [String], progress: (String) -> Void
    ) async -> Resolution {
        var resolution = Resolution()
        guard !items.isEmpty else { return resolution }

        // Read the ledger into plain values, dropping what aged out.
        let cutoff = Date().addingTimeInterval(-Self.storyRetention)
        for record in (try? context.fetch(FetchDescriptor<StoryRecord>())) ?? [] {
            if record.lastSeen < cutoff {
                resolution.expired.append(record)
                continue
            }
            resolution.stories[record.id] = PendingStory(
                record: record, id: record.id, titleHe: record.titleHe, gistHe: record.gistHe,
                entities: record.entities, firstSeen: record.firstSeen, lastSeen: record.lastSeen,
                mentionCount: record.mentionCount, sources: record.sources, touched: false
            )
        }
        // Stories this very run created, and the item that created each. A hit
        // on one means the in-run matcher and the ledger matcher disagreed: the
        // pair is the same story, so this item folds into that one.
        var createdThisRun: [String: Int] = [:]

        // Items arrive already deduplicated, so each is resolved on its own,
        // against every live story — no entity shortlist and no candidate count
        // limit, since restricting the candidate list is what let repeats
        // through in the first place.
        var calls = 0
        for (index, item) in items.enumerated() {
            let sourceURL = Self.primaryURL(for: item, urls: urls)
            let candidates = Self.candidates(from: resolution.stories)
            var hit: (storyId: String, deltaHe: String, isNewInfo: Bool)?
            if !candidates.isEmpty {
                calls += 1
                progress("Digest: matching against earlier stories… (\(calls)/\(items.count))")
                if let output = await storyMatchCall(item: item, candidates: candidates),
                   !output.story_id.isEmpty, resolution.stories[output.story_id] != nil {
                    hit = (output.story_id, output.delta_he ?? "", output.is_new_info ?? true)
                }
            }

            if let hit, var story = resolution.stories[hit.storyId] {
                let delta = hit.deltaHe.trimmingCharacters(in: .whitespacesAndNewlines)
                story.lastSeen = Date()
                story.mentionCount += 1
                story.touched = true
                for vendor in item.sources
                where !story.sources.contains(where: { $0.vendor == vendor && $0.url == sourceURL }) {
                    story.sources.append((vendor, sourceURL))
                }
                if !delta.isEmpty {
                    let combined = story.gistHe.isEmpty ? delta : story.gistHe + " " + delta
                    story.gistHe = combined.count <= Self.maxGistChars
                        ? combined : String(combined.suffix(Self.maxGistChars))
                }
                resolution.stories[story.id] = story
                if let target = createdThisRun[story.id] {
                    resolution.classification[index] = .duplicate(ofIndex: target)
                } else if hit.isNewInfo && !delta.isEmpty {
                    resolution.classification[index] = .update(
                        storyId: story.id, deltaHe: delta, firstSeen: story.firstSeen,
                        firstSource: story.sources.first?.vendor ?? item.sources.first ?? ""
                    )
                } else {
                    resolution.classification[index] = .echo(storyId: story.id)
                }
            } else {
                resolution.classification[index] = .new
                let entities = item.entities.map(Self.normalize).filter { !$0.isEmpty }
                let now = Date()
                let story = PendingStory(
                    record: nil, id: UUID().uuidString, titleHe: item.titleHe,
                    gistHe: String(item.summaryHe.prefix(Self.maxGistChars)),
                    entities: entities, firstSeen: now, lastSeen: now, mentionCount: 1,
                    sources: item.sources.map { ($0, sourceURL) }, touched: true
                )
                resolution.stories[story.id] = story
                createdThisRun[story.id] = index
            }
        }
        return resolution
    }

    /// The match candidates for one item: every live story, newest first, with
    /// its full gist — cut off only where the list would make the prompt
    /// oversized, since a call that fails leaves the item `.new`, which is the
    /// repeat this stage exists to prevent. Stories this run created stay in the
    /// list: they are how a same-day repeat the in-run matcher missed still gets
    /// folded instead of printed twice.
    private static func candidates(from stories: [String: PendingStory]) -> [PendingStory] {
        var kept: [PendingStory] = []
        var chars = 0
        for story in stories.values.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            chars += story.titleHe.count + story.gistHe.count + 80
            if chars > maxCandidateChars { break }
            kept.append(story)
        }
        return kept
    }

    /// Writes the resolved ledger. Called only after the digest has been
    /// delivered, so a failed delivery leaves the ledger exactly as it was and
    /// a retry produces the same digest rather than an empty one.
    private func commitStories(_ resolution: Resolution) {
        for record in resolution.expired { context.delete(record) }
        for story in resolution.stories.values where story.touched {
            let sourcesRaw = story.sources
                .map { "\($0.vendor)\u{1}\($0.url)" }
                .joined(separator: "\u{2}")
            let entitiesRaw = story.entities.isEmpty
                ? "" : ",\(story.entities.joined(separator: ",")),"
            if let record = story.record {
                record.titleHe = story.titleHe
                record.gistHe = story.gistHe
                record.entitiesRaw = entitiesRaw
                record.lastSeen = story.lastSeen
                record.mentionCount = story.mentionCount
                record.sourcesRaw = sourcesRaw
            } else {
                context.insert(StoryRecord(
                    id: story.id, titleHe: story.titleHe, gistHe: story.gistHe,
                    entitiesRaw: entitiesRaw, firstSeen: story.firstSeen,
                    lastSeen: story.lastSeen, mentionCount: story.mentionCount,
                    sourcesRaw: sourcesRaw
                ))
            }
        }
    }

    /// One story-matching call (with a retry) for a single merged item; nil
    /// when both attempts fail, in which case the item stays `.new`.
    private func storyMatchCall(
        item: DigestItem, candidates: [PendingStory]
    ) async -> MatchOutput.Match? {
        let now = Date()
        let payload: [String: Any] = [
            "item": [
                "title_he": item.titleHe,
                "summary_he": item.summaryHe,
                "entities": item.entities,
            ],
            "candidates": candidates.map { story -> [String: Any] in
                [
                    "story_id": story.id,
                    "title_he": story.titleHe,
                    "gist_he": story.gistHe,
                    "days_ago": Self.days(from: story.firstSeen, to: now),
                    "sources": story.sources.map(\.vendor).joined(separator: ", "),
                ]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let input = String(decoding: data, as: UTF8.self)
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "story_id": ["type": "STRING"],
                "delta_he": ["type": "STRING"],
                "is_new_info": ["type": "BOOLEAN"],
            ],
            "required": ["story_id"],
        ]
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let text = try? await TranslationService.shared.geminiGenerate(
                system: Self.storyMatchSystem, userText: input, responseSchema: schema,
                maxOutputTokens: 2048
            ), let parsed = try? JSONDecoder().decode(MatchOutput.Match.self,
                                                      from: Data(text.utf8)) {
                return parsed
            }
        }
        return nil
    }

    private static var storyMatchSystem: String {
        """
        You decide whether a new newsletter item is the SAME underlying story as one already \
        covered in this reader's digest — on an earlier day, or earlier in the digest being \
        built right now. The input is JSON: {item: \
        {title_he, summary_he, entities}, candidates: [{story_id, title_he, gist_he, days_ago, \
        sources}]}. `gist_he` is everything already reported about that story.
        Return {"story_id", "delta_he", "is_new_info"}.
        Rules:
        - story_id: the id of the candidate covering the SAME underlying news story, \
        announcement, or result — even when phrased differently or by a different newsletter. \
        Use "" when none of them do. Two items about the same company or product are NOT the \
        same story unless they are about the same event. When in doubt, answer "".
        - delta_he: when matched, ONLY what this item adds beyond gist_he, in natural Hebrew — \
        new benchmarks, pricing, availability dates, a correction, a reaction. Do NOT restate \
        anything gist_he already says. Leave it "" when the item adds nothing.
        - is_new_info: false when the item is a pure repeat of gist_he, true when delta_he \
        carries real new material.
        - Keep product, company, and model names, code, CLI commands, and URLs in English. \
        ALWAYS keep these exact words in English, never translate them: \
        \(TranslationService.skipWordsClause).
        """
    }

    /// Entity key: lowercase, ASCII letters and digits only, so "GPT-5.5",
    /// "GPT 5.5" and "gpt5.5" all collapse to "gpt55". This is what makes the
    /// mechanical shortlist actually hit.
    static func normalize(_ name: String) -> String {
        String(name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// The item's best single URL for the ledger: its first kept link, else the
    /// message-level link the extractor found.
    private static func primaryURL(for item: DigestItem, urls: [String]) -> String {
        if let first = item.links.first, urls.indices.contains(first.id) { return urls[first.id] }
        return item.primaryLink
    }

    private static func days(from start: Date, to end: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
    }

    // MARK: - Stage 2: topic grouping

    /// Turns the deduplicated items into rendered entries. The items already
    /// carry their final Hebrew text, so the model's only job here is to sort
    /// them under topic headings — it never rewrites, merges, or drops
    /// anything, which is what keeps this stage from undoing stage 1.5.
    ///
    /// Accounting: every item id must come back in some group; whatever doesn't
    /// is appended under a catch-all heading rather than lost.
    private func composeDigest(
        _ items: [DigestItem], urls: [String], progress: (String) -> Void
    ) async -> String {
        guard !items.isEmpty else { return "" }
        progress("Digest: grouping by topic…")

        var headingByItem: [Int: String] = [:]
        var order: [String] = []
        if let output = await groupCall(items) {
            for group in output.groups {
                let heading = group.heading.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !heading.isEmpty else { continue }
                if !order.contains(heading) { order.append(heading) }
                for id in group.item_ids
                where items.indices.contains(id) && headingByItem[id] == nil {
                    headingByItem[id] = heading
                }
            }
        }
        let ungrouped = items.indices.filter { headingByItem[$0] == nil }
        if !ungrouped.isEmpty {
            let heading = order.isEmpty ? "" : "עוד"
            for id in ungrouped { headingByItem[id] = heading }
            if !heading.isEmpty { order.append(heading) }
        }

        var entries: [Entry] = []
        for heading in order.isEmpty ? [""] : order {
            for id in items.indices where headingByItem[id] == heading {
                entries.append(Self.entry(items[id], heading: heading, urls: urls))
            }
        }
        return Self.renderEntries(entries)
    }

    /// Builds one renderable entry from a deduplicated item.
    private static func entry(_ item: DigestItem, heading: String, urls: [String]) -> Entry {
        var links = resolve(item.links.map(\.id), urls: urls,
                            titles: Dictionary(item.links.map { ($0.id, $0.title) },
                                               uniquingKeysWith: { first, _ in first }))
        if links.isEmpty && !item.primaryLink.isEmpty {
            links = [(item.primaryLink, item.sources.first ?? item.primaryLink)]
        }
        return Entry(heading: heading, titleHe: item.titleHe, summaryHe: item.summaryHe,
                     links: links)
    }

    /// Resolves link ids into real URLs. An id we never issued yields nothing —
    /// which is what keeps an invented link out of the digest.
    private static func resolve(
        _ ids: [Int], urls: [String], titles: [Int: String]
    ) -> [(url: String, title: String)] {
        var seen = Set<Int>()
        return ids.compactMap { id in
            guard urls.indices.contains(id), seen.insert(id).inserted else { return nil }
            return (urls[id], titles[id] ?? urls[id])
        }
    }

    /// One grouping call; nil when both attempts fail (everything then lands
    /// under a single unheaded run, which still reads fine).
    private func groupCall(_ items: [DigestItem]) async -> GroupOutput? {
        let payload = items.enumerated().map { index, item -> [String: Any] in
            [
                "id": index,
                "title_he": item.titleHe,
                "summary_he": String(item.summaryHe.prefix(Self.matchSummaryChars)),
                "significance": item.significance,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "groups": ["type": "ARRAY", "items": [
                    "type": "OBJECT",
                    "properties": [
                        "heading": ["type": "STRING"],
                        "item_ids": ["type": "ARRAY", "items": ["type": "INTEGER"]],
                    ],
                    "required": ["heading", "item_ids"],
                ] as [String: Any]],
            ],
            "required": ["groups"],
        ]
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            if let text = try? await TranslationService.shared.geminiGenerate(
                system: Self.groupSystem, userText: String(decoding: data, as: UTF8.self),
                responseSchema: schema, maxOutputTokens: 8192
            ), let parsed = try? JSONDecoder().decode(GroupOutput.self, from: Data(text.utf8)),
               !parsed.groups.isEmpty {
                return parsed
            }
        }
        return nil
    }

    private static var groupSystem: String {
        """
        You sort already-written digest items under topic headings. The input is a JSON array \
        of {id, title_he, summary_he, significance}.
        Return {"groups": [{heading, item_ids: [...]}]}.
        Rules:
        - heading: a short Hebrew topic heading, 2–5 words. Aim for a handful of meaningful \
        groups, not one per item and not one for everything.
        - Put the groups containing "major" items first, and the most significant item first \
        within each group.
        - EVERY input id must appear in exactly one group. Never repeat an id across groups.
        - Do NOT rewrite, summarize, merge, split, or drop any item — you are only assigning \
        headings. The items' own text is already final.
        - Keep product, company, and model names in English in the headings.
        """
    }

    // MARK: - Rendering

    /// Shared block spacing. Inline styles rather than a stylesheet: the digest
    /// is a mail message, and its HTML has to survive being rendered wherever
    /// the message is read.
    private static let entryStyle = "margin:0 0 1.4em 0"
    fileprivate static let headingStyle = "margin:1.6em 0 0.7em 0"
    private static let titleStyle = "margin:0 0 0.3em 0"
    private static let listStyle = "margin:0.5em 0 0 0; padding-inline-start:1.2em"
    /// Link titles are English sentences, so their list runs LTR and flushes
    /// left inside the RTL page — the bullets sit beside the text instead of
    /// stranded across the column.
    private static let linkListStyle =
        "margin:0.5em 0 0 0; padding-inline-start:1.2em; direction:ltr; text-align:left"

    /// Builds every entry's markup. The model returns plain text only, so this
    /// is the single place the digest's structure is decided — which is what
    /// guarantees entries, summaries and links stay visually separated.
    private static func renderEntries(_ entries: [Entry]) -> String {
        var html = ""
        var lastHeading: String?
        for entry in entries {
            if !entry.heading.isEmpty && entry.heading != lastHeading {
                html += "\n<h3 style=\"\(headingStyle)\">\(TranslationService.htmlEscape(entry.heading))</h3>"
                lastHeading = entry.heading
            }
            html += "\n<div style=\"\(entryStyle)\">"
            html += "<div style=\"\(titleStyle)\"><b>\(TranslationService.htmlEscape(entry.titleHe))</b></div>"
            html += "<div>\(TranslationService.htmlEscape(entry.summaryHe))</div>"
            html += renderLinks(entry.links)
            html += "</div>"
        }
        return html
    }

    /// An entry's links, one per line. Every link is shown: a hidden "+16" is
    /// exactly the tail a reader wants, and an entry with that many links is a
    /// symptom to fix upstream (see `mergeRunItems`), not to hide here.
    private static func renderLinks(_ links: [(url: String, title: String)]) -> String {
        guard !links.isEmpty else { return "" }
        var html = "<ul dir=\"ltr\" style=\"\(linkListStyle)\">"
        for link in links {
            let title = TranslationService.htmlEscape(link.title)
            html += "<li style=\"margin-bottom:0.25em\"><a href=\"\(escapeAttribute(link.url))\">\(title)</a></li>"
        }
        return html + "</ul>"
    }

    private static func escapeAttribute(_ value: String) -> String {
        TranslationService.htmlEscape(value).replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// An item's own links, resolved for the mechanical sections.
    private static func links(of items: [DigestItem], urls: [String]) -> [(url: String, title: String)] {
        var titles: [Int: String] = [:]
        var ids: [Int] = []
        for item in items {
            for link in item.links where titles[link.id] == nil {
                titles[link.id] = link.title
                ids.append(link.id)
            }
        }
        return resolve(ids, urls: urls, titles: titles)
    }

    /// The updates section: stories already covered on an earlier day, rendered
    /// mechanically — the deltas are already Hebrew, so this costs no call.
    private static func renderUpdates(_ updates: [Update], urls: [String]) -> String {
        guard !updates.isEmpty else { return "" }
        var order: [String] = []
        var byStory: [String: [Update]] = [:]
        for update in updates {
            if byStory[update.storyId] == nil { order.append(update.storyId) }
            byStory[update.storyId, default: []].append(update)
        }
        let now = Date()
        var html = "\n<h2 style=\"\(headingStyle)\">עדכונים לסיפורים קודמים</h2>"
        for storyId in order {
            guard let entries = byStory[storyId], let first = entries.first else { continue }
            let elapsed = days(from: first.firstSeen, to: now)
            let when = elapsed <= 0 ? "היום" : (elapsed == 1 ? "אתמול" : "לפני \(elapsed) ימים")
            let title = TranslationService.htmlEscape(first.item.titleHe)
            let source = TranslationService.htmlEscape(first.firstSource)
            html += "\n<div style=\"\(entryStyle)\">"
            html += "<div style=\"\(titleStyle)\"><b>\(title)</b> "
            html += "<span style=\"color:#666; font-weight:normal\">— דווח לראשונה \(when) ע״י \(source)</span></div>"
            html += "<div>"
            html += entries.map { TranslationService.htmlEscape($0.deltaHe) }.joined(separator: " ")
            html += "</div>"
            html += renderLinks(links(of: entries.map(\.item), urls: urls))
            html += "</div>"
        }
        return html
    }

    /// The collapsed "already discussed" disclosure: items that repeat a story
    /// without adding anything. Nothing is discarded, nothing bloats the top.
    private static func renderEchoes(_ echoes: [DigestItem], urls: [String]) -> String {
        guard !echoes.isEmpty else { return "" }
        var html = "\n<hr><details><summary style=\"color:#666\">נדון כבר (\(echoes.count))</summary>"
        html += "<ul style=\"color:#888; font-size:0.9em; \(listStyle)\">"
        for item in echoes {
            let resolved = links(of: [item], urls: urls)
            let tail = resolved.first.map {
                "<a href=\"\(escapeAttribute($0.url))\">\(TranslationService.htmlEscape($0.title))</a>"
            } ?? TranslationService.htmlEscape(item.sources.joined(separator: ", "))
            html += "<li style=\"margin-bottom:0.3em\">\(TranslationService.htmlEscape(item.titleHe)) — \(tail)</li>"
        }
        return html + "</ul></details>"
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
        digestBody: String, itemCount: Int, mergedAway: Int, forcedCount: Int,
        updateCount: Int, echoCount: Int,
        appendix: [(header: MessageHeader, link: String)],
        audit: [(source: String, snippets: [String], truncated: Bool)]
    ) -> String {
        var countLine = "סיכום של \(itemCount) פריטים"
        var notes: [String] = []
        if mergedAway > 0 { notes.append("\(mergedAway) כפילויות אוחדו") }
        if updateCount > 0 { notes.append("\(updateCount) עדכונים") }
        if echoCount > 0 { notes.append("\(echoCount) נדונו כבר") }
        if forcedCount > 0 { notes.append("\(forcedCount) שלא סוכמו במלואם") }
        if !notes.isEmpty { countLine += " (\(notes.joined(separator: ", ")))" }
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
                    : "<li><b>\(title)</b> — <a href=\"\(escapeAttribute(entry.link))\">\(source)</a></li>"
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

    /// Rewrites the message's anchors into ` [L:n] ` markers placed where each
    /// link ended, then strips the tags as usual. Returns the marked-up text and
    /// the id→URL table.
    ///
    /// Ids rather than the URLs themselves (which is what the Python reference
    /// inlines) for two reasons: a tracking URL is ~200 characters of prompt
    /// each, and — more importantly — a model that never sees a URL cannot
    /// invent, truncate, or "tidy" one. Anything it hands back that isn't an id
    /// we issued is dropped.
    static func linkify(_ html: String) -> (text: String, urls: [String]) {
        guard let re = try? NSRegularExpression(
            pattern: "<a\\b[^>]*?href\\s*=\\s*[\"']([^\"']+)[\"'][^>]*>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return (stripHTML(html), []) }

        let ns = html as NSString
        var urls: [String] = []
        var idByURL: [String: Int] = [:]
        var out = ""
        var cursor = 0
        for match in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            // A nested anchor's opening tag can fall inside the span the
            // previous one already consumed; skip it rather than reorder text.
            guard match.range.location >= cursor else { continue }
            let href = ns.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
            guard href.lowercased().hasPrefix("http") else { continue }

            let id: Int
            if let existing = idByURL[href] {
                id = existing
            } else {
                id = urls.count
                urls.append(href)
                idByURL[href] = id
            }
            // Emit everything through this anchor's closing tag, then the
            // marker — so the marker sits right after the text it belongs to.
            let afterOpen = match.range.location + match.range.length
            let close = ns.range(of: "</a>", options: [.caseInsensitive],
                                 range: NSRange(location: afterOpen, length: ns.length - afterOpen))
            let end = close.location == NSNotFound ? afterOpen : close.location + close.length
            out += ns.substring(with: NSRange(location: cursor, length: end - cursor))
            out += " [L:\(id)] "
            cursor = end
        }
        out += ns.substring(from: cursor)
        return (stripHTML(out), urls)
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
    /// `[L:n]` markers carry no angle brackets, so they survive this untouched.
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

// MARK: - Preferences

/// UserDefaults-backed digest settings, edited in Settings → Digest.
enum DigestPrefs {
    static let autoArchiveKey = "digestAutoArchiveSources"
    static let scheduleEnabledKey = "digestScheduleEnabled"
    static let scheduleHourKey = "digestScheduleHour"
    /// "yyyy-MM-dd" of the last day the scheduler generated a digest.
    static let lastRunDayKey = "digestLastRunDay"

    /// Default on: the Inbox is clean once the digest that replaces the sources
    /// exists, and archiving destroys nothing.
    static var autoArchiveSources: Bool {
        UserDefaults.standard.object(forKey: autoArchiveKey) as? Bool ?? true
    }

    static var scheduleEnabled: Bool {
        UserDefaults.standard.bool(forKey: scheduleEnabledKey)
    }

    static var scheduleHour: Int {
        let hour = UserDefaults.standard.object(forKey: scheduleHourKey) as? Int ?? 8
        return min(23, max(0, hour))
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

// MARK: - StoryRecord fields

extension StoryRecord {
    /// Normalized entity names, from the delimiter-wrapped ",gpt55,openai," form.
    var entities: [String] {
        entitiesRaw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    /// Decodes `sourcesRaw`: "vendor\u{1}url" pairs joined by \u{2}. (A vendor's
    /// display name can contain a comma, so the pair separator can't be one.)
    var sources: [(vendor: String, url: String)] {
        sourcesRaw.split(separator: "\u{2}").compactMap { pair in
            let parts = pair.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]))
        }
    }
}
