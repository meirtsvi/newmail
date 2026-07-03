import Foundation
import SwiftData

/// Polls the subscribed RSS/Atom feeds and materializes each new item as a real
/// received Gmail message in the Inbox (via `MIMEBuilder` + `importRawMessage`, the
/// same machinery behind the Outlook→Gmail move and edit-in-place). Runs only while
/// the app is open; a pass runs immediately on `start()` and whenever a feed is added.
@MainActor
final class FeedService {
    /// How many recent items to import the first time a feed is seen (older items are
    /// recorded as seen without importing, so adding a feed doesn't flood the Inbox).
    private static let firstAddBacklog = 10
    /// Poll cadence.
    private static let interval: TimeInterval = 300
    /// Sender address of every materialized feed message; also how other code
    /// (e.g. the popup pre-translation) recognizes a message as a feed item.
    static let fromAddress = "feeds@rss.local"
    /// Low-specificity default so inline SVG icons (sized only by the site's CSS
    /// classes) don't balloon to full width if that stylesheet fails to load; the
    /// site's class-based rules override this when the CSS is present.
    private static let iconFallbackCSS = "<style>svg{width:1.25em;height:1.25em}</style>"

    private let provider: MailProvider
    private let accountId: String
    private let context: ModelContext
    private let store: MailStore
    private var timer: Timer?
    private var inFlight = false

    /// Imported message ids waiting for their Hebrew translation + summary to be
    /// pre-computed, drained one at a time by a single background worker.
    private var translationQueue: [String] = []
    private var translationWorkerRunning = false

    /// Notifies the UI (e.g. to refresh the current folder) after new items land.
    var onNewItems: (() -> Void)?

    init(provider: MailProvider, accountId: String, context: ModelContext? = nil) {
        let ctx = context ?? Persistence.container.mainContext
        self.provider = provider
        self.accountId = accountId
        self.context = ctx
        self.store = MailStore(context: ctx)
    }

