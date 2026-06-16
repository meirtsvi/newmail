import Foundation

// MARK: - Model

/// A calendar invitation parsed from a message's `text/calendar` part.
struct CalendarInvite: Hashable {
    enum Method: String {
        case request = "REQUEST"   // an invitation asking for a response
        case cancel  = "CANCEL"    // the organizer canceled the event
        case reply   = "REPLY"
        case publish = "PUBLISH"
        case other   = "OTHER"
    }

    var method: Method
    var uid: String
    var summary: String
    var location: String
    var details: String
    var start: Date?
    var end: Date?
    var isAllDay: Bool
    var organizer: MailAddress?
    var attendees: [MailAddress]
    var sequence: String

    /// Original property lines we echo verbatim into a REPLY (RFC 5546).
    var organizerLine: String?
    var dtStartLine: String?
    var dtEndLine: String?

    /// A friendly date/time range for the preview card.
    var whenText: String {
        guard let start else { return "" }
        if isAllDay {
            let day = start.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
            return "\(day) · All day"
        }
        let dayTime = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        if let end {
            let sameDay = Calendar.current.isDate(start, inSameDayAs: end)
            let endText = sameDay
                ? end.formatted(.dateTime.hour().minute())
                : end.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            return "\(dayTime) – \(endText)"
        }
        return dayTime
    }
}

/// The user's response to an invitation (maps to iCalendar PARTSTAT).
enum InviteResponse: String {
    case accepted  = "ACCEPTED"
    case tentative = "TENTATIVE"
    case declined  = "DECLINED"

    var subjectPrefix: String {
        switch self {
        case .accepted:  return "Accepted"
        case .tentative: return "Tentative"
        case .declined:  return "Declined"
        }
    }
}

// MARK: - Parser

/// A small, forgiving RFC 5545 reader — enough to surface and respond to the
/// VEVENT in a mail invitation (we don't need a full calendar engine).
enum ICSParser {
    static func parse(_ ics: String) -> CalendarInvite? {
        let lines = unfold(ics)
        var method = "OTHER"
        var inEvent = false

        var uid = "", summary = "", location = "", details = "", sequence = "0"
        var start: Date?, end: Date?, allDay = false
        var durationSeconds: TimeInterval?
        var organizer: MailAddress?, organizerLine: String?
        var dtStartLine: String?, dtEndLine: String?
        var attendees: [MailAddress] = []
        var sawEvent = false

        for line in lines {
            let (name, params, value) = parseLine(line)
            switch name {
            case "METHOD" where !inEvent:
                method = value.uppercased()
            case "BEGIN" where value.uppercased() == "VEVENT":
                inEvent = true; sawEvent = true
            case "END" where value.uppercased() == "VEVENT":
                inEvent = false
            case "UID" where inEvent:
                uid = value
            case "SUMMARY" where inEvent:
                summary = unescapeText(value)
            case "LOCATION" where inEvent:
                location = unescapeText(value)
            case "DESCRIPTION" where inEvent:
                details = unescapeText(value)
            case "SEQUENCE" where inEvent:
                sequence = value
            case "DTSTART" where inEvent:
                let parsed = parseDate(value: value, params: params)
                start = parsed.date; allDay = parsed.allDay; dtStartLine = line
            case "DTEND" where inEvent:
                end = parseDate(value: value, params: params).date; dtEndLine = line
            case "DURATION" where inEvent:
                durationSeconds = parseDuration(value)
            case "ORGANIZER" where inEvent:
                organizer = address(value: value, params: params); organizerLine = line
            case "ATTENDEE" where inEvent:
                if let a = address(value: value, params: params) { attendees.append(a) }
            default:
                break
            }
        }

        // RFC 5545 allows DURATION in place of DTEND; derive the end so the
        // timeline hatch spans the meeting's full length rather than a guessed default.
        if end == nil, let s = start, let dur = durationSeconds {
            end = s.addingTimeInterval(dur)
        }

        guard sawEvent else { return nil }
        return CalendarInvite(
            method: CalendarInvite.Method(rawValue: method) ?? .other,
            uid: uid, summary: summary.isEmpty ? "(no title)" : summary,
            location: location, details: details,
            start: start, end: end, isAllDay: allDay,
            organizer: organizer, attendees: attendees, sequence: sequence,
            organizerLine: organizerLine, dtStartLine: dtStartLine, dtEndLine: dtEndLine
        )
    }

