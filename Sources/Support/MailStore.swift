import Foundation
import SwiftData

/// SwiftData-backed cache for folders, message headers, and bodies. Lets the UI
/// paint instantly from cache and keep working offline, with the network as the
/// source of truth that reconciles into the cache. Multi-account: folders and
/// headers are scoped by `accountId`.
@MainActor
final class MailStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? Persistence.container.mainContext
    }

    // MARK: Folders

    func cachedFolders(accountId: String) -> [MailFolder] {
        let descriptor = FetchDescriptor<CachedFolder>(
            predicate: #Predicate { $0.accountId == accountId },
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map {
            MailFolder(
                id: $0.id,
                name: $0.name,
                kind: FolderKind(rawValue: $0.kindRaw) ?? .custom,
                unreadCount: $0.unreadCount,
                totalCount: $0.totalCount,
                path: $0.path.isEmpty ? $0.name : $0.path,
                accountId: $0.accountId
            )
        }
    }

    func saveFolders(_ folders: [MailFolder], accountId: String) {
        let existing = (try? context.fetch(
            FetchDescriptor<CachedFolder>(predicate: #Predicate { $0.accountId == accountId })
        )) ?? []
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let liveIds = Set(folders.map(\.id))

        for (index, folder) in folders.enumerated() {
            if let row = byId[folder.id] {
                row.name = folder.name
                row.kindRaw = folder.kind.rawValue
                row.unreadCount = folder.unreadCount
                row.totalCount = folder.totalCount
                row.sortIndex = index
                row.path = folder.path
            } else {
                context.insert(CachedFolder(
                    accountId: accountId, id: folder.id, name: folder.name, kindRaw: folder.kind.rawValue,
                    unreadCount: folder.unreadCount, totalCount: folder.totalCount,
                    sortIndex: index, path: folder.path
                ))
            }
            byId.removeValue(forKey: folder.id)
        }
        // Drop folders that no longer exist server-side (within this account).
        for (id, row) in byId where !liveIds.contains(id) {
            context.delete(row)
        }
        try? context.save()
    }

    // MARK: Headers

    func cachedHeaders(folderId: String, accountId: String, limit: Int = 200) -> [MessageHeader] {
        let needle = ",\(folderId),"
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountId == accountId && $0.labelIdsRaw.contains(needle) },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map(Self.header(from:))
    }

    func saveHeaders(_ headers: [MessageHeader]) {
        guard !headers.isEmpty else { return }
        let ids = headers.map(\.id)
        let existing = (try? context.fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        var byId = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for header in headers {
            let toRaw = header.to.map { "\($0.name)|\($0.email)" }.joined(separator: "‖")
            let labelsRaw = "," + header.labelIds.joined(separator: ",") + ","
            if let row = byId[header.id] {
                row.accountId = header.accountId
                row.fromName = header.from.name
                row.fromEmail = header.from.email
                row.toRaw = toRaw
                row.subject = header.subject
                row.snippet = header.snippet
                row.date = header.date
                row.isRead = header.isRead
                row.isFlagged = header.isFlagged
                row.hasAttachments = header.hasAttachments
                row.labelIdsRaw = labelsRaw
            } else {
                context.insert(CachedMessage(
                    id: header.id, accountId: header.accountId, threadId: header.threadId,
                    fromName: header.from.name, fromEmail: header.from.email, toRaw: toRaw,
                    subject: header.subject, snippet: header.snippet, date: header.date,
                    isRead: header.isRead, isFlagged: header.isFlagged,
                    hasAttachments: header.hasAttachments, labelIdsRaw: labelsRaw
                ))
            }
            byId.removeValue(forKey: header.id)
        }
        try? context.save()
    }

    func deleteMessages(ids: [String]) {
        guard !ids.isEmpty else { return }
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for row in rows { context.delete(row) }
        try? context.save()
    }

    func updateRead(ids: [String], read: Bool) {
        mutate(ids: ids) { row in
            row.isRead = read
            row.labelIdsRaw = Self.adjustLabel(row.labelIdsRaw, "UNREAD", present: !read)
        }
    }

    func updateFlag(ids: [String], flagged: Bool) {
        mutate(ids: ids) { row in
            row.isFlagged = flagged
            row.labelIdsRaw = Self.adjustLabel(row.labelIdsRaw, "STARRED", present: flagged)
        }
    }

    private func mutate(ids: [String], _ change: (CachedMessage) -> Void) {
        guard !ids.isEmpty else { return }
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for row in rows { change(row) }
        try? context.save()
    }

    // MARK: Bodies

    func cachedBody(id: String) -> MessageBody? {
        let descriptor = FetchDescriptor<CachedBody>(predicate: #Predicate { $0.id == id })
        guard let row = try? context.fetch(descriptor).first else { return nil }
        let attachments = (try? JSONDecoder().decode([MailAttachment].self, from: Data(row.attachmentsJSON.utf8))) ?? []
        return MessageBody(headerId: row.id, html: row.html, plainText: row.plainText, attachments: attachments)
    }

    func saveBody(_ body: MessageBody) {
        let attachmentsJSON = (try? JSONEncoder().encode(body.attachments)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let id = body.headerId
        let isCalendar = body.calendar != nil
        if let row = try? context.fetch(FetchDescriptor<CachedBody>(predicate: #Predicate { $0.id == id })).first {
            row.html = body.html
            row.plainText = body.plainText
            row.attachmentsJSON = attachmentsJSON
            row.isCalendar = isCalendar
        } else {
            context.insert(CachedBody(id: id, html: body.html, plainText: body.plainText,
                                      attachmentsJSON: attachmentsJSON, isCalendar: isCalendar))
        }
        try? context.save()
    }

    /// Of the given message ids, those whose cached body is a calendar invitation.
    func calendarMessageIds(among ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        let rows = (try? context.fetch(
            FetchDescriptor<CachedBody>(predicate: #Predicate { ids.contains($0.id) && $0.isCalendar })
        )) ?? []
        return Set(rows.map(\.id))
    }

    // MARK: Mapping

    private static func header(from row: CachedMessage) -> MessageHeader {
        let to: [MailAddress] = row.toRaw.isEmpty ? [] : row.toRaw.split(separator: "‖").map {
            let parts = $0.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            return MailAddress(name: String(parts.first ?? ""), email: parts.count > 1 ? String(parts[1]) : "")
        }
        let labels = row.labelIdsRaw
            .split(separator: ",")
            .map(String.init)
        return MessageHeader(
            id: row.id, threadId: row.threadId,
            from: MailAddress(name: row.fromName, email: row.fromEmail),
            to: to, subject: row.subject, snippet: row.snippet, date: row.date,
            isRead: row.isRead, isFlagged: row.isFlagged, hasAttachments: row.hasAttachments,
            labelIds: labels, accountId: row.accountId
        )
    }

    private static func adjustLabel(_ raw: String, _ label: String, present: Bool) -> String {
        var labels = raw.split(separator: ",").map(String.init)
        if present {
            if !labels.contains(label) { labels.append(label) }
        } else {
            labels.removeAll { $0 == label }
        }
        return "," + labels.joined(separator: ",") + ","
    }
}
