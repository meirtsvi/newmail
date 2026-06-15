import Foundation

/// Microsoft Graph v1.0 mail client. Maps Graph's real `mailFolders` tree onto
/// the app's folder abstraction. Tokens come from `GraphAuth` (MSAL); write
/// operations work as long as the account granted `Mail.ReadWrite` / `Mail.Send`.
final class GraphProvider: MailProvider {
    private let base = URL(string: "https://graph.microsoft.com/v1.0/me")!
    private let auth: GraphAuth
    private let homeAccountId: String
    let accountId: String
    private(set) var accountEmail: String

    init(account: MailAccount, auth: GraphAuth) {
        self.auth = auth
        self.homeAccountId = account.externalId
        self.accountId = account.id
        self.accountEmail = account.email
    }

    // MARK: - HTTP

    private func token() async throws -> String {
        try await auth.accessToken(homeAccountId: homeAccountId)
    }

    /// Issues a Graph request. Pass `absoluteURL` to follow an `@odata.nextLink`
    /// (then `path`/`query` are ignored). Use `rawBody` for non-JSON bodies
    /// (e.g. base64 MIME on send).
    @discardableResult
    private func request(
        _ path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        jsonBody: Data? = nil,
        rawBody: Data? = nil,
        contentType: String? = nil,
        absoluteURL: URL? = nil
    ) async throws -> Data {
        let url: URL
        if let absoluteURL {
            url = absoluteURL
        } else {
            var comps = URLComponents(
                url: path.isEmpty ? base : base.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )!
            if !query.isEmpty { comps.queryItems = query }
            url = comps.url!
        }

        let maxAttempts = 4
        var attempt = 0
        while true {
            attempt += 1
            var req = URLRequest(url: url)
            req.httpMethod = method
            let tok = try await token()
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            if let jsonBody {
                req.httpBody = jsonBody
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if let rawBody {
                req.httpBody = rawBody
                req.setValue(contentType ?? "text/plain", forHTTPHeaderField: "Content-Type")
            }

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw MailError.other("No HTTP response")
                }
                if (200..<300).contains(http.statusCode) { return data }

                // Graph throttling/transient gateway errors. Retry GETs freely;
                // for writes only retry 429 (the request definitely wasn't
                // processed) so a timed-out send/move is never duplicated.
                let transient = [429, 503, 504].contains(http.statusCode)
                let safeToRetry = method == "GET" || http.statusCode == 429
                if transient && safeToRetry && attempt < maxAttempts {
                    try await Task.sleep(nanoseconds: Self.retryDelay(http, attempt: attempt))
                    continue
                }
                throw MailError.api(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            } catch let urlError as URLError where method == "GET"
                && attempt < maxAttempts && Self.isTransient(urlError) {
                try await Task.sleep(nanoseconds: Self.backoff(attempt))
                continue
            }
        }
    }

