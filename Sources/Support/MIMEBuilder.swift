import Foundation
import UniformTypeIdentifiers

/// An image pasted into a composed message body: referenced from the HTML by
/// `cid:` and carried as an inline-disposition MIME part (which most clients also
/// expose as a savable attachment). Distinct from `InlineImage`, which models the
/// inline images of a *received* message.
struct ComposeInlineImage: Identifiable, Hashable {
    let id: String        // unique token; doubles as the HTML src filename and Content-ID
    let mime: String      // e.g. "image/png"
    let data: Data
    var cid: String { id }
    var filename: String { id }
}

/// Builds RFC 5322 messages for Gmail's `messages.send`. Supports a rich HTML
/// body, inline images (multipart/related), and file attachments
/// (multipart/mixed); falls back to a single text/html part when there's neither.
enum MIMEBuilder {
    static func buildHTML(
        from: String,
        to: String,
        cc: String,
        subject: String,
        html: String,
        attachments: [URL],
        inlineImages: [ComposeInlineImage] = [],
        date: Date? = nil
    ) -> Data {
        var header: [String] = []
        if !from.isEmpty { header.append("From: \(from)") }
        header.append("To: \(to)")
        if !cc.isEmpty { header.append("Cc: \(cc)") }
        header.append("Subject: \(encodeHeader(subject))")
        // Preserve the original message's date when editing in place so the copy
        // sorts and displays identically (Gmail honors this via internalDateSource).
        if let date { header.append("Date: \(rfc5322Date(date))") }
        header.append("MIME-Version: 1.0")

        let body = html.isEmpty ? "<html><body></body></html>" : html

        // Read attachment data up front; skip any that can't be read.
        let readable: [(name: String, mime: String, data: Data)] = attachments.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return (url.lastPathComponent, mime, data)
        }

        // The HTML body as one MIME entity — a bare text/html part, or, when there
        // are inline images, a multipart/related bundling the HTML with them. The
        // returned lines start with the entity's own Content-Type header.
        func htmlEntity() -> [String] {
            guard !inlineImages.isEmpty else {
                return [
                    "Content-Type: text/html; charset=utf-8",
                    "Content-Transfer-Encoding: 8bit",
                    "",
                    body,
                ]
            }
            let relBoundary = "nm_rel_\(UUID().uuidString)"
            var lines = ["Content-Type: multipart/related; boundary=\"\(relBoundary)\"", ""]
            lines.append("--\(relBoundary)")
            lines.append("Content-Type: text/html; charset=utf-8")
            lines.append("Content-Transfer-Encoding: 8bit")
            lines.append("")
            lines.append(body)
            for img in inlineImages {
                let b64 = img.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
                lines.append("--\(relBoundary)")
                lines.append("Content-Type: \(img.mime); name=\"\(img.filename)\"")
                lines.append("Content-Transfer-Encoding: base64")
                lines.append("Content-ID: <\(img.cid)>")
                lines.append("Content-Disposition: inline; filename=\"\(img.filename)\"")
                lines.append("")
                lines.append(b64)
            }
            lines.append("--\(relBoundary)--")
            return lines
        }

        // No file attachments: the HTML entity is the whole message body.
        if readable.isEmpty {
            var lines = header
            lines.append(contentsOf: htmlEntity())
            return lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        }

        // File attachments present: wrap the HTML entity and the attachments in a
        // multipart/mixed.
        let boundary = "nm_\(UUID().uuidString)"
        header.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        header.append("")

        var lines: [String] = header
        lines.append("--\(boundary)")
        lines.append(contentsOf: htmlEntity())

        for att in readable {
            let b64 = att.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
            lines.append("--\(boundary)")
            lines.append("Content-Type: \(att.mime); name=\"\(att.name)\"")
            lines.append("Content-Transfer-Encoding: base64")
            lines.append("Content-Disposition: attachment; filename=\"\(att.name)\"")
            lines.append("")
            lines.append(b64)
        }
        lines.append("--\(boundary)--")
        return lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
    }

    /// Builds an RSVP email carrying an iCalendar REPLY (text/calendar;
    /// method=REPLY). Sent to the organizer; Gmail/Outlook process it to record
    /// the response and update the calendar.
    static func buildICSReply(from: String, to: String, subject: String, ics: String, note: String = "") -> Data {
        var lines: [String] = []
        if !from.isEmpty { lines.append("From: \(from)") }
        lines.append("To: \(to)")
        lines.append("Subject: \(encodeHeader(subject))")
        lines.append("MIME-Version: 1.0")

        if note.isEmpty {
            lines.append("Content-Type: text/calendar; charset=utf-8; method=REPLY")
            lines.append("Content-Transfer-Encoding: 8bit")
            lines.append("")
            lines.append(ics)
        } else {
            // Carry the organizer-visible note as a text/plain part alongside the
            // calendar REPLY (multipart/alternative).
            let boundary = "nm_\(UUID().uuidString)"
            lines.append("Content-Type: multipart/alternative; boundary=\"\(boundary)\"")
            lines.append("")
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("Content-Transfer-Encoding: 8bit")
            lines.append("")
            lines.append(note)
            lines.append("--\(boundary)")
            lines.append("Content-Type: text/calendar; charset=utf-8; method=REPLY")
            lines.append("Content-Transfer-Encoding: 8bit")
            lines.append("")
            lines.append(ics)
            lines.append("--\(boundary)--")
        }
        return lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
    }

    /// Pulls `data:` URI images out of an HTML body, returning the body with each
    /// such `<img>` src rewritten to a `cid:` reference plus the decoded images to
    /// send as multipart/related parts. Used when saving an edited message: the
    /// editor renders inline images as `data:` URIs, but re-embedding them as proper
    /// related parts keeps the stored message a normal, broadly-renderable email.
    /// Non-data sources (e.g. remote `https:` images) are left untouched.
    static func extractDataURIImages(from html: String) -> (html: String, images: [ComposeInlineImage]) {
        let pattern = "src\\s*=\\s*([\"'])data:(image/[^;,\"']+);base64,([^\"']*)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (html, [])
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (html, []) }

        var images: [ComposeInlineImage] = []
        var result = ""
        var lastEnd = 0
        for (index, match) in matches.enumerated() {
            result += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let mime = ns.substring(with: match.range(at: 2))
            let base64 = ns.substring(with: match.range(at: 3))
            if let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]) {
                let cid = "nm-edit-\(index)-\(UUID().uuidString)"
                images.append(ComposeInlineImage(id: cid, mime: mime, data: data))
                result += "src=\"cid:\(cid)\""
            } else {
                // Couldn't decode — leave the original src so nothing breaks.
                result += ns.substring(with: match.range)
            }
            lastEnd = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: lastEnd, length: ns.length - lastEnd))
        return (result, images)
    }

    /// RFC 5322 date header, e.g. "Mon, 22 Jun 2026 14:05:09 +0000".
    private static func rfc5322Date(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return f.string(from: date)
    }

    /// RFC 2047 encoded-word for non-ASCII subjects.
    private static func encodeHeader(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) { return value }
        let encoded = Data(value.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }
}
