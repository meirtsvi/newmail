import Foundation
import UniformTypeIdentifiers

/// Builds RFC 5322 messages for Gmail's `messages.send`. Supports a rich HTML
/// body and file attachments (multipart/mixed); falls back to a single
/// text/html part when there are no attachments.
enum MIMEBuilder {
    static func buildHTML(
        from: String,
        to: String,
        cc: String,
        subject: String,
        html: String,
        attachments: [URL]
    ) -> Data {
        var header: [String] = []
        if !from.isEmpty { header.append("From: \(from)") }
        header.append("To: \(to)")
        if !cc.isEmpty { header.append("Cc: \(cc)") }
        header.append("Subject: \(encodeHeader(subject))")
        header.append("MIME-Version: 1.0")

        let body = html.isEmpty ? "<html><body></body></html>" : html

        // Read attachment data up front; skip any that can't be read.
        let readable: [(name: String, mime: String, data: Data)] = attachments.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            return (url.lastPathComponent, mime, data)
        }

        if readable.isEmpty {
            header.append("Content-Type: text/html; charset=utf-8")
            header.append("Content-Transfer-Encoding: 8bit")
            header.append("")
            header.append(body)
            return header.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        }

        let boundary = "nm_\(UUID().uuidString)"
        header.append("Content-Type: multipart/mixed; boundary=\"\(boundary)\"")
        header.append("")

        var lines: [String] = header
        lines.append("--\(boundary)")
        lines.append("Content-Type: text/html; charset=utf-8")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("")
        lines.append(body)

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
    static func buildICSReply(from: String, to: String, subject: String, ics: String) -> Data {
        var lines: [String] = []
        if !from.isEmpty { lines.append("From: \(from)") }
        lines.append("To: \(to)")
        lines.append("Subject: \(encodeHeader(subject))")
        lines.append("MIME-Version: 1.0")
        lines.append("Content-Type: text/calendar; charset=utf-8; method=REPLY")
        lines.append("Content-Transfer-Encoding: 8bit")
        lines.append("")
        lines.append(ics)
        return lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
    }

    /// RFC 2047 encoded-word for non-ASCII subjects.
    private static func encodeHeader(_ value: String) -> String {
        if value.allSatisfy({ $0.isASCII }) { return value }
        let encoded = Data(value.utf8).base64EncodedString()
        return "=?UTF-8?B?\(encoded)?="
    }
}
