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

@Model
final class CachedBody {
    @Attribute(.unique) var id: String
    var html: String
    var plainText: String
    var attachmentsJSON: String

    init(id: String, html: String, plainText: String, attachmentsJSON: String) {
        self.id = id
        self.html = html
        self.plainText = plainText
        self.attachmentsJSON = attachmentsJSON
    }
}

// MARK: - Container

enum Persistence {
    static let container: ModelContainer = {
        let schema = Schema([
            SnoozeRecord.self, CachedFolder.self, CachedMessage.self, CachedBody.self, PersistedAccount.self,
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
