import Foundation
import Network

/// Minimal IMAP client used for one job: appending a complete RFC822 message to
/// an Outlook.com folder (`IMAP APPEND`).
///
/// Microsoft Graph can't do this — creating a message from MIME always yields a
/// draft (`isDraft: true`, "This message hasn't been sent" banner) stamped with
/// the import time rather than the original received time, and Microsoft
/// documents no supported way around it. `APPEND` is the protocol's native
/// import: the exact original bytes, an explicit INTERNALDATE, and real
/// message flags, so a moved message is indistinguishable from a delivered one.
///
/// Authentication is OAuth (`AUTHENTICATE XOAUTH2`) with a token for the
/// `outlook.office.com` resource; basic auth is retired for Outlook.com.
struct OutlookIMAP {
    static let host = "outlook.office365.com"
    static let port: UInt16 = 993

    let email: String
    let accessToken: String

    /// Appends `raw` to the folder at `path` (slash-separated, e.g. "Archive" or
    /// "Work/Receipts"), dating it by the message's own `Date:` header so it
    /// sorts where it belongs, and marking it read unless `markUnread`.
    ///
    /// `kind` resolves the special folders, whose IMAP names differ from their
    /// Graph display names ("Deleted Items" is "Deleted" over IMAP, and so on).
    func append(raw: Data, path: String, kind: FolderKind, markUnread: Bool) async throws {
        let connection = try await IMAPConnection.connect(host: Self.host, port: Self.port)
        defer { connection.close() }

        // Greeting, then authenticate.
        _ = try await connection.readResponse(tag: nil)
        let credential = "user=\(email)\u{01}auth=Bearer \(accessToken)\u{01}\u{01}"
        let authLine = "AUTHENTICATE XOAUTH2 \(Data(credential.utf8).base64EncodedString())"
        try await connection.authenticate(authLine)

        let mailboxes = try await connection.list()
        let mailbox = try Self.resolveMailbox(path: path, kind: kind, in: mailboxes)

        let flags = markUnread ? "()" : "(\\Seen)"
        let date = Self.internalDate(for: raw)
        let command = "APPEND \(Self.quoted(mailbox)) \(flags) \"\(date)\" {\(raw.count)}"
        try await connection.appendLiteral(command: command, payload: raw)
        try? await connection.logout()
    }

