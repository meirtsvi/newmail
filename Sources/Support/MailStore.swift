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
                if !header.rfcMessageId.isEmpty { row.rfcMessageId = header.rfcMessageId }
            } else {
                let row = CachedMessage(
                    id: header.id, accountId: header.accountId, threadId: header.threadId,
                    fromName: header.from.name, fromEmail: header.from.email, toRaw: toRaw,
                    subject: header.subject, snippet: header.snippet, date: header.date,
                    isRead: header.isRead, isFlagged: header.isFlagged,
                    hasAttachments: header.hasAttachments, labelIdsRaw: labelsRaw
                )
                row.rfcMessageId = header.rfcMessageId
                context.insert(row)
            }
            byId.removeValue(forKey: header.id)
        }
        try? context.save()
        recordReplyMarks(from: headers)
    }

    func setRfcMessageId(_ rfcMessageId: String, forId id: String) {
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.id == id })
        )) ?? []
        guard let row = rows.first else { return }
        row.rfcMessageId = rfcMessageId
        try? context.save()
    }

    // MARK: Replied / forwarded marks

    /// Called with the marks that changed, keyed by `CachedReplyMark.key`.
    var onReplyMarks: (([String: ReplyState]) -> Void)?

    /// Every stored mark, keyed by `CachedReplyMark.key`.
    func replyMarks() -> [String: ReplyState] {
        let rows = (try? context.fetch(FetchDescriptor<CachedReplyMark>())) ?? []
        var marks: [String: ReplyState] = [:]
        for row in rows { marks[row.key] = ReplyState(rawValue: row.stateRaw) }
        return marks
    }

    /// Derives marks from headers: a Gmail sent message marks the message it
    /// answers, and a Graph message carries its own server-side state.
    func recordReplyMarks(from headers: [MessageHeader]) {
        var marks: [(accountId: String, rfcMessageId: String, state: ReplyState, date: Date?)] = []
        for header in headers {
            if !header.inReplyTo.isEmpty, header.labelIds.contains("SENT") {
                marks.append((header.accountId, header.inReplyTo, ReplyState(sentSubject: header.subject), header.date))
            }
            if let state = header.serverReplyState, !header.rfcMessageId.isEmpty {
                // The server's state is authoritative: nil date overwrites.
                marks.append((header.accountId, header.rfcMessageId, state, nil))
            }
        }
        recordReplyMarks(marks)
    }

    /// Upserts marks. A dated mark only replaces an older one (the latest reply or
    /// forward wins); an undated mark always replaces.
    func recordReplyMarks(_ marks: [(accountId: String, rfcMessageId: String, state: ReplyState, date: Date?)]) {
        guard !marks.isEmpty else { return }
        let keys = marks.map { CachedReplyMark.key(accountId: $0.accountId, rfcMessageId: $0.rfcMessageId) }
        let existing = (try? context.fetch(
            FetchDescriptor<CachedReplyMark>(predicate: #Predicate { keys.contains($0.key) })
        )) ?? []
        var byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var changed: [String: ReplyState] = [:]
        for mark in marks {
            let key = CachedReplyMark.key(accountId: mark.accountId, rfcMessageId: mark.rfcMessageId)
            let date = mark.date ?? Date()
            if let row = byKey[key] {
                if let markDate = mark.date, markDate < row.date { continue }
                row.date = date
                guard row.stateRaw != mark.state.rawValue else { continue }
                row.stateRaw = mark.state.rawValue
            } else {
                let row = CachedReplyMark(accountId: mark.accountId, rfcMessageId: mark.rfcMessageId,
                                          stateRaw: mark.state.rawValue, date: date)
                context.insert(row)
                byKey[key] = row
            }
            changed[key] = mark.state
        }
        try? context.save()
        if !changed.isEmpty { onReplyMarks?(changed) }
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
        var dropped: [String] = []
        for row in rows where !keep.contains(row.id) {
            var labels = row.labelIdsRaw.split(separator: ",").map(String.init)
            labels.removeAll { $0 == folderId }
            if labels.isEmpty {
                dropped.append(row.id)
                context.delete(row)
            } else {
                row.labelIdsRaw = "," + labels.joined(separator: ",") + ","
            }
            changed = true
        }
        deleteBodiesAndTranslations(ids: dropped)
        if changed { try? context.save() }
    }

    /// Takes messages out of one folder (a Graph delta removal): strips the
    /// folder label, and drops a row left with no folder at all.
    func removeFromFolder(ids: [String], folderId: String) {
        guard !ids.isEmpty else { return }
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        var dropped: [String] = []
        for row in rows {
            var labels = row.labelIdsRaw.split(separator: ",").map(String.init)
            labels.removeAll { $0 == folderId }
            if labels.isEmpty {
                dropped.append(row.id)
                context.delete(row)
            } else {
                row.labelIdsRaw = "," + labels.joined(separator: ",") + ","
            }
        }
        deleteBodiesAndTranslations(ids: dropped)
        try? context.save()
    }

    /// Of `ids`, the ones already in the cache.
    func existingIds(_ ids: [String]) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { ids.contains($0.id) })
        descriptor.propertiesToFetch = [\.id]
        return Set(((try? context.fetch(descriptor)) ?? []).map(\.id))
    }

    /// After a full Gmail bootstrap: drops cached rows of `accountId` dated on
    /// or after `since` that the server no longer has (`keep` is everything it
    /// listed). Older rows aren't covered by the bootstrap and are left alone.
    func dropUnlisted(accountId: String, since: Date, keep: Set<String>) {
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.accountId == accountId && $0.date >= since })
        descriptor.propertiesToFetch = [\.id]
        let stale = ((try? context.fetch(descriptor)) ?? [])
            .map(\.id)
            .filter { !keep.contains($0) && !$0.hasPrefix(Self.localDraftPrefix) }
        deleteMessages(ids: stale)
    }

    func deleteMessages(ids: [String]) {
        guard !ids.isEmpty else { return }
        let rows = (try? context.fetch(
            FetchDescriptor<CachedMessage>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for row in rows { context.delete(row) }
        deleteBodiesAndTranslations(ids: ids)
        try? context.save()
    }

    /// Drops the cached bodies and translations/summaries of deleted messages, so
    /// they don't pile up as orphans behind message rows that no longer exist.
    private func deleteBodiesAndTranslations(ids: [String]) {
        guard !ids.isEmpty else { return }
        let bodies = (try? context.fetch(
            FetchDescriptor<CachedBody>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for row in bodies { context.delete(row) }
        let translations = (try? context.fetch(
            FetchDescriptor<CachedTranslation>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for row in translations { context.delete(row) }
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

    /// Cached headers in `accountId` carrying `labelId` that the Inbox view
    /// shows, dated after `since` (oldest-first) — the digest's source set.
    /// Matches the Inbox listing exactly (INBOX label, minus Trash/Spam): what
    /// you see in the Inbox is what gets digested. A message Gmail lists both
    /// in the Inbox and in a folder (labeled rather than moved) counts as in
    /// the Inbox; mail properly moved to a folder loses INBOX and drops out.
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

    /// The newest `limit` Inbox messages carrying the label, oldest first — the
    /// same rows as the tail of `headers(withLabel:accountId:since:)`, without
    /// loading every labeled message ever cached. Scans the whole message table,
    /// so it runs off the main thread in its own context.
    nonisolated static func newestHeaders(withLabel labelId: String, accountId: String, limit: Int) async -> [MessageHeader] {
        await Task.detached(priority: .utility) {
            newestHeaders(in: ModelContext(Persistence.container), labelId: labelId, accountId: accountId, limit: limit)
        }.value
    }

    private nonisolated static func newestHeaders(in context: ModelContext, labelId: String, accountId: String,
                                                  limit: Int) -> [MessageHeader] {
        let needle = ",\(labelId),"
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate {
                $0.accountId == accountId && $0.labelIdsRaw.contains(needle) && $0.labelIdsRaw.contains(",INBOX,")
            },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        // Trash/Spam are checked after the fetch (see `headers(withLabel:)`), so
        // read in pages until enough rows pass; normally the first page does.
        let pageSize = limit * 2
        descriptor.fetchLimit = pageSize
        var result: [CachedMessage] = []
        var offset = 0
        while result.count < limit {
            descriptor.fetchOffset = offset
            let rows = (try? context.fetch(descriptor)) ?? []
            result += rows.filter { !$0.labelIdsRaw.contains(",TRASH,") && !$0.labelIdsRaw.contains(",SPAM,") }
            if rows.count < pageSize { break }
            offset += pageSize
        }
        return result.prefix(limit).reversed().map(header(from:))
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

    /// Messages dated on or after `since` with no cached body yet, newest first —
    /// the offline prefetch's work list. Local drafts are skipped (their body is
    /// already stored). `skip` excludes ids that failed earlier this session.
    /// Scans the whole sync window (tens of thousands of rows), so it runs off the
    /// main thread in its own context instead of freezing the UI.
    nonisolated static func messagesNeedingBodies(since: Date, skip: Set<String>, limit: Int) async -> [(id: String, accountId: String)] {
        await Task.detached(priority: .utility) {
            findMessagesNeedingBodies(in: ModelContext(Persistence.container), since: since, skip: skip, limit: limit)
        }.value
    }

    private nonisolated static func findMessagesNeedingBodies(in context: ModelContext, since: Date, skip: Set<String>,
                                                              limit: Int) -> [(id: String, accountId: String)] {
        var bodyDescriptor = FetchDescriptor<CachedBody>()
        bodyDescriptor.propertiesToFetch = [\.id]
        let haveBody = Set(((try? context.fetch(bodyDescriptor)) ?? []).map(\.id))
        var descriptor = FetchDescriptor<CachedMessage>(
            predicate: #Predicate { $0.date >= since },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.id, \.accountId, \.fromEmail]
        var result: [(id: String, accountId: String)] = []
        for row in (try? context.fetch(descriptor)) ?? [] {
            guard !haveBody.contains(row.id), !skip.contains(row.id),
                  !row.id.hasPrefix(Self.localDraftPrefix),
                  !Self.isAutomatedSender(row.fromEmail) else { continue }
            result.append((row.id, row.accountId))
            if result.count == limit { break }
        }
        return result
    }

    /// Senders whose mail isn't downloaded ahead of time: CI, code-hosting and
    /// monitoring notifications, which arrive by the thousand and are rarely
    /// read offline. Their bodies still load when opened online.
    private nonisolated static let automatedSenderPatterns = [
        "cicd", "jenkins", "@github.com", "alerts@", "getsentry.com", "jira@",
    ]

    nonisolated static func isAutomatedSender(_ email: String) -> Bool {
        let lower = email.lowercased()
        return automatedSenderPatterns.contains { lower.contains($0) }
    }

    /// Deletes cached bodies and translations/summaries of messages dated
    /// before `before`, keeping their headers. Returns the ids whose body was
    /// dropped so the caller can delete their cached attachment files too.
    /// Scans every message older than the window, so it runs off the main thread
    /// in its own context.
    @discardableResult
    nonisolated static func pruneBodies(before: Date) async -> [String] {
        await Task.detached(priority: .utility) {
            pruneBodies(in: ModelContext(Persistence.container), before: before)
        }.value
    }

    private nonisolated static func pruneBodies(in context: ModelContext, before: Date) -> [String] {
        var descriptor = FetchDescriptor<CachedMessage>(predicate: #Predicate { $0.date < before })
        descriptor.propertiesToFetch = [\.id]
        let old = ((try? context.fetch(descriptor)) ?? []).map(\.id)
        var pruned: [String] = []
        // Chunked: an `IN` list with tens of thousands of ids is slow to build.
        var index = 0
        while index < old.count {
            let chunk = Array(old[index..<min(index + 500, old.count)])
            index += 500
            for row in (try? context.fetch(FetchDescriptor<CachedBody>(predicate: #Predicate { chunk.contains($0.id) }))) ?? [] {
                pruned.append(row.id)
                context.delete(row)
            }
            for row in (try? context.fetch(FetchDescriptor<CachedTranslation>(predicate: #Predicate { chunk.contains($0.id) }))) ?? [] {
                context.delete(row)
            }
        }
        if !pruned.isEmpty { try? context.save() }
        return pruned
    }

    // MARK: Local drafts

    /// Id prefix of drafts saved on this Mac while offline (not yet on the server).
    nonisolated static let localDraftPrefix = "local:"

    /// Shows an offline-saved draft in the Drafts folder until it reaches the server.
    func saveLocalDraft(id: String, accountId: String, draftsFolderId: String,
                        to: [MailAddress], cc: [MailAddress], subject: String, html: String) {
        let header = MessageHeader(
            id: id, threadId: id, from: MailAddress(name: "", email: ""), to: to,
            subject: subject.isEmpty ? "(no subject)" : subject,
            snippet: Self.plainText(fromHTML: html).prefix(200).description, date: Date(),
            isRead: true, isFlagged: false, hasAttachments: false,
            labelIds: [draftsFolderId], accountId: accountId)
        saveHeaders([header])
        saveBody(MessageBody(headerId: id, html: html, plainText: Self.plainText(fromHTML: html),
                             attachments: [], cc: cc))
    }

    private static func plainText(fromHTML html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Local search

    /// Searches cached mail. Plain words must all appear in the sender,
    /// recipients, subject, preview or body. Understands `from:`, `to:`,
    /// `subject:`, `is:unread`, `is:read`, `is:starred`, `has:attachment` and
    /// quoted phrases; other operators (dates, labels, KQL) are ignored, so the
    /// local result can be broader than the server's.
    func localSearch(_ query: String, accountId: String, folderId: String?, limit: Int = 300) -> [MessageHeader] {
        let q = LocalQuery(query)
        let needle = folderId.map { ",\($0)," }
        let hideTrashSpam = folderId != "TRASH" && folderId != "SPAM"

        // Candidate rows: those matching the first text term in a header field
        // or in the body. Flag-only queries scan the folder.
        var candidates: [CachedMessage] = []
        if let key = q.firstTerm {
            var ids = Set<String>()
            for row in fetchHeaderMatches(key, accountId: accountId) { ids.insert(row.id); candidates.append(row) }
            var bodyDescriptor = FetchDescriptor<CachedBody>(
                predicate: #Predicate { $0.plainText.localizedStandardContains(key) || $0.html.localizedStandardContains(key) })
            bodyDescriptor.propertiesToFetch = [\.id]
            let bodyIds = ((try? context.fetch(bodyDescriptor)) ?? []).map(\.id).filter { !ids.contains($0) }
            if !bodyIds.isEmpty {
                candidates += (try? context.fetch(FetchDescriptor<CachedMessage>(
                    predicate: #Predicate { bodyIds.contains($0.id) && $0.accountId == accountId }))) ?? []
            }
        } else {
            var descriptor = FetchDescriptor<CachedMessage>(
                predicate: #Predicate { $0.accountId == accountId },
                sortBy: [SortDescriptor(\.date, order: .reverse)])
            descriptor.fetchLimit = 5000
            candidates = (try? context.fetch(descriptor)) ?? []
        }

        let matches = candidates.filter { row in
            if let needle, !row.labelIdsRaw.contains(needle) { return false }
            if hideTrashSpam, row.labelIdsRaw.contains(",TRASH,") || row.labelIdsRaw.contains(",SPAM,") { return false }
            if let unread = q.unread, row.isRead == unread { return false }
            if q.starred, !row.isFlagged { return false }
            if q.attachment, !row.hasAttachments { return false }
            let from = (row.fromName + " " + row.fromEmail)
            if !q.from.allSatisfy({ from.localizedStandardContains($0) }) { return false }
            if !q.to.allSatisfy({ row.toRaw.localizedStandardContains($0) }) { return false }
            if !q.subject.allSatisfy({ row.subject.localizedStandardContains($0) }) { return false }
            guard !q.words.isEmpty else { return true }
            let headerText = [from, row.toRaw, row.subject, row.snippet].joined(separator: " ")
            let missing = q.words.filter { !headerText.localizedStandardContains($0) }
            guard !missing.isEmpty else { return true }
            guard let body = cachedBody(id: row.id) else { return false }
            return missing.allSatisfy { body.plainText.localizedStandardContains($0) || body.html.localizedStandardContains($0) }
        }
        return matches
            .sorted { $0.date > $1.date }
            .prefix(limit)
            .map(Self.header(from:))
    }

    /// Header rows of `accountId` containing `key` in a searchable field. Split
    /// into one fetch per field: a single predicate OR-ing them all exceeds the
    /// #Predicate macro's type-check budget.
    private func fetchHeaderMatches(_ key: String, accountId: String) -> [CachedMessage] {
        let predicates: [Predicate<CachedMessage>] = [
            #Predicate { $0.accountId == accountId && $0.subject.localizedStandardContains(key) },
            #Predicate { $0.accountId == accountId && $0.fromName.localizedStandardContains(key) },
            #Predicate { $0.accountId == accountId && $0.fromEmail.localizedStandardContains(key) },
            #Predicate { $0.accountId == accountId && $0.toRaw.localizedStandardContains(key) },
            #Predicate { $0.accountId == accountId && $0.snippet.localizedStandardContains(key) },
        ]
        var seen = Set<String>()
        var rows: [CachedMessage] = []
        for predicate in predicates {
            for row in (try? context.fetch(FetchDescriptor(predicate: predicate))) ?? [] where seen.insert(row.id).inserted {
                rows.append(row)
            }
        }
        return rows
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

    // MARK: Contacts

    /// Every address the message cache knows: senders and To lists from the cached
    /// headers, plus the Cc lists kept on cached bodies. Duplicates are left in —
    /// `ContactStore.record` turns repeats into the use count it ranks by.
    func allCachedAddresses() -> [MailAddress] {
        var addresses: [MailAddress] = []
        for row in (try? context.fetch(FetchDescriptor<CachedMessage>())) ?? [] {
            addresses.append(MailAddress(name: row.fromName, email: row.fromEmail))
            addresses += Self.decodeAddresses(row.toRaw)
        }
        for row in (try? context.fetch(FetchDescriptor<CachedBody>())) ?? [] {
            addresses += Self.decodeAddresses(row.ccRaw)
        }
        return addresses
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

    private nonisolated static func header(from row: CachedMessage) -> MessageHeader {
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
            labelIds: labels, accountId: row.accountId, rfcMessageId: row.rfcMessageId
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

/// A search string parsed for `MailStore.localSearch`.
struct LocalQuery {
    var words: [String] = []
    var from: [String] = []
    var to: [String] = []
    var subject: [String] = []
    var unread: Bool?
    var starred = false
    var attachment = false

    /// The first text term, used to narrow the candidate rows.
    var firstTerm: String? { (words + from + to + subject).first }

    init(_ query: String) {
        for token in Self.tokens(query) {
            let lower = token.lowercased()
            if let value = Self.value(lower, token, "from:") { from.append(value) }
            else if let value = Self.value(lower, token, "to:") { to.append(value) }
            else if let value = Self.value(lower, token, "subject:") { subject.append(value) }
            else if lower == "is:unread" { unread = true }
            else if lower == "is:read" { unread = false }
            else if lower == "is:starred" || lower == "is:flagged" { starred = true }
            else if lower == "has:attachment" || lower == "hasattachments:true" { attachment = true }
            else if lower == "and" || lower == "or" || lower == "not" { continue }
            else if token.contains(":") && !token.contains(" ") { continue }   // unsupported operator
            else { words.append(token) }
        }
    }

    private static func value(_ lower: String, _ token: String, _ prefix: String) -> String? {
        guard lower.hasPrefix(prefix), token.count > prefix.count else { return nil }
        return String(token.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// Splits on whitespace, keeping "quoted phrases" (and `from:"a b"`) whole.
    private static func tokens(_ query: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuote = false
        for ch in query {
            if ch == "\"" {
                inQuote.toggle()
            } else if ch.isWhitespace && !inQuote {
                if !current.isEmpty { result.append(current) }
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