    // MARK: Timer

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshAll() }
        }
        self.timer = timer
        Task {
            await refreshAll()
            // Catch up on feed items imported before pre-translation existed (or
            // whose pass was interrupted), so their toggles are instant too.
            enqueueBacklogTranslations()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: Polling

    func refreshAll() async {
        // Inserting a real received message needs Gmail write scope; skip the pass
        // rather than hammering the API with 403s if it isn't granted yet.
        guard (try? await GoogleAuth.shared.hasWriteScope) == true else { return }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let subscriptions = (try? context.fetch(FetchDescriptor<FeedSubscription>())) ?? []
        guard !subscriptions.isEmpty else { return }
        var seenKeys = Set((try? context.fetch(FetchDescriptor<SeenFeedItem>()))?.map(\.key) ?? [])

        var importedAny = false
        for sub in subscriptions {
            guard let url = URL(string: sub.url) else { continue }
            guard let data = try? await URLSession.shared.data(from: url).0,
                  let feed = FeedParser.parse(data) else { continue }

            if !feed.title.isEmpty { sub.title = feed.title }
            let displayTitle = sub.title.isEmpty ? (url.host ?? sub.url) : sub.title

            let prefix = sub.url + "\u{1}"
            let firstPass = !seenKeys.contains { $0.hasPrefix(prefix) }

            // Pair each item with its dedup key, dropping ones already handled.
            let fresh = feed.items
                .map { (item: $0, key: prefix + $0.guid) }
                .filter { !seenKeys.contains($0.key) }
            guard !fresh.isEmpty else { continue }

            let toImport: [(item: FeedParser.FeedItem, key: String)]
            let markSeenOnly: [(item: FeedParser.FeedItem, key: String)]
            if firstPass {
                let ordered = fresh.sorted { $0.item.date > $1.item.date }
                toImport = Array(ordered.prefix(Self.firstAddBacklog)).reversed() // oldest-first
                markSeenOnly = Array(ordered.dropFirst(Self.firstAddBacklog))
            } else {
                toImport = fresh.sorted { $0.item.date < $1.item.date }            // oldest-first
                markSeenOnly = []
            }

            for entry in toImport {
                do {
                    let messageId = try await importItem(entry.item, feedTitle: displayTitle)
                    recordSeen(entry.key, into: &seenKeys)
                    importedAny = true
                    translationQueue.append(messageId)
                    // Start translating right away rather than after the whole
                    // pass, so the first item is likely ready by the time its
                    // popup appears (a no-op if the worker is already running).
                    startTranslationWorker()
                } catch {
                    // Leave it unrecorded so the next pass retries it.
                    continue
                }
            }
            for entry in markSeenOnly {
                recordSeen(entry.key, into: &seenKeys)
            }
        }

        try? context.save()
        if importedAny { onNewItems?() }
        startTranslationWorker()
    }

    // MARK: Pre-translation

    /// Pre-computes and caches the Hebrew translation + summary for imported feed
    /// items (including full-article bodies), one at a time in the background, so
    /// the viewer's toggles show instantly. Also warms the body cache on the way.
    private func startTranslationWorker() {
        guard !translationWorkerRunning, !translationQueue.isEmpty,
              GeminiConfig.apiKey != nil else { return }
        translationWorkerRunning = true
        Task { [weak self] in
            while let id = self?.dequeueTranslation() {
                await self?.pretranslate(id)
            }
            self?.translationWorkerRunning = false
        }
    }

    private func dequeueTranslation() -> String? {
        translationQueue.isEmpty ? nil : translationQueue.removeFirst()
    }

    private func pretranslate(_ id: String) async {
        // The body: from the cache, else fetched (with one retry — a just-imported
        // message can take a moment to become fetchable) and cached for the viewer.
        var body = store.cachedBody(id: id)
        if body == nil {
            for attempt in 0..<2 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(3)) }
                if let fetched = try? await provider.fetchBody(id: id) {
                    store.saveBody(fetched)
                    body = fetched
                    break
                }
            }
        }
        guard let body else { return }
        let existing = store.cachedTranslation(id: id)
        if existing.translated == nil,
           let translated = try? await TranslationService.shared.translateHTMLToHebrew(body.html) {
            store.saveTranslation(id: id, translated: translated)
        }
        if existing.summary == nil,
           let summary = try? await TranslationService.shared.summarizeInHebrew(
               plainText: body.plainText, html: body.html) {
            store.saveTranslation(id: id, summary: summary)
        }
    }

    /// Recent feed messages already in the cache that still lack a translation or
    /// summary — imported before pre-translation existed, or interrupted mid-pass.
    private func enqueueBacklogTranslations() {
        guard GeminiConfig.apiKey != nil else { return }
        let sender = Self.fromAddress
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.fromEmail == sender },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 30
        let rows = (try? context.fetch(descriptor)) ?? []
        let missing = rows.map(\.id).filter { id in
            guard !translationQueue.contains(id) else { return false }
            let cached = store.cachedTranslation(id: id)
            return cached.translated == nil || cached.summary == nil
        }
        guard !missing.isEmpty else { return }
        translationQueue.append(contentsOf: missing)
        startTranslationWorker()
    }

    private func recordSeen(_ key: String, into seenKeys: inout Set<String>) {
        guard !seenKeys.contains(key) else { return }
        context.insert(SeenFeedItem(key: key))
        seenKeys.insert(key)
    }

    /// Imports one feed item as a received Gmail message; returns the new message id.
    @discardableResult
    private func importItem(_ item: FeedParser.FeedItem, feedTitle: String) async throws -> String {
        let from = "\(encodedDisplayName(feedTitle)) <\(Self.fromAddress)>"
        let to = provider.accountEmail.isEmpty ? Self.fromAddress : provider.accountEmail

        // If the feed only carries a summary with a "Read full article" link, fetch
        // that page and use the full article as the body instead of the snippet.
        var html = item.html
        var replacedWithArticle = false
        if let articleURL = fullArticleURL(in: item.html),
           let data = try? await URLSession.shared.data(from: articleURL).0,
           !data.isEmpty {
            let page = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            if !page.isEmpty {
                // Prefer the page's main content so the site header, nav, ads (an
                // empty leaderboard slot renders as a tall blank gap with JS off),
                // and footer don't get embedded; fall back to the whole page. Carry
                // the page's stylesheets along so its content — e.g. inline SVG icons
                // sized only via CSS classes — renders at the right size, not blown up.
                if let content = extractMainContent(from: page) {
                    html = withBase(Self.iconFallbackCSS + headStyleTags(in: page) + "\n" + content, url: articleURL)
                } else {
                    html = withBase(page, url: articleURL)
                }
                replacedWithArticle = true
            }
        }
        if !replacedWithArticle, !item.link.isEmpty {
            html += "\n<hr>\n<p><a href=\"\(item.link)\">View original</a></p>"
        }

        let raw = MIMEBuilder.buildHTML(
            from: from,
            to: to,
            cc: "",
            subject: item.title.isEmpty ? "(untitled)" : item.title,
            html: html,
            attachments: [],
            date: item.date
        )
        return try await provider.importRawMessage(raw, toFolderId: "INBOX", markUnread: true)
    }

    /// An address display-name for the feed title. Non-ASCII (e.g. Hebrew) titles
    /// must be RFC 2047 encoded-words, or the raw UTF-8 bytes in the header render as
    /// mojibake; ASCII titles are just quoted.
    private func encodedDisplayName(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.allSatisfy(\.isASCII) {
            return "\"\(cleaned.replacingOccurrences(of: "\"", with: ""))\""
        }
        return "=?UTF-8?B?\(Data(cleaned.utf8).base64EncodedString())?="
    }

    /// The href of a "Read full article" style link in the item HTML, if present, so
    /// summary-only feeds can be expanded to the full article.
    private func fullArticleURL(in html: String) -> URL? {
        guard let anchorRe = try? NSRegularExpression(
            pattern: "<a\\b[^>]*>.*?</a>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = html as NSString
        for match in anchorRe.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let anchor = ns.substring(with: match.range)
            guard anchor.lowercased().contains("read full article") else { continue }
            guard let hrefRe = try? NSRegularExpression(
                pattern: "href\\s*=\\s*[\"']([^\"']+)[\"']",
                options: [.caseInsensitive]
            ) else { continue }
            let anchorNS = anchor as NSString
            if let hrefMatch = hrefRe.firstMatch(in: anchor, range: NSRange(location: 0, length: anchorNS.length)),
               hrefMatch.numberOfRanges > 1,
               let url = URL(string: anchorNS.substring(with: hrefMatch.range(at: 1))) {
                return url
            }
        }
        return nil
    }

    /// The inner HTML of the page's primary content element (`<article>`, else
    /// `<main>`), used to strip the surrounding site chrome from a fetched article.
    /// Returns nil when neither is present or the match is implausibly small.
    private func extractMainContent(from page: String) -> String? {
        for tag in ["article", "main"] {
            if let inner = firstElementInner(tag, in: page), inner.count > 400 {
                return inner
            }
        }
        return nil
    }

    /// The page's `<link rel="stylesheet">` and `<style>` tags, so extracted content
    /// keeps the site's styling (fonts, and CSS-class-sized inline SVG icons).
    private func headStyleTags(in page: String) -> String {
        var out: [String] = []
        let patterns = [
            "<link\\b[^>]*stylesheet[^>]*>",
            "<style\\b[^>]*>.*?</style>",
        ]
        let ns = page as NSString
        for pattern in patterns {
            guard let re = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ) else { continue }
            for m in re.matches(in: page, range: NSRange(location: 0, length: ns.length)) {
                out.append(ns.substring(with: m.range))
            }
        }
        return out.joined(separator: "\n")
    }

    private func firstElementInner(_ tag: String, in html: String) -> String? {
        guard let re = try? NSRegularExpression(
            pattern: "<\(tag)\\b[^>]*>(.*?)</\(tag)>",
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = html as NSString
        guard let m = re.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Injects a `<base href>` so relative images/links in a fetched full page resolve
    /// when the message is later rendered (the reader loads HTML with no base URL).
    private func withBase(_ html: String, url: URL) -> String {
        let base = "<base href=\"\(url.absoluteString)\">"
        if let headRe = try? NSRegularExpression(pattern: "<head[^>]*>", options: [.caseInsensitive]) {
            let ns = html as NSString
            if let m = headRe.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) {
                return ns.replacingCharacters(in: m.range, with: ns.substring(with: m.range) + base)
            }
        }
        return base + html
    }
}