    /// Joins RFC 5545 folded lines (a continuation starts with a space or tab).
    private static func unfold(_ ics: String) -> [String] {
        let raw = ics.replacingOccurrences(of: "\r\n", with: "\n")
                     .replacingOccurrences(of: "\r", with: "\n")
                     .components(separatedBy: "\n")
        var out: [String] = []
        for line in raw {
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1] += line.dropFirst()
            } else {
                out.append(line)
            }
        }
        return out.filter { !$0.isEmpty }
    }

    /// Splits `NAME;PARAM=val:VALUE` into its name (uppercased), params, and value.
    private static func parseLine(_ line: String) -> (name: String, params: [String: String], value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line.uppercased(), [:], "") }
        let lhs = String(line[..<colon])
        let value = String(line[line.index(after: colon)...])
        let segments = lhs.components(separatedBy: ";")
        let name = (segments.first ?? "").uppercased()
        var params: [String: String] = [:]
        for seg in segments.dropFirst() {
            let kv = seg.components(separatedBy: "=")
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return (name, params, value)
    }

    private static func address(value: String, params: [String: String]) -> MailAddress? {
        var email = value
        if let range = value.range(of: "mailto:", options: .caseInsensitive) {
            email = String(value[range.upperBound...])
        }
        email = email.trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { return nil }
        return MailAddress(name: params["CN"] ?? "", email: email)
    }

    private static func parseDate(value: String, params: [String: String]) -> (date: Date?, allDay: Bool) {
        // All-day: VALUE=DATE or a bare yyyyMMdd.
        if params["VALUE"]?.uppercased() == "DATE" || (value.count == 8 && !value.contains("T")) {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd"
            f.timeZone = .current
            return (f.date(from: value), true)
        }
        let f = DateFormatter()
        if value.hasSuffix("Z") {
            f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            f.timeZone = TimeZone(identifier: "UTC")
        } else {
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            // IANA TZIDs resolve; Windows zone names (Outlook) fall back to local.
            f.timeZone = params["TZID"].flatMap { TimeZone(identifier: $0) } ?? .current
        }
        return (f.date(from: value), false)
    }

    /// Parses an RFC 5545 DURATION value (`PT1H`, `PT30M`, `P1DT2H`, `P2W`, …) into
    /// seconds. Months/years aren't valid in a duration, so `M` always means minutes.
    private static func parseDuration(_ raw: String) -> TimeInterval? {
        var s = raw.trimmingCharacters(in: .whitespaces).uppercased()
        var sign = 1.0
        if s.hasPrefix("-") { sign = -1; s.removeFirst() }
        else if s.hasPrefix("+") { s.removeFirst() }
        guard s.hasPrefix("P") else { return nil }
        s.removeFirst()
        var total = 0.0
        var number = ""
        var sawUnit = false
        for ch in s {
            if ch == "T" { continue }            // separates the date and time parts
            if ch.isNumber { number.append(ch); continue }
            guard let n = Double(number) else { return nil }
            number = ""
            sawUnit = true
            switch ch {
            case "W": total += n * 7 * 86_400
            case "D": total += n * 86_400
            case "H": total += n * 3_600
            case "M": total += n * 60
            case "S": total += n
            default: return nil
            }
        }
        return sawUnit ? sign * total : nil
    }

    private static func unescapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
         .replacingOccurrences(of: "\\N", with: "\n")
         .replacingOccurrences(of: "\\,", with: ",")
         .replacingOccurrences(of: "\\;", with: ";")
         .replacingOccurrences(of: "\\\\", with: "\\")
    }
}

// MARK: - REPLY builder

/// Builds the iCalendar body for an RSVP (METHOD:REPLY) per RFC 5546: echoes the
/// UID/ORGANIZER/DTSTART and carries a single ATTENDEE line with the chosen PARTSTAT.
enum ICSReplyBuilder {
    static func reply(to invite: CalendarInvite, attendee: MailAddress, response: InviteResponse,
                      comment: String = "", now: Date) -> String {
        let stamp = utcStamp(now)
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//newmail//EN",
            "VERSION:2.0",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(invite.uid)",
        ]
        if let org = invite.organizerLine { lines.append(org) }
        let cn = attendee.name.isEmpty ? attendee.email : attendee.name
        lines.append("ATTENDEE;PARTSTAT=\(response.rawValue);CN=\(cn):mailto:\(attendee.email)")
        if let dtStart = invite.dtStartLine { lines.append(dtStart) }
        if let dtEnd = invite.dtEndLine { lines.append(dtEnd) }
        if !comment.isEmpty { lines.append("COMMENT:\(escapeText(comment))") }
        lines.append("SEQUENCE:\(invite.sequence)")
        lines.append("DTSTAMP:\(stamp)")
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n")
    }

    /// Escapes a TEXT value per RFC 5545 (newlines, commas, semicolons, backslashes).
    private static func escapeText(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: ";", with: "\\;")
         .replacingOccurrences(of: ",", with: "\\,")
         .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func utcStamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