    /// Picks the server's own name for the destination: an exact match on the
    /// encoded path, else the mailbox flagged with the matching SPECIAL-USE
    /// attribute (`\Sent`, `\Trash`, …). Matching the server's spelling rather
    /// than assuming one keeps non-ASCII (Hebrew) names working too, since both
    /// sides are compared in modified UTF-7.
    static func resolveMailbox(path: String, kind: FolderKind, in mailboxes: [IMAPMailbox]) throws -> String {
        let encoded = modifiedUTF7(path)
        if let exact = mailboxes.first(where: { $0.name.caseInsensitiveCompare(encoded) == .orderedSame }) {
            return exact.name
        }
        // The delimiter is "/" on Outlook.com, but honor whatever LIST reported.
        if let delimiter = mailboxes.first?.delimiter, delimiter != "/", delimiter != "" {
            let translated = encoded.replacingOccurrences(of: "/", with: delimiter)
            if let match = mailboxes.first(where: { $0.name.caseInsensitiveCompare(translated) == .orderedSame }) {
                return match.name
            }
        }
        // INBOX is the one mailbox IMAP names itself, case-insensitively.
        if kind == .inbox { return "INBOX" }
        if let attribute = specialUse(for: kind),
           let match = mailboxes.first(where: { $0.attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame } }) {
            return match.name
        }
        throw MailError.other("The folder “\(path)” wasn’t found on the Outlook server.")
    }

    private static func specialUse(for kind: FolderKind) -> String? {
        switch kind {
        case .sent: return "\\Sent"
        case .drafts: return "\\Drafts"
        case .trash: return "\\Trash"
        case .junk: return "\\Junk"
        case .archive: return "\\Archive"
        default: return nil
        }
    }

    // MARK: - Encoding helpers

    /// The `Date:` header, formatted as an IMAP INTERNALDATE. Falls back to now
    /// when the header is missing or unparseable (better than refusing the move).
    static func internalDate(for raw: Data) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MMM-yyyy HH:mm:ss Z"
        return formatter.string(from: dateHeader(in: raw) ?? Date())
    }

    /// The named top-level header's value. Only the header block is scanned, so a
    /// line that looks like a header inside the body is ignored.
    static func headerValue(_ name: String, in raw: Data) -> String? {
        // Headers are ASCII; decoding lossily is safe and avoids failing on a
        // body with invalid UTF-8.
        let text = String(decoding: raw.prefix(64 * 1024), as: UTF8.self)
        let prefix = name.lowercased() + ":"
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }  // end of the header block
            if line.lowercased().hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Parses the message's `Date:` header.
    static func dateHeader(in raw: Data) -> Date? {
        guard let value = headerValue("date", in: raw) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // With and without the day name, and with an obsolete zone name ("GMT")
        // instead of an offset — all appear in real mail.
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z",
                       "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz"] {
            formatter.dateFormat = format
            // A trailing comment like "(UTC)" is legal; drop it before parsing.
            let cleaned = value.replacingOccurrences(
                of: "\\s*\\(.*\\)\\s*$", with: "", options: .regularExpression
            )
            if let date = formatter.date(from: cleaned) { return date }
        }
        return nil
    }

    /// IMAP quoted-string: wraps in double quotes, escaping `\` and `"`.
    static func quoted(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Encodes a mailbox name as modified UTF-7 (RFC 3501 §5.1.3), which IMAP
    /// requires for non-ASCII folder names — e.g. Hebrew ones.
    static func modifiedUTF7(_ name: String) -> String {
        var out = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var bytes = Data()
            for unit in pending {
                bytes.append(UInt8(unit >> 8))
                bytes.append(UInt8(unit & 0xFF))
            }
            let b64 = bytes.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "/", with: ",")
            out += "&\(b64)-"
            pending.removeAll()
        }

        for unit in Array(name.utf16) {
            // Printable ASCII passes through; everything else is base64'd.
            if unit >= 0x20 && unit <= 0x7E {
                flush()
                out += unit == 0x26 ? "&-" : String(UnicodeScalar(UInt8(unit)))
            } else {
                pending.append(unit)
            }
        }
        flush()
        return out
    }
}

/// One `LIST` entry: the mailbox's name as the server spells it (still in
/// modified UTF-7), its hierarchy delimiter, and its attributes — including the
/// SPECIAL-USE ones (`\Sent`, `\Trash`, …) that identify the well-known folders.
struct IMAPMailbox {
    var attributes: [String]
    var delimiter: String
    var name: String
}

/// A TLS socket with just enough IMAP framing to run the append: read CRLF
/// lines, wait for a tagged completion, and stream one literal.
private final class IMAPConnection {
    private let connection: NWConnection
    private var buffer = Data()
    private var tagCounter = 0

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(host: String, port: UInt16) async throws -> IMAPConnection {
        let endpoint = NWEndpoint.Host(host)
        let connection = NWConnection(
            host: endpoint,
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tls
        )
        let client = IMAPConnection(connection: connection)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            connection.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    continuation.resume()
                case .failed(let error), .waiting(let error):
                    resumed = true
                    continuation.resume(throwing: MailError.other("IMAP connection failed: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        connection.stateUpdateHandler = nil
        return client
    }

    func close() {
        connection.cancel()
    }

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "n%03d", tagCounter)
    }

    // MARK: - Commands

    /// Runs `AUTHENTICATE XOAUTH2 …`. On failure the server sends a `+` challenge
    /// carrying the error JSON and waits for an empty line before reporting the
    /// tagged NO, so answer it rather than hanging.
    func authenticate(_ command: String) async throws {
        let tag = nextTag()
        try await send(Data("\(tag) \(command)\r\n".utf8))
        let response = try await readResponse(tag: tag, allowContinuation: true)
        if response.hasPrefix("+") {
            try await send(Data("\r\n".utf8))
            let final = try await readResponse(tag: tag)
            throw MailError.auth("Outlook IMAP rejected the sign-in: \(Self.detail(final))")
        }
        guard Self.isOK(response, tag: tag) else {
            throw MailError.auth("Outlook IMAP rejected the sign-in: \(Self.detail(response))")
        }
    }

