import Foundation

// MARK: - Errors

enum MailError: LocalizedError {
    case auth(String)
    case api(Int, String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .auth(let m): return "Authentication error: \(m)"
        case .api(let code, let body):
            if code == 403 {
                return "Permission denied (403): \(body.prefix(300))"
            }
            return "API error \(code): \(body.prefix(300))"
        case .other(let m): return m
        }
    }
}

// MARK: - Addresses

struct MailAddress: Hashable, Identifiable {
    var name: String
    var email: String

    var id: String { email.isEmpty ? name : email }
    var display: String { name.isEmpty ? email : name }

    /// "Name <email>" when both are present; falls back to whichever exists.
    var nameAndEmail: String {
        if name.isEmpty { return email }
        if email.isEmpty { return name }
        return "\(name) <\(email)>"
    }

    var initials: String {
        let base = name.isEmpty ? email : name
        let parts = base.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
        if let a = parts.first?.first, parts.count >= 2, let b = parts.dropFirst().first?.first {
            return "\(a)\(b)".uppercased()
        }
        return String(base.prefix(2)).uppercased()
    }

    /// Parses an RFC 5322 address such as `Name <user@host>` or a bare `user@host`.
    static func parse(_ raw: String) -> MailAddress {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let lt = s.firstIndex(of: "<"), let gt = s.lastIndex(of: ">"), lt < gt {
            let name = String(s[..<lt])
                .trimmingCharacters(in: CharacterSet(charactersIn: " \""))
                .trimmingCharacters(in: .whitespaces)
            let email = String(s[s.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            return MailAddress(name: name, email: email)
        }
        return MailAddress(name: "", email: s)
    }

    /// Splits a recipient-list header into individual addresses, breaking only on
    /// top-level commas. Commas inside a quoted display name (the common Exchange
    /// `"Last, First" <user@host>` form) or inside the angle-bracketed address are
    /// kept with their entry. Empty entries (e.g. from a trailing comma) are dropped.
    static func parseList(_ raw: String) -> [MailAddress] {
        var entries: [String] = []
        var current = ""
        var inQuote = false
        var inAngle = false
        for ch in raw {
            switch ch {
            case "\"":
                inQuote.toggle()
                current.append(ch)
            case "<" where !inQuote:
                inAngle = true
                current.append(ch)
            case ">" where !inQuote:
                inAngle = false
                current.append(ch)
            case "," where !inQuote && !inAngle:
                entries.append(current)
                current = ""
            default:
                current.append(ch)
            }
        }
        entries.append(current)
        return entries
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map(parse)
    }
}

// MARK: - Folders

enum FolderKind: String, Hashable {
    case inbox, sent, drafts, trash, junk, archive, snoozed, starred, important, custom

    var icon: String {
        switch self {
        case .inbox: return "tray"
        case .sent: return "paperplane"
        case .drafts: return "doc"
        case .trash: return "trash"
        case .junk: return "xmark.bin"
        case .archive: return "archivebox"
        case .snoozed: return "clock"
        case .starred: return "star"
        case .important: return "exclamationmark"
        case .custom: return "folder"
        }
    }

    /// Sidebar ordering weight (lower = higher in list).
    var sortWeight: Int {
        switch self {
        case .inbox: return 0
        case .snoozed: return 1
        case .sent: return 2
        case .drafts: return 3
        case .archive: return 4
        case .junk: return 5
        case .trash: return 6
        case .starred: return 7
        case .important: return 8
        case .custom: return 9
        }
    }
}

struct MailFolder: Identifiable, Hashable {
    var id: String          // provider label/folder id
    var name: String        // leaf display name
    var kind: FolderKind
    var unreadCount: Int = 0
    var totalCount: Int = 0
    /// Full hierarchical path, e.g. "Work/Receipts" (slash-separated). Defaults
    /// to the leaf name for non-nested folders.
    var path: String = ""
    var accountId: String = ""

    var pathComponents: [String] {
        let p = path.isEmpty ? name : path
        return p.split(separator: "/").map(String.init)
    }

    /// Unique across accounts (a folder id like "INBOX" can repeat per account).
    var compositeId: String { "\(accountId)\u{1}\(id)" }
}

// MARK: - Messages

struct MessageHeader: Identifiable, Hashable {
    var id: String
    var threadId: String
    var from: MailAddress
    var to: [MailAddress]
    var subject: String
    var snippet: String
    var date: Date
    var isRead: Bool
    var isFlagged: Bool
    var hasAttachments: Bool
    var labelIds: [String]
    var accountId: String = ""
    /// Whether this message is a calendar invitation. Derived at runtime from the
    /// view model's invite set (not from the provider), so the column can sort.
    var isCalendarEvent: Bool = false
    /// Whether this message carries the Newsletter category label. Mirrored from
    /// `labelIds` by the view model (which knows each account's label id), so the
    /// Category column can render and sort on it.
    var isNewsletter: Bool = false

    // Comparable sort keys for boolean columns (Bool isn't Comparable).
    var readSort: Int { isRead ? 1 : 0 }
    var flagSort: Int { isFlagged ? 1 : 0 }
    var attachmentSort: Int { hasAttachments ? 1 : 0 }
    /// Category column sort key: regular < newsletter < calendar event.
    var categorySort: Int { isCalendarEvent ? 2 : (isNewsletter ? 1 : 0) }
}

// MARK: - Newsletter category

enum NewsletterCategory {
    /// Name of the Gmail user label backing the category (created on first use).
    static let labelName = "Newsletter"
}

struct MailAttachment: Identifiable, Hashable, Codable {
    var id: String          // attachmentId
    var messageId: String
    var filename: String
    var mimeType: String
    var sizeBytes: Int
}

struct MessageBody {
    var headerId: String
    var html: String
    var plainText: String
    var attachments: [MailAttachment]
    /// Cc recipients, parsed from the message headers at body-fetch time (the
    /// To list lives on `MessageHeader`; Cc isn't carried in the list metadata).
    var cc: [MailAddress] = []
    /// A calendar invitation parsed from a `text/calendar` part, if present.
    var calendar: CalendarInvite? = nil
    /// Mailing-list unsubscribe targets, when the message advertises them.
    /// Not persisted in the body cache; repopulated on each fresh fetch.
    var unsubscribe: UnsubscribeInfo? = nil
}

// MARK: - Unsubscribe

/// Parsed `List-Unsubscribe` / `List-Unsubscribe-Post` headers (RFC 2369/8058),
/// powering a Gmail-style Unsubscribe button.
struct UnsubscribeInfo: Hashable {
    /// `mailto:` target — unsubscribe by sending a message.
    var mailto: URL?
    /// Web (https) target — unsubscribe via the sender's page.
    var web: URL?
    /// RFC 8058 one-click: POSTing `List-Unsubscribe=One-Click` to `web`
    /// unsubscribes without a browser visit.
    var oneClick = false

    /// Parses the raw header values; nil when there's no usable target.
    static func parse(listUnsubscribe: String?, listUnsubscribePost: String?) -> UnsubscribeInfo? {
        guard let raw = listUnsubscribe else { return nil }
        var info = UnsubscribeInfo()
        // The header is a comma-separated list of <uri> entries, e.g.
        // "<mailto:leave@list.example.com>, <https://example.com/unsub?u=1>".
        for entry in raw.split(separator: ",") {
            let uri = entry.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n<>"))
            guard let url = URL(string: uri), let scheme = url.scheme?.lowercased() else { continue }
            if scheme == "mailto", info.mailto == nil { info.mailto = url }
            if scheme == "https" || scheme == "http", info.web == nil { info.web = url }
        }
        guard info.mailto != nil || info.web != nil else { return nil }
        info.oneClick = info.web != nil
            && listUnsubscribePost?.range(of: "One-Click", options: .caseInsensitive) != nil
        return info
    }
}

// MARK: - Search

enum SearchScope: String, CaseIterable, Identifiable {
    case currentFolder = "Current folder"
    case allFolders = "All folders"
    var id: String { rawValue }
}

// MARK: - Date formatting (matches the reference UI)

extension Date {
    var mailListString: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) {
            return formatted(date: .omitted, time: .shortened)
        }
        if cal.isDateInYesterday(self) {
            return "Yesterday"
        }
        if let days = cal.dateComponents([.day], from: self, to: Date()).day, days < 7 {
            return formatted(.dateTime.weekday(.wide))
        }
        return formatted(.dateTime.month(.abbreviated).day().year())
    }

    var mailFullString: String {
        formatted(date: .abbreviated, time: .shortened)
    }
}

extension CharacterSet {
    /// Allowed characters for a value in application/x-www-form-urlencoded.
    static let formValueAllowed: CharacterSet = {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return cs
    }()
}