    /// Honors a `Retry-After` header (seconds) when present, else exponential backoff.
    private static func retryDelay(_ http: HTTPURLResponse, attempt: Int) -> UInt64 {
        if let header = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header), seconds > 0 {
            return UInt64(min(seconds, 30) * 1_000_000_000)
        }
        return backoff(attempt)
    }

    /// 0.5s, 1s, 2s … exponential backoff.
    private static func backoff(_ attempt: Int) -> UInt64 {
        UInt64(0.5 * pow(2.0, Double(attempt - 1)) * 1_000_000_000)
    }

    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    // MARK: - Profile

    func loadProfile() async throws {
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "$select", value: "mail,userPrincipalName,displayName")]
        let data = try await request("", absoluteURL: comps.url!)
        let user = try JSONDecoder().decode(GraphAPI.User.self, from: data)
        accountEmail = user.mail ?? user.userPrincipalName ?? accountEmail
    }

    // MARK: - Folders

    func listFolders() async throws -> [MailFolder] {
        var result: [MailFolder] = []
        try await appendFolders(endpoint: "mailFolders", pathPrefix: "", into: &result)
        return result.sorted { a, b in
            if a.kind.sortWeight != b.kind.sortWeight { return a.kind.sortWeight < b.kind.sortWeight }
            return a.path.localizedCaseInsensitiveCompare(b.path) == .orderedAscending
        }
    }

    private func appendFolders(
        endpoint: String,
        pathPrefix: String,
        into result: inout [MailFolder]
    ) async throws {
        var nextURL: URL? = nil
        repeat {
            let data: Data
            if let nextURL {
                data = try await request("", absoluteURL: nextURL)
            } else {
                data = try await request(endpoint, query: [
                    URLQueryItem(name: "$top", value: "100"),
                    // `wellKnownName` is beta-only; v1.0 rejects it. Kind is
                    // derived from displayName instead (see `kind(for:)`).
                    URLQueryItem(name: "$select",
                                 value: "id,displayName,parentFolderId,childFolderCount,unreadItemCount,totalItemCount"),
                ])
            }
            let list = try JSONDecoder().decode(GraphAPI.MailFolderList.self, from: data)
            for f in list.value {
                let path = pathPrefix.isEmpty ? f.displayName : pathPrefix + "/" + f.displayName
                result.append(MailFolder(
                    id: f.id,
                    name: f.displayName,
                    kind: Self.kind(for: f),
                    unreadCount: f.unreadItemCount ?? 0,
                    totalCount: f.totalItemCount ?? 0,
                    path: path,
                    accountId: accountId
                ))
                if (f.childFolderCount ?? 0) > 0 {
                    try await appendFolders(
                        endpoint: "mailFolders/\(f.id)/childFolders",
                        pathPrefix: path,
                        into: &result
                    )
                }
            }
            nextURL = list.nextLink.flatMap { URL(string: $0) }
        } while nextURL != nil
    }

    func folderCount(id: String) async throws -> (unread: Int, total: Int) {
        let data = try await request("mailFolders/\(id)", query: [
            URLQueryItem(name: "$select", value: "unreadItemCount,totalItemCount")
        ])
        let f = try JSONDecoder().decode(GraphAPI.MailFolder.self, from: data)
        return (f.unreadItemCount ?? 0, f.totalItemCount ?? 0)
    }

    func ensureFolder(named name: String) async throws -> String {
        let data = try await request("mailFolders", query: [
            URLQueryItem(name: "$filter", value: "displayName eq '\(name)'")
        ])
        let list = try JSONDecoder().decode(GraphAPI.MailFolderList.self, from: data)
        if let existing = list.value.first { return existing.id }

        let body = try JSONSerialization.data(withJSONObject: ["displayName": name])
        let created = try await request("mailFolders", method: "POST", jsonBody: body)
        return try JSONDecoder().decode(GraphAPI.MailFolder.self, from: created).id
    }

    // MARK: - Listing & search

    private static let messageSelect =
        "id,conversationId,subject,bodyPreview,receivedDateTime,isRead,hasAttachments,from,toRecipients,flag,parentFolderId"

    func listMessages(
        folderId: String,
        query: String?,
        pageToken: String?
    ) async throws -> (headers: [MessageHeader], nextPageToken: String?) {
        if let pageToken, let url = URL(string: pageToken) {
            return try await fetchMessagePage(absoluteURL: url)
        }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "$top", value: "50"),
            URLQueryItem(name: "$select", value: Self.messageSelect),
        ]
        if let query, !query.isEmpty {
            // $search and $orderby cannot be combined on Graph.
            items.append(URLQueryItem(name: "$search", value: "\"\(query)\""))
        } else {
            items.append(URLQueryItem(name: "$orderby", value: "receivedDateTime desc"))
        }
        let data = try await request("mailFolders/\(folderId)/messages", query: items)
        return try decodeMessagePage(data)
    }

    func search(
        query: String,
        pageToken: String?
    ) async throws -> (headers: [MessageHeader], nextPageToken: String?) {
        if let pageToken, let url = URL(string: pageToken) {
            return try await fetchMessagePage(absoluteURL: url)
        }
        let data = try await request("messages", query: [
            URLQueryItem(name: "$top", value: "50"),
            URLQueryItem(name: "$select", value: Self.messageSelect),
            URLQueryItem(name: "$search", value: "\"\(query)\""),
        ])
        return try decodeMessagePage(data)
    }

    private func fetchMessagePage(absoluteURL: URL) async throws -> (headers: [MessageHeader], nextPageToken: String?) {
        let data = try await request("", absoluteURL: absoluteURL)
        return try decodeMessagePage(data)
    }

    private func decodeMessagePage(_ data: Data) throws -> (headers: [MessageHeader], nextPageToken: String?) {
        let list = try JSONDecoder().decode(GraphAPI.MessageList.self, from: data)
        return (list.value.map { Self.header(from: $0, accountId: accountId) }, list.nextLink)
    }

    // MARK: - Body

    func fetchBody(id: String) async throws -> MessageBody {
        let data = try await request("messages/\(id)", query: [
            URLQueryItem(name: "$select", value: "id,body,bodyPreview,hasAttachments")
        ])
        let msg = try JSONDecoder().decode(GraphAPI.Message.self, from: data)
        let contentType = (msg.body?.contentType ?? "").lowercased()
        let content = msg.body?.content ?? ""

        let rawHTML = contentType == "html" ? content : ""
        let plain = contentType == "html" ? (msg.bodyPreview ?? "") : content

        var attachments: [MailAttachment] = []
        var images: [InlineImage] = []
        if msg.hasAttachments == true {
            let aData = try await request("messages/\(id)/attachments", query: [
                URLQueryItem(name: "$select", value: "id,name,contentType,size,isInline,contentId")
            ])
            let list = try JSONDecoder().decode(GraphAPI.AttachmentList.self, from: aData)
            for att in list.value {
                let mime = att.contentType ?? "application/octet-stream"
                if mime.lowercased().hasPrefix("image/"), let bytes = try? await fetchAttachment(messageId: id, attachmentId: att.id) {
                    // Inline (cid:) and standalone images both get embedded/previewed.
                    let cid = att.contentId?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
                    images.append(InlineImage(
                        cid: (cid?.isEmpty ?? true) ? nil : cid,
                        mime: mime, data: bytes, filename: att.name ?? "image", attachmentId: att.id
                    ))
                } else if !(att.isInline ?? false) {
                    attachments.append(MailAttachment(
                        id: att.id, messageId: id, filename: att.name ?? "attachment",
                        mimeType: mime, sizeBytes: att.size ?? 0
                    ))
                }
            }
        }
        let assembled = BodyHTML.assemble(rawHTML: rawHTML, plainText: plain, images: images, messageId: id)
        return MessageBody(headerId: id, html: assembled.html, plainText: plain,
                           attachments: attachments + assembled.imageAttachments)
    }

    func fetchAttachment(messageId: String, attachmentId: String) async throws -> Data {
        let data = try await request("messages/\(messageId)/attachments/\(attachmentId)")
        struct FileAttachment: Codable { var contentBytes: String? }
        let att = try JSONDecoder().decode(FileAttachment.self, from: data)
        guard let b64 = att.contentBytes, let bytes = Data(base64Encoded: b64) else {
            throw MailError.other("Attachment is unavailable.")
        }
        return bytes
    }

    /// Casts the folder's message collection to the `eventMessage` derived type, so
    /// the server returns only meeting requests/cancellations/responses — no body fetch.
    func calendarInviteIds(folderId: String) async throws -> Set<String> {
        var ids: Set<String> = []
        var nextURL: URL? = nil
        repeat {
            let data: Data
            if let nextURL {
                data = try await request("", absoluteURL: nextURL)
            } else {
                data = try await request("mailFolders/\(folderId)/messages/microsoft.graph.eventMessage", query: [
                    URLQueryItem(name: "$select", value: "id"),
                    URLQueryItem(name: "$top", value: "100"),
                ])
            }
            let list = try JSONDecoder().decode(GraphAPI.MessageList.self, from: data)
            ids.formUnion(list.value.map(\.id))
            nextURL = list.nextLink.flatMap { URL(string: $0) }
        } while nextURL != nil
        return ids
    }

    // MARK: - Mutations

    func setRead(ids: [String], read: Bool) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["isRead": read])
        for id in ids {
            try await request("messages/\(id)", method: "PATCH", jsonBody: body)
        }
    }

    func setFlagged(ids: [String], flagged: Bool) async throws {
        let status = flagged ? "flagged" : "notFlagged"
        let body = try JSONSerialization.data(withJSONObject: ["flag": ["flagStatus": status]])
        for id in ids {
            try await request("messages/\(id)", method: "PATCH", jsonBody: body)
        }
    }

    func trash(ids: [String]) async throws {
        try await moveAll(ids: ids, to: "deleteditems")
    }

    func archive(ids: [String]) async throws {
        try await moveAll(ids: ids, to: "archive")
    }

    func move(ids: [String], toFolderId: String, fromFolderId: String?) async throws {
        try await moveAll(ids: ids, to: toFolderId)
    }

    func markNotSpam(ids: [String]) async throws {
        try await moveAll(ids: ids, to: "inbox")
    }

    private func moveAll(ids: [String], to destination: String) async throws {
        guard !ids.isEmpty else { return }
        let body = try JSONSerialization.data(withJSONObject: ["destinationId": destination])
        for id in ids {
            try await request("messages/\(id)/move", method: "POST", jsonBody: body)
        }
    }

    // MARK: - Sending

    func send(rawMIME: Data) async throws {
        // Create a draft from the MIME, then send it (reuses the shared MIMEBuilder).
        let base64 = rawMIME.base64EncodedData()
        let created = try await request("messages", method: "POST", rawBody: base64, contentType: "text/plain")
        let msg = try JSONDecoder().decode(GraphAPI.Message.self, from: created)
        try await request("messages/\(msg.id)/send", method: "POST")
    }

    // MARK: - Mapping helpers

    private static func kind(for f: GraphAPI.MailFolder) -> FolderKind {
        switch (f.wellKnownName ?? "").lowercased() {
        case "inbox": return .inbox
        case "sentitems": return .sent
        case "drafts": return .drafts
        case "deleteditems": return .trash
        case "junkemail": return .junk
        case "archive": return .archive
        default: break
        }
        switch f.displayName.lowercased() {
        case "inbox": return .inbox
        case "sent items", "sent": return .sent
        case "drafts": return .drafts
        case "deleted items", "trash": return .trash
        case "junk email", "junk", "spam": return .junk
        case "archive": return .archive
        case "snoozed": return .snoozed
        default: return .custom
        }
    }

    private static func header(from m: GraphAPI.Message, accountId: String) -> MessageHeader {
        let from = address(m.from?.emailAddress ?? m.sender?.emailAddress)
        let to = (m.toRecipients ?? []).map { address($0.emailAddress) }
        let flagged = (m.flag?.flagStatus ?? "").lowercased() == "flagged"
        // Carry the parent folder id as a "label" so the offline cache can scope
        // headers to a folder the same way it does for Gmail labels.
        let labels = [m.parentFolderId].compactMap { $0 }
        return MessageHeader(
            id: m.id,
            threadId: m.conversationId ?? m.id,
            from: from,
            to: to,
            subject: m.subject ?? "(no subject)",
            snippet: m.bodyPreview ?? "",
            date: parseDate(m.receivedDateTime),
            isRead: m.isRead ?? false,
            isFlagged: flagged,
            hasAttachments: m.hasAttachments ?? false,
            labelIds: labels,
            accountId: accountId
        )
    }

    private static func address(_ e: GraphAPI.EmailAddress?) -> MailAddress {
        MailAddress(name: e?.name ?? "", email: e?.address ?? "")
    }

    private static func parseDate(_ s: String?) -> Date {
        guard let s else { return Date() }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s) ?? Date()
    }
}
