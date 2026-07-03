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

    func cachedHeaders(folderId: String, accountId: String, limit: Int = 300) -> [MessageHeader] {
        let needle = ",\(folderId),"
        // Gmail's message list excludes trashed/spam mail by default, so a draft that
        // was trashed (it keeps its DRAFT label but gains TRASH, and gets cached when
        // Trash is viewed) must not linger in the Drafts cache view. Mirror that here:
        // hide TRASH/SPAM rows unless the folder being viewed is itself Trash/Spam.
        // (Graph folder ids are opaque tokens that never contain these literals.)
        let hideTrashSpam = folderId != "TRASH" && folderId != "SPAM"
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate {
                $0.accountId == accountId && $0.labelIdsRaw.contains(needle)
                    && (!hideTrashSpam
                        || (!$0.labelIdsRaw.contains(",TRASH,") && !$0.labelIdsRaw.contains(",SPAM,")))
            },
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

    /// Reconciles the cache for a fully-loaded folder. When a folder is paged to the
    /// end, `keepIds` is the complete, authoritative set of messages the server
    /// currently has in `folderId`, so any cached row still tagged with this folder
    /// but absent from `keepIds` has since left it (e.g. a draft that was sent, or
    /// mail that was archived). Strip the stale folder label; drop the row if that
    /// leaves it with no labels at all.
    func reconcileFolder(folderId: String, accountId: String, keepIds: [String]) {
        let needle = ",\(folderId),"
        let keep = Set(keepIds)
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.accountId == accountId && $0.labelIdsRaw.contains(needle) }
            )
        )) ?? []
        var changed = false
        for row in rows where !keep.contains(row.id) {
            var labels = row.labelIdsRaw.split(separator: ",").map(String.init)
            labels.removeAll { $0 == folderId }
            if labels.isEmpty {
                context.delete(row)
            } else {
                row.labelIdsRaw = "," + labels.joined(separator: ",") + ","
            }
            changed = true
        }
        if changed { try? context.save() }
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

    /// Adds/removes a label on the cached rows (mirrors a server-side batchModify).
    func updateLabel(ids: [String], label: String, present: Bool) {
        mutate(ids: ids) { row in
            row.labelIdsRaw = Self.adjustLabel(row.labelIdsRaw, label, present: present)
        }
    }

    /// Ids of cached messages in `accountId` from the given sender (optionally
    /// narrowed to a From display name — how RSS feed items are told apart, since
    /// they all share one sender address).
    func messageIds(fromEmail: String, fromName: String? = nil, accountId: String) -> [String] {
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.accountId == accountId && $0.fromEmail == fromEmail }
            )
        )) ?? []
        if let fromName {
            return rows.filter { $0.fromName == fromName }.map(\.id)
        }
        return rows.map(\.id)
    }

    /// Cached headers in `accountId` carrying `labelId` that are still in the
    /// Inbox, dated after `since` (oldest-first) — the digest's source set.
    /// Mail moved to a folder, archived, trashed, or marked spam is excluded:
    /// the digest covers only what's sitting in the Inbox.
    func headers(withLabel labelId: String, accountId: String, since: Date) -> [MessageHeader] {
        let needle = ",\(labelId),"
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(
                // Only the narrowing conditions live in the #Predicate — piling
                // the folder checks in too blows the macro's type-check budget.
                predicate: #Predicate {
                    $0.accountId == accountId && $0.labelIdsRaw.contains(needle) && $0.date > since
                },
                sortBy: [SortDescriptor(\.date, order: .forward)]
            )
        )) ?? []
        return rows
            .filter {
                $0.labelIdsRaw.contains(",INBOX,")
                    && !$0.labelIdsRaw.contains(",TRASH,")
                    && !$0.labelIdsRaw.contains(",SPAM,")
            }
            .map(Self.header(from:))
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
        return MessageBody(headerId: row.id, html: row.html, plainText: row.plainText,
                           attachments: attachments, cc: Self.decodeAddresses(row.ccRaw))
    }

    func saveBody(_ body: MessageBody) {
        let attachmentsJSON = (try? JSONEncoder().encode(body.attachments)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let ccRaw = Self.encodeAddresses(body.cc)
        let id = body.headerId
        let isCalendar = body.calendar != nil
        if let row = try? context.fetch(FetchDescriptor<CachedBody>(predicate: #Predicate { $0.id == id })).first {
            row.html = body.html
            row.plainText = body.plainText
            row.attachmentsJSON = attachmentsJSON
            row.ccRaw = ccRaw
            row.isCalendar = isCalendar
        } else {
            context.insert(CachedBody(id: id, html: body.html, plainText: body.plainText,
                                      attachmentsJSON: attachmentsJSON, ccRaw: ccRaw, isCalendar: isCalendar))
        }
        try? context.save()
    }

    // MARK: Translations

    /// Cached Hebrew translation and summary for a message (nil = not produced yet).
    func cachedTranslation(id: String) -> (translated: String?, summary: String?) {
        guard let row = try? context.fetch(
            FetchDescriptor<CachedTranslation>(predicate: #Predicate { $0.id == id })
        ).first else { return (nil, nil) }
        return (row.translatedHTML.isEmpty ? nil : row.translatedHTML,
                row.summaryHTML.isEmpty ? nil : row.summaryHTML)
    }

    /// Upserts the cached translation/summary for a message. A nil argument leaves
    /// that variant untouched, so translation and summary can be saved separately.
    func saveTranslation(id: String, translated: String? = nil, summary: String? = nil) {
        let row: CachedTranslation
        if let existing = try? context.fetch(
            FetchDescriptor<CachedTranslation>(predicate: #Predicate { $0.id == id })
        ).first {
            row = existing
        } else {
            row = CachedTranslation(id: id)
            context.insert(row)
        }
        if let translated { row.translatedHTML = translated }
        if let summary { row.summaryHTML = summary }
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

    /// Encodes addresses as "Name|email" entries joined by "‖" (the format used
    /// for a header's cached To list).
    private static func encodeAddresses(_ addresses: [MailAddress]) -> String {
        addresses.map { "\($0.name)|\($0.email)" }.joined(separator: "‖")
    }

    /// Inverse of `encodeAddresses`.
    private static func decodeAddresses(_ raw: String) -> [MailAddress] {
        raw.isEmpty ? [] : raw.split(separator: "‖").map {
            let parts = $0.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            return MailAddress(name: String(parts.first ?? ""), email: parts.count > 1 ? String(parts[1]) : "")
        }
    }

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
