import Foundation

/// Gmail REST API v1 client. Maps Gmail's label model onto the app's folder
/// abstraction. Read operations work with a `gmail.readonly` token; write
/// operations require `gmail.modify` / `gmail.send` and otherwise return 403.
final class GmailProvider: MailProvider {
    private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    private let auth: GoogleAuth
    let accountId: String
    private(set) var accountEmail: String = "me"

    /// Concurrency cap for per-message header fetches (kept low to avoid
    /// Gmail's burst rate-limit, which returns 429 RESOURCE_EXHAUSTED).
    private let headerFetchWindow = 6

    init(accountId: String = "gmail", auth: GoogleAuth = .shared) {
        self.accountId = accountId
        self.auth = auth
    }

    // MARK: - HTTP

    private func request(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        jsonBody: Data? = nil
    ) async throws -> Data {
        var comps = URLComponents(
            url: base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { comps.queryItems = query }

        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        let token = try await auth.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            req.httpBody = jsonBody
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw MailError.other("No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MailError.api(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    // MARK: - Profile

    func loadProfile() async throws {
        let data = try await request("profile")
        let profile = try JSONDecoder().decode(GmailAPI.Profile.self, from: data)
        accountEmail = profile.emailAddress
    }

    // MARK: - Folders

    func listFolders() async throws -> [MailFolder] {
        let data = try await request("labels")
        let list = try JSONDecoder().decode(GmailAPI.LabelsList.self, from: data)
        let shown = list.labels.filter { Self.isFolderLabel($0) }

        // Build folders directly from the single labels call (no counts yet) so
        // the sidebar populates immediately and never depends on count requests.
        var folders = shown.map { label in
            MailFolder(
                id: label.id,
                name: Self.displayName(label),
                kind: Self.kind(label),
                unreadCount: 0,
                totalCount: 0,
                // User labels carry their full nested name (e.g. "Work/Receipts").
                path: label.type == "user" ? label.name : Self.displayName(label),
                accountId: accountId
            )
        }

        // Hydrate unread/total counts for the primary folders only (Inbox,
        // Sent, Drafts, etc.) so the sidebar appears quickly. Per-custom-label
        // counts are deferred (a background pass is a planned follow-up).
        // Failures (e.g. transient 429s) are non-fatal.
        let countIds = shown.filter { Self.kind($0) != .custom }.map(\.id)
        let counts = await fetchCounts(countIds)
        for i in folders.indices {
            if let c = counts[folders[i].id] {
                folders[i].unreadCount = c.unread
                folders[i].totalCount = c.total
            }
        }

        return folders.sorted { a, b in
            if a.kind.sortWeight != b.kind.sortWeight { return a.kind.sortWeight < b.kind.sortWeight }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Fetches (unread, total) per label in small concurrent windows to stay
    /// under Gmail's burst limits. Failures are dropped rather than thrown.
    private func fetchCounts(_ ids: [String]) async -> [String: (unread: Int, total: Int)] {
        var result: [String: (unread: Int, total: Int)] = [:]
        let window = 5
        var index = 0
        while index < ids.count {
            let slice = Array(ids[index..<min(index + window, ids.count)])
            await withTaskGroup(of: (String, (unread: Int, total: Int))?.self) { group in
                for id in slice {
                    group.addTask { [self] in
                        guard let d = try? await request("labels/\(id)"),
                              let full = try? JSONDecoder().decode(GmailAPI.Label.self, from: d)
                        else { return nil }
                        return (id, (full.messagesUnread ?? 0, full.messagesTotal ?? 0))
                    }
                }
                for await item in group {
                    if let item { result[item.0] = item.1 }
                }
            }
            index += window
        }
        return result
    }

    func folderCount(id: String) async throws -> (unread: Int, total: Int) {
        let data = try await request("labels/\(id)")
        let label = try JSONDecoder().decode(GmailAPI.Label.self, from: data)
        return (label.messagesUnread ?? 0, label.messagesTotal ?? 0)
    }

    func ensureFolder(named name: String) async throws -> String {
        let data = try await request("labels")
        let list = try JSONDecoder().decode(GmailAPI.LabelsList.self, from: data)
        if let existing = list.labels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return existing.id
        }
        struct NewLabel: Codable {
            var name: String
            var labelListVisibility = "labelShow"
            var messageListVisibility = "show"
        }
        let body = try JSONEncoder().encode(NewLabel(name: name))
        let created = try await request("labels", method: "POST", jsonBody: body)
        return try JSONDecoder().decode(GmailAPI.CreatedLabel.self, from: created).id
    }

    // MARK: - Listing & search

    func listMessages(
        folderId: String,
        query: String?,
        pageToken: String?
    ) async throws -> (headers: [MessageHeader], nextPageToken: String?) {
        var items = [
            URLQueryItem(name: "maxResults", value: "100"),
            URLQueryItem(name: "labelIds", value: folderId),
        ]
        if let query, !query.isEmpty { items.append(URLQueryItem(name: "q", value: query)) }
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await listAndHydrate(items)
    }

    func search(
        query: String,
        pageToken: String?
    ) async throws -> (headers: [MessageHeader], nextPageToken: String?) {
        var items = [
            URLQueryItem(name: "maxResults", value: "100"),
            URLQueryItem(name: "q", value: query),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        return try await listAndHydrate(items)
    }

    private func listAndHydrate(
        _ items: [URLQueryItem]
    ) async throws -> (headers: [MessageHeader], nextPageToken: String?) {
        let data = try await request("messages", query: items)
        let list = try JSONDecoder().decode(GmailAPI.MessagesList.self, from: data)
        let ids = (list.messages ?? []).map(\.id)
        let headers = await fetchHeaders(ids)
        return (headers, list.nextPageToken)
    }

    /// Fetches metadata for many message ids with capped concurrency, preserving
    /// order. A failed individual fetch is skipped rather than aborting the whole
    /// page (so one transient error can't drop the entire list).
    private func fetchHeaders(_ ids: [String]) async -> [MessageHeader] {
        var byId: [String: MessageHeader] = [:]
        var index = 0
        while index < ids.count {
            let slice = Array(ids[index..<min(index + headerFetchWindow, ids.count)])
            await withTaskGroup(of: MessageHeader?.self) { group in
                for id in slice {
                    group.addTask { [self] in try? await fetchHeader(id) }
                }
                for await header in group {
                    if let header { byId[header.id] = header }
                }
            }
            index += headerFetchWindow
        }
        return ids.compactMap { byId[$0] }
    }

    private func fetchHeader(_ id: String) async throws -> MessageHeader? {
        let items = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
            URLQueryItem(name: "metadataHeaders", value: "To"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "Date"),
        ]
        let data = try await request("messages/\(id)", query: items)
        let msg = try JSONDecoder().decode(GmailAPI.Message.self, from: data)
        return Self.header(from: msg, accountId: accountId)
    }

    // MARK: - Body

    func fetchBody(id: String) async throws -> MessageBody {
        let data = try await request(
            "messages/\(id)",
            query: [URLQueryItem(name: "format", value: "full")]
        )
        let msg = try JSONDecoder().decode(GmailAPI.Message.self, from: data)

        var html = ""
        var text = ""
        var ics = ""
        var icsAttachmentId: String?
        var attachments: [MailAttachment] = []

        // Image parts (inline or standalone): captured separately so we can fetch
        // their bytes and either embed them (cid:) or preview them below the body.
        struct ImagePart { var attachmentId: String?; var inlineData: Data?; var mime: String; var cid: String?; var filename: String }
        var imageParts: [ImagePart] = []

        func isCalendar(_ mime: String, _ filename: String) -> Bool {
            mime.hasPrefix("text/calendar") || mime == "application/ics"
                || filename.lowercased().hasSuffix(".ics")
        }

        func headerValue(_ part: GmailAPI.Part, _ name: String) -> String? {
            part.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func walk(_ part: GmailAPI.Part?) {
            guard let part else { return }
            let mime = (part.mimeType ?? "").lowercased()
            let filename = part.filename ?? ""
            // Calendar invites arrive either inline (text/calendar inside a
            // multipart/alternative) or as an invite.ics attachment. Capture the
            // content either way and surface it as a card, not a file chip.
            if isCalendar(mime, filename) {
                if let encoded = part.body?.data, let decoded = Self.decodeBase64URL(encoded) {
                    ics += String(decoding: decoded, as: UTF8.self)
                } else if let attId = part.body?.attachmentId, icsAttachmentId == nil {
                    icsAttachmentId = attId
                }
            } else if mime.hasPrefix("image/"), part.body?.attachmentId != nil || part.body?.data != nil {
                let rawCID = headerValue(part, "Content-ID") ?? headerValue(part, "X-Attachment-Id")
                let cid = rawCID?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                imageParts.append(ImagePart(
                    attachmentId: part.body?.attachmentId,
                    inlineData: part.body?.data.flatMap(Self.decodeBase64URL),
                    mime: part.mimeType ?? "image/png",
                    cid: (cid?.isEmpty ?? true) ? nil : cid,
                    filename: filename
                ))
            } else if !filename.isEmpty, let attId = part.body?.attachmentId {
                attachments.append(MailAttachment(
                    id: attId,
                    messageId: id,
                    filename: filename,
                    mimeType: part.mimeType ?? "",
                    sizeBytes: part.body?.size ?? 0
                ))
            } else if let encoded = part.body?.data, let decoded = Self.decodeBase64URL(encoded) {
                let str = String(decoding: decoded, as: UTF8.self)
                if mime == "text/html" { html += str }
                else if mime == "text/plain" { text += str }
            }
            part.parts?.forEach(walk)
        }
        walk(msg.payload)

        // If the invite was delivered only as an attachment, fetch its bytes.
        if ics.isEmpty, let attId = icsAttachmentId,
           let data = try? await fetchAttachmentData(messageId: id, attachmentId: attId) {
            ics = String(decoding: data, as: UTF8.self)
        }

        // Pull the bytes for each image part, then embed/preview them.
        var images: [InlineImage] = []
        for part in imageParts {
            let data: Data?
            if let inline = part.inlineData {
                data = inline
            } else if let attId = part.attachmentId {
                data = try? await fetchAttachmentData(messageId: id, attachmentId: attId)
            } else {
                data = nil
            }
            guard let data else { continue }
            images.append(InlineImage(cid: part.cid, mime: part.mime, data: data,
                                      filename: part.filename, attachmentId: part.attachmentId))
        }

        let assembled = BodyHTML.assemble(rawHTML: html, plainText: text, images: images, messageId: id)
        let invite = ics.isEmpty ? nil : ICSParser.parse(ics)
        let ccRaw = msg.payload?.headers?
            .first { $0.name.caseInsensitiveCompare("cc") == .orderedSame }?.value ?? ""
        return MessageBody(headerId: id, html: assembled.html, plainText: text,
                           attachments: attachments + assembled.imageAttachments,
                           cc: MailAddress.parseList(ccRaw), calendar: invite)
    }

    /// Downloads and decodes a single attachment's bytes (used to read an
    /// invite.ics that wasn't inlined in the body).
    private func fetchAttachmentData(messageId: String, attachmentId: String) async throws -> Data? {
        let data = try await request("messages/\(messageId)/attachments/\(attachmentId)")
        let body = try JSONDecoder().decode(GmailAPI.Body.self, from: data)
        return body.data.flatMap(Self.decodeBase64URL)
    }

    func fetchAttachment(messageId: String, attachmentId: String) async throws -> Data {
        guard let data = try await fetchAttachmentData(messageId: messageId, attachmentId: attachmentId) else {
            throw MailError.other("Attachment is unavailable.")
        }
        return data
    }

    /// Matches invites carrying an `.ics` attachment (the common Google Calendar
    /// case) with a single paged listing — no per-message body fetch.
    func calendarInviteIds(folderId: String) async throws -> Set<String> {
        var ids: Set<String> = []
        var pageToken: String?
        repeat {
            var items = [
                URLQueryItem(name: "maxResults", value: "500"),
                URLQueryItem(name: "labelIds", value: folderId),
                URLQueryItem(name: "q", value: "filename:ics"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let data = try await request("messages", query: items)
            let list = try JSONDecoder().decode(GmailAPI.MessagesList.self, from: data)
            ids.formUnion((list.messages ?? []).map(\.id))
            pageToken = list.nextPageToken
        } while pageToken != nil
        return ids
    }

    // MARK: - Mutations (require write scope)

    func setRead(ids: [String], read: Bool) async throws {
        try await batchModify(ids: ids,
                              add: read ? [] : ["UNREAD"],
                              remove: read ? ["UNREAD"] : [])
    }

    func setFlagged(ids: [String], flagged: Bool) async throws {
        try await batchModify(ids: ids,
                              add: flagged ? ["STARRED"] : [],
                              remove: flagged ? [] : ["STARRED"])
    }

    func archive(ids: [String]) async throws {
        try await batchModify(ids: ids, add: [], remove: ["INBOX"])
    }

    func move(ids: [String], toFolderId: String, fromFolderId: String?) async throws {
        var remove = ["INBOX"]
        if let fromFolderId, fromFolderId != "INBOX" { remove = [fromFolderId] }
        try await batchModify(ids: ids, add: [toFolderId], remove: remove)
    }

    func trash(ids: [String]) async throws {
        for id in ids {
            _ = try await request("messages/\(id)/trash", method: "POST")
        }
    }

    /// Untrash restores the message's prior labels (e.g. INBOX), so the message
    /// returns to the folder it was deleted from; `toFolderId` is unused here.
    func untrash(ids: [String], toFolderId: String) async throws {
        for id in ids {
            _ = try await request("messages/\(id)/untrash", method: "POST")
        }
    }

    func markNotSpam(ids: [String]) async throws {
        try await batchModify(ids: ids, add: ["INBOX"], remove: ["SPAM"])
    }

    private func batchModify(ids: [String], add: [String], remove: [String]) async throws {
        guard !ids.isEmpty else { return }
        struct Body: Codable {
            var ids: [String]
            var addLabelIds: [String]
            var removeLabelIds: [String]
        }
        let body = try JSONEncoder().encode(Body(ids: ids, addLabelIds: add, removeLabelIds: remove))
        _ = try await request("messages/batchModify", method: "POST", jsonBody: body)
    }

    // MARK: - Sending

    func send(rawMIME: Data) async throws {
        struct Body: Codable { var raw: String }
        let raw = rawMIME.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let body = try JSONEncoder().encode(Body(raw: raw))
        _ = try await request("messages/send", method: "POST", jsonBody: body)
    }

    // MARK: - Drafts

    func saveDraft(id: String?, rawMIME: Data) async throws -> String {
        struct Message: Codable { var raw: String }
        struct Body: Codable { var message: Message }
        struct DraftResponse: Codable { var id: String }
        let raw = rawMIME.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let body = try JSONEncoder().encode(Body(message: Message(raw: raw)))
        // PUT replaces an existing draft in place (same id); POST creates a new one.
        let data: Data
        if let id {
            data = try await request("drafts/\(id)", method: "PUT", jsonBody: body)
        } else {
            data = try await request("drafts", method: "POST", jsonBody: body)
        }
        return try JSONDecoder().decode(DraftResponse.self, from: data).id
    }

    func deleteDraft(id: String) async throws {
        _ = try await request("drafts/\(id)", method: "DELETE")
    }

    // MARK: - Cross-account move (destination side)

    /// Imports a message into this mailbox via `messages.insert` (IMAP-APPEND-style):
    /// it does not send anything and bypasses spam classification, so the message
    /// keeps its original sender, headers, and date. `internalDateSource=dateHeader`
    /// dates it by its own `Date:` header so it sorts where it belongs. The target
    /// label is applied (plus `UNREAD` to keep it unread). Requires `gmail.modify`.
    func importRawMessage(_ raw: Data, toFolderId: String, markUnread: Bool) async throws -> String {
        var labels = [toFolderId]
        if markUnread { labels.append("UNREAD") }
        // The inline JSON insert is capped around 5 MB; larger messages (big
        // attachments) go through the resumable/multipart upload endpoint instead.
        if raw.count > 4_000_000 {
            return try await uploadImport(raw: raw, labelIds: labels)
        }
        struct Body: Encodable { var raw: String; var labelIds: [String] }
        let body = try JSONEncoder().encode(Body(raw: Self.base64url(raw), labelIds: labels))
        let data = try await request(
            "messages",
            query: [URLQueryItem(name: "internalDateSource", value: "dateHeader")],
            method: "POST", jsonBody: body
        )
        struct Inserted: Decodable { var id: String }
        return try JSONDecoder().decode(Inserted.self, from: data).id
    }

    /// Inserts a large message through the media-upload endpoint (a different host
    /// than the JSON API), sending the raw RFC822 bytes directly so we don't inflate
    /// them 33% with base64 inside a JSON body.
    private func uploadImport(raw: Data, labelIds: [String]) async throws -> String {
        var comps = URLComponents(string: "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages")!
        comps.queryItems = [
            URLQueryItem(name: "uploadType", value: "multipart"),
            URLQueryItem(name: "internalDateSource", value: "dateHeader"),
        ]
        let boundary = "newmail-\(UUID().uuidString)"
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        let token = try await auth.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let meta = try JSONSerialization.data(withJSONObject: ["labelIds": labelIds])
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        append("--\(boundary)\r\n")
        append("Content-Type: application/json; charset=UTF-8\r\n\r\n")
        body.append(meta)
        append("\r\n--\(boundary)\r\n")
        append("Content-Type: message/rfc822\r\n\r\n")
        body.append(raw)
        append("\r\n--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MailError.other("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw MailError.api(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        struct Inserted: Decodable { var id: String }
        return try JSONDecoder().decode(Inserted.self, from: data).id
    }

    /// RFC 2822 message bytes → base64url (no padding), as Gmail's `raw` field expects.
    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Mapping helpers

    private static let hiddenSystemLabels: Set<String> = [
        "UNREAD", "STARRED", "IMPORTANT", "CHAT", "CATEGORY_PERSONAL",
        "CATEGORY_SOCIAL", "CATEGORY_PROMOTIONS", "CATEGORY_UPDATES", "CATEGORY_FORUMS",
    ]

    private static func isFolderLabel(_ label: GmailAPI.Label) -> Bool {
        if label.type == "user" { return true }
        return !hiddenSystemLabels.contains(label.id)
    }

    private static func kind(_ label: GmailAPI.Label) -> FolderKind {
        switch label.id {
        case "INBOX": return .inbox
        case "SENT": return .sent
        case "DRAFT": return .drafts
        case "TRASH": return .trash
        case "SPAM": return .junk
        default:
            if label.name.caseInsensitiveCompare("Snoozed") == .orderedSame { return .snoozed }
            return .custom
        }
    }

    private static func displayName(_ label: GmailAPI.Label) -> String {
        switch label.id {
        case "INBOX": return "Inbox"
        case "SENT": return "Sent"
        case "DRAFT": return "Drafts"
        case "TRASH": return "Trash"
        case "SPAM": return "Junk"
        default:
            // Show the leaf of nested labels like "Work/Receipts".
            return label.name.split(separator: "/").last.map(String.init) ?? label.name
        }
    }

    private static func header(from msg: GmailAPI.Message, accountId: String) -> MessageHeader {
        var headers: [String: String] = [:]
        for h in msg.payload?.headers ?? [] {
            headers[h.name.lowercased()] = h.value
        }
        let labels = msg.labelIds ?? []
        let ms = Double(msg.internalDate ?? "0") ?? 0
        return MessageHeader(
            id: msg.id,
            threadId: msg.threadId,
            from: MailAddress.parse(headers["from"] ?? ""),
            to: MailAddress.parseList(headers["to"] ?? ""),
            subject: headers["subject"] ?? "(no subject)",
            snippet: msg.snippet ?? "",
            date: Date(timeIntervalSince1970: ms / 1000.0),
            isRead: !labels.contains("UNREAD"),
            isFlagged: labels.contains("STARRED"),
            // Heuristic from the metadata payload: multipart/mixed messages
            // carry attachments (the parts tree isn't returned by format=metadata).
            hasAttachments: (msg.payload?.mimeType ?? "").caseInsensitiveCompare("multipart/mixed") == .orderedSame,
            labelIds: labels,
            accountId: accountId
        )
    }

    private static func decodeBase64URL(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        return Data(base64Encoded: str)
    }
}