    /// Runs `LIST "" "*"` and collects the untagged replies.
    func list() async throws -> [IMAPMailbox] {
        let tag = nextTag()
        try await send(Data("\(tag) LIST \"\" \"*\"\r\n".utf8))
        var mailboxes: [IMAPMailbox] = []
        while true {
            let line = try await readLine()
            if line.hasPrefix(tag + " ") {
                guard Self.isOK(line, tag: tag) else {
                    throw MailError.other("Outlook IMAP couldn’t list folders: \(Self.detail(line))")
                }
                return mailboxes
            }
            if let mailbox = Self.parseListLine(line) { mailboxes.append(mailbox) }
        }
    }

    /// Parses `* LIST (\HasNoChildren \Sent) "/" "Sent"`. Returns nil for any
    /// other untagged line.
    static func parseListLine(_ line: String) -> IMAPMailbox? {
        guard line.hasPrefix("* LIST ") else { return nil }
        var rest = Substring(line.dropFirst("* LIST ".count))
        guard rest.first == "(", let close = rest.firstIndex(of: ")") else { return nil }
        let attributes = rest[rest.index(after: rest.startIndex)..<close]
            .split(separator: " ").map(String.init)

        rest = rest[rest.index(after: close)...].drop(while: { $0 == " " })
        let (delimiter, afterDelimiter) = takeToken(rest)
        let (name, _) = takeToken(afterDelimiter.drop(while: { $0 == " " }))
        guard let name, !name.isEmpty else { return nil }
        return IMAPMailbox(attributes: attributes,
                           delimiter: (delimiter == "NIL" ? "" : delimiter) ?? "",
                           name: name)
    }

    /// Reads one quoted string (unescaping `\"` and `\\`) or, failing that, the
    /// bare atom up to the next space, and returns the remainder of the line.
    private static func takeToken(_ input: Substring) -> (String?, Substring) {
        guard let first = input.first else { return (nil, input) }
        guard first == "\"" else {
            let atom = input.prefix(while: { $0 != " " })
            return (String(atom), input[atom.endIndex...])
        }
        var value = ""
        var index = input.index(after: input.startIndex)
        while index < input.endIndex {
            let character = input[index]
            if character == "\\", input.index(after: index) < input.endIndex {
                index = input.index(after: index)
                value.append(input[index])
            } else if character == "\"" {
                return (value, input[input.index(after: index)...])
            } else {
                value.append(character)
            }
            index = input.index(after: index)
        }
        return (nil, input)
    }

    /// Sends a command ending in a literal (`{n}`), waits for the server's `+`
    /// continuation, then writes the payload.
    func appendLiteral(command: String, payload: Data) async throws {
        let tag = nextTag()
        try await send(Data("\(tag) \(command)\r\n".utf8))
        let ready = try await readResponse(tag: tag, allowContinuation: true)
        guard ready.hasPrefix("+") else {
            throw MailError.other("Outlook IMAP refused the message: \(Self.detail(ready))")
        }
        var body = payload
        body.append(Data("\r\n".utf8))
        try await send(body)
        let result = try await readResponse(tag: tag)
        guard Self.isOK(result, tag: tag) else {
            throw MailError.other("Outlook IMAP refused the message: \(Self.detail(result))")
        }
    }

    func logout() async throws {
        let tag = nextTag()
        try await send(Data("\(tag) LOGOUT\r\n".utf8))
        _ = try await readResponse(tag: tag)
    }

    // MARK: - Framing

    /// Reads lines until the one that completes the command: the tagged line
    /// (`n001 OK …`), a `+` continuation when `allowContinuation`, or — with no
    /// tag — the greeting. Untagged `*` lines in between are skipped.
    func readResponse(tag: String?, allowContinuation: Bool = false) async throws -> String {
        while true {
            let line = try await readLine()
            if line.hasPrefix("+") {
                if allowContinuation { return line }
                continue
            }
            if let tag {
                if line.hasPrefix(tag + " ") { return line }
            } else {
                return line  // greeting
            }
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = try await receive()
            guard !chunk.isEmpty else {
                throw MailError.other("Outlook IMAP closed the connection unexpectedly.")
            }
            buffer.append(chunk)
        }
    }

    private func receive() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: MailError.other("IMAP read failed: \(error.localizedDescription)"))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MailError.other("IMAP write failed: \(error.localizedDescription)"))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func isOK(_ line: String, tag: String) -> Bool {
        line.hasPrefix("\(tag) OK")
    }

    /// The human-readable remainder of a tagged NO/BAD line.
    private static func detail(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        return parts.count > 2 ? String(parts[2]) : line
    }
}
