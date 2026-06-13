import Foundation

/// Gmail REST API v1 client. Maps Gmail's label model onto the app's folder
/// abstraction. Read operations work with a `gmail.readonly` token; write
/// operations require `gmail.modify` / `gmail.send` and otherwise return 403.
final class GmailProvider: MailProvider {
    private let base = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!
    private let auth: GoogleAuth
    private(set) var accountEmail: String = "me"

    /// Concurrency cap for per-message header fetches (kept low to avoid
    /// Gmail's burst rate-limit, which returns 429 RESOURCE_EXHAUSTED).
    private let headerFetchWindow = 6

    init(auth: GoogleAuth = .shared) {
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
                totalCount: 0
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
            URLQueryItem(name: "maxResults", value: "50"),
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
            URLQueryItem(name: "maxResults", value: "50"),
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
        let headers = try await fetchHeaders(ids)
        return (headers, list.nextPageToken)
    }

    /// Fetches metadata for many message ids, capped concurrency, original order preserved.
    private func fetchHeaders(_ ids: [String]) async throws -> [MessageHeader] {
        var byId: [String: MessageHeader] = [:]
        var index = 0
        while index < ids.count {
            let slice = Array(ids[index..<min(index + headerFetchWindow, ids.count)])
            try await withThrowingTaskGroup(of: MessageHeader?.self) { group in
                for id in slice {
                    group.addTask { [self] in try await fetchHeader(id) }
                }
                for try await header in group {
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
        return Self.header(from: msg)
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
        var attachments: [MailAttachment] = []

        func walk(_ part: GmailAPI.Part?) {
            guard let part else { return }
            let mime = part.mimeType ?? ""
            if let filename = part.filename, !filename.isEmpty,
               let attId = part.body?.attachmentId {
                attachments.append(MailAttachment(
                    id: attId,
                    messageId: id,
                    filename: filename,
                    mimeType: mime,
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

        if html.isEmpty, !text.isEmpty {
            let escaped = text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            html = "<pre style=\"white-space:pre-wrap;font-family:-apple-system,sans-serif\">\(escaped)</pre>"
        }
        return MessageBody(headerId: id, html: html, plainText: text, attachments: attachments)
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

    private static func header(from msg: GmailAPI.Message) -> MessageHeader {
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
            labelIds: labels
        )
    }

    private static func decodeBase64URL(_ s: String) -> Data? {
        var str = s.replacingOccurrences(of: "-", with: "+")
                   .replacingOccurrences(of: "_", with: "/")
        while str.count % 4 != 0 { str.append("=") }
        return Data(base64Encoded: str)
    }
}
