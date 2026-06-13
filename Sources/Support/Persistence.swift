import Foundation
import SwiftData

// MARK: - Snooze

/// Persistent record of a snoozed message. Gmail has no per-message custom
/// property, so the wake time is tracked here while the message carries the
/// `Snoozed` label on the server.
@Model
final class SnoozeRecord {
    @Attribute(.unique) var messageId: String
    var accountEmail: String
    var wakeDate: Date
    var originLabelId: String
    var snoozedLabelId: String
    var createdAt: Date

    init(
        messageId: String,
        accountEmail: String,
        wakeDate: Date,
        originLabelId: String,
        snoozedLabelId: String,
        createdAt: Date = .init()
    ) {
        self.messageId = messageId
        self.accountEmail = accountEmail
        self.wakeDate = wakeDate
        self.originLabelId = originLabelId
        self.snoozedLabelId = snoozedLabelId
        self.createdAt = createdAt
    }
}

// MARK: - Cache models

@Model
final class CachedFolder {
    @Attribute(.unique) var id: String
    var name: String
    var kindRaw: String
    var unreadCount: Int
    var totalCount: Int
    var sortIndex: Int

    init(id: String, name: String, kindRaw: String, unreadCount: Int, totalCount: Int, sortIndex: Int) {
        self.id = id
        self.name = name
        self.kindRaw = kindRaw
        self.unreadCount = unreadCount
        self.totalCount = totalCount
        self.sortIndex = sortIndex
    }
}

@Model
final class CachedMessage {
    @Attribute(.unique) var id: String
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
        id: String, threadId: String, fromName: String, fromEmail: String, toRaw: String,
        subject: String, snippet: String, date: Date, isRead: Bool, isFlagged: Bool,
        hasAttachments: Bool, labelIdsRaw: String
    ) {
        self.id = id
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
        let schema = Schema([SnoozeRecord.self, CachedFolder.self, CachedMessage.self, CachedBody.self])
        do {
            return try ModelContainer(for: schema)
        } catch {
            // If a schema change can't migrate, fall back to a fresh in-memory store.
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: config)
        }
    }()
}
