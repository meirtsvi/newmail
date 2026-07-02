import Foundation
import SwiftData

// MARK: - Snooze

/// Persistent record of a snoozed message. Gmail has no per-message custom
/// property, so the wake time is tracked here while the message carries the
/// `Snoozed` label on the server.
@Model
final class SnoozeRecord {
    @Attribute(.unique) var messageId: String
    var accountId: String = ""
    var accountEmail: String
    var wakeDate: Date
    var originLabelId: String
    var snoozedLabelId: String
    var createdAt: Date

    init(
        messageId: String,
        accountId: String,
        accountEmail: String,
        wakeDate: Date,
        originLabelId: String,
        snoozedLabelId: String,
        createdAt: Date = .init()
    ) {
        self.messageId = messageId
        self.accountId = accountId
        self.accountEmail = accountEmail
        self.wakeDate = wakeDate
        self.originLabelId = originLabelId
        self.snoozedLabelId = snoozedLabelId
        self.createdAt = createdAt
    }
}

// MARK: - Accounts

/// Persisted list of configured accounts (so they reload across launches).
@Model
final class PersistedAccount {
    @Attribute(.unique) var id: String
    var providerKindRaw: String
    var email: String
    var displayName: String
    var externalId: String
    var sortIndex: Int

    init(id: String, providerKindRaw: String, email: String, displayName: String, externalId: String, sortIndex: Int) {
        self.id = id
        self.providerKindRaw = providerKindRaw
        self.email = email
        self.displayName = displayName
        self.externalId = externalId
        self.sortIndex = sortIndex
    }
}

// MARK: - Cache models

@Model
final class CachedFolder {
    /// Composite "accountId\u{1}folderId" — unique across accounts.
    @Attribute(.unique) var key: String
    var accountId: String
    var id: String
    var name: String
    var kindRaw: String
    var unreadCount: Int
    var totalCount: Int
    var sortIndex: Int
    var path: String = ""

    init(accountId: String, id: String, name: String, kindRaw: String, unreadCount: Int, totalCount: Int, sortIndex: Int, path: String) {
        self.key = "\(accountId)\u{1}\(id)"
        self.accountId = accountId
        self.id = id
        self.name = name
        self.kindRaw = kindRaw
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.sortIndex = sortIndex
        self.path = path
    }
}

@Model
final class CachedMessage {
    @Attribute(.unique) var id: String
    var accountId: String = ""
    var threadId: String
    var fromName: String
    var fromEmail: String
    var toRaw: String          // "Name|email" entries joined by "‖"
    var subject: String
    var snippet: String
    var date: Date
    var isRead: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
    /// Label membership wrapped in delimiters, e.g. ",INBOX,Label_12," so a
    /// folder query can match ",<id>," without partial collisions.
    var labelIdsRaw: String

    init(
        id: String, accountId: String, threadId: String, fromName: String, fromEmail: String, toRaw: String,
        subject: String, snippet: String, date: Date, isRead: Bool, isFlagged: Bool,
        hasAttachments: Bool, labelIdsRaw: String
    ) {
        self.id = id
        self.accountId = accountId
        self.threadId = threadId
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.toRaw = toRaw
        self.subject = subject
        self.snippet = snippet
        self.date = date
        self.isRead = isRead
        self.isFlagged = isFlagged
        self.hasAttachments = hasAttachments
        self.labelIdsRaw = labelIdsRaw
    }
}

/// A known recipient/sender, used to autocomplete the compose To/Cc fields.
/// Collected from message senders and the recipients of mail you've sent.
@Model
final class CachedContact {
    @Attribute(.unique) var email: String   // lowercased; the match + dedupe key
    var name: String
    var useCount: Int
    var lastSeen: Date

    init(email: String, name: String, useCount: Int, lastSeen: Date) {
        self.email = email
        self.name = name
        self.useCount = useCount
        self.lastSeen = lastSeen
    }
}

@Model
final class CachedBody {
    @Attribute(.unique) var id: String
    var html: String
    var plainText: String
    var attachmentsJSON: String
    /// Cc recipients as "Name|email" entries joined by "‖" (same encoding as a
    /// header's To). Defaulted so the additive schema change migrates in place
    /// without discarding the cache.
    var ccRaw: String = ""
    /// Whether this message carries a calendar invitation (drives the list's
    /// calendar-event column). Defaulted so the additive schema change migrates
    /// in place without discarding the cache.
    var isCalendar: Bool = false

    init(id: String, html: String, plainText: String, attachmentsJSON: String, ccRaw: String = "", isCalendar: Bool = false) {
        self.id = id
        self.html = html
        self.plainText = plainText
        self.attachmentsJSON = attachmentsJSON
        self.ccRaw = ccRaw
        self.isCalendar = isCalendar
    }
}

/// Cached Hebrew translation and summary of a message body, keyed by message id.
/// Written when a translation/summary is produced — on demand from the viewers'
/// toggle buttons, or ahead of time for imported RSS feed items — so showing
/// either again (including across launches) is instant. Empty string = not yet
/// produced for that variant.
@Model
final class CachedTranslation {
    @Attribute(.unique) var id: String
    var translatedHTML: String
    var summaryHTML: String
    var createdAt: Date

    init(id: String, translatedHTML: String = "", summaryHTML: String = "", createdAt: Date = .init()) {
        self.id = id
        self.translatedHTML = translatedHTML
        self.summaryHTML = summaryHTML
        self.createdAt = createdAt
    }
}

// MARK: - RSS Feeds

/// A subscribed RSS/Atom feed. Polled every few minutes; each new item is inserted
/// into the Gmail Inbox as a real received message (see `FeedService`).
@Model
final class FeedSubscription {
    @Attribute(.unique) var url: String
    /// The feed's own `<title>`, resolved on first fetch; falls back to the host.
    var title: String
    var createdAt: Date

    init(url: String, title: String, createdAt: Date = .init()) {
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }
}

/// Records a feed item that has already been imported (or intentionally skipped on
/// first add), so it is never imported twice. `key` is `feedURL + "\u{1}" + guid`.
@Model
final class SeenFeedItem {
    @Attribute(.unique) var key: String
    var createdAt: Date

    init(key: String, createdAt: Date = .init()) {
        self.key = key
        self.createdAt = createdAt
    }
}

// MARK: - Container

enum Persistence {
    static let container: ModelContainer = {
        let schema = Schema([
            SnoozeRecord.self, CachedFolder.self, CachedMessage.self, CachedBody.self,
            PersistedAccount.self, CachedContact.self,
            FeedSubscription.self, SeenFeedItem.self, CachedTranslation.self,
        ])
        // Versioned store file: the multi-account schema is incompatible with the
        // single-account one, and the cache is disposable (re-fetched from the
        // server), so we use a fresh file rather than a migration.
        let dir = URL.applicationSupportDirectory.appending(path: "newmail", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeURL = dir.appending(path: "cache-v2.store")
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: storeURL))
        } catch {
            // Last resort: a fresh in-memory store so the app still launches.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: config)
        }
    }()
}
