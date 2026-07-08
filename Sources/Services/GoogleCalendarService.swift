import Foundation

/// A single event on the user's calendar, used to render the day timeline next
/// to a meeting invitation.
struct CalEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var joinURL: URL?       // video-meeting link (Zoom/Meet/Teams), if any
}

/// A recognized video-conferencing provider for an event's join link.
enum MeetingProvider {
    case zoom, meet, teams

    var label: String {
        switch self {
        case .zoom:  return "Connect to Zoom"
        case .meet:  return "Connect to Meet"
        case .teams: return "Connect to Teams"
        }
    }

    /// Classifies a URL by host; nil for links we don't recognize.
    init?(url: URL) {
        let host = (url.host ?? "").lowercased()
        if host.contains("zoom.us") { self = .zoom }
        else if host.contains("meet.google.com") { self = .meet }
        else if host.contains("teams.microsoft.com") || host.contains("teams.live.com") { self = .teams }
        else { return nil }
    }
}

/// One popup reminder for a calendar event: a title/time plus the moment the
/// popup should appear (the event's start minus the reminder's lead minutes).
struct EventReminder: Identifiable, Hashable {
    var id: String          // the eventId — stable across the event's upcoming→in-progress transition
    var eventId: String
    var title: String
    var start: Date
    var isAllDay: Bool
    var fireDate: Date      // mutable: snooze reschedules it
    var joinURL: URL?       // video-meeting link (Zoom/Meet/Teams), if any
    var location: String?   // event location text, if any
    var htmlLink: URL?      // link to open the event in Google Calendar's web UI
}

/// Reads the user's primary Google Calendar (read-only) to show their schedule
/// around an invitation. Uses the same Google account/token as Gmail; requires
/// the `calendar.readonly` scope (granted via the interactive sign-in).
actor GoogleCalendarService {
    static let shared = GoogleCalendarService()

    private let auth: GoogleAuth
    init(auth: GoogleAuth = .shared) { self.auth = auth }

    /// All events overlapping the calendar day that `date` falls on.
    func events(onDayOf date: Date) async throws -> [CalEvent] {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: date)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay) ?? date

        let iso = ISO8601DateFormatter()
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: startOfDay)),
            .init(name: "timeMax", value: iso.string(from: endOfDay)),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "50"),
        ]
        var req = URLRequest(url: comps.url!)
        let token = try await auth.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MailError.other("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw MailError.api(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let list = try JSONDecoder().decode(EventsList.self, from: data)
        return list.items.compactMap(Self.event(from:))
    }

    /// Popup reminders for timed events starting within `window` from now. A
    /// reminder's `fireDate` is the event start minus its lead minutes. Events that
    /// opt in to the calendar's defaults (`useDefault`) inherit `defaultReminders`;
    /// email-method reminders are ignored. All-day events are skipped (their
    /// reminder timing is day-based and out of scope here).
    ///
    /// The window must be at least as large as the longest reminder lead time, or
    /// long-lead reminders (e.g. "2 days before") would never be discovered for
    /// events further out than the window. Google allows leads up to 4 weeks.
    func upcomingReminders(within window: TimeInterval = 28 * 24 * 3600) async throws -> [EventReminder] {
        let now = Date()
        let iso = ISO8601DateFormatter()
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [
            .init(name: "timeMin", value: iso.string(from: now)),
            .init(name: "timeMax", value: iso.string(from: now.addingTimeInterval(window))),
            .init(name: "singleEvents", value: "true"),
            .init(name: "orderBy", value: "startTime"),
            .init(name: "maxResults", value: "50"),
        ]
        var req = URLRequest(url: comps.url!)
        let token = try await auth.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw MailError.other("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw MailError.api(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let list = try JSONDecoder().decode(EventsList.self, from: data)
        let defaults = list.defaultReminders ?? []

        var out: [EventReminder] = []
        for item in list.items {
            guard let event = Self.event(from: item), !event.isAllDay else { continue }
            let htmlLink = item.htmlLink.flatMap { URL(string: $0) }
            // A nil method means popup (Google omits it for default reminders).
            let isPopup: (Reminder) -> Bool = { ($0.method ?? "popup") == "popup" }
            let source: [Reminder]
            if item.reminders?.useDefault ?? true {
                source = defaults
            } else {
                source = item.reminders?.overrides ?? []
            }
            let popupReminders = source.filter(isPopup)

            if event.start > now {
                // Upcoming event: collapse multiple popup overrides into one card. The
                // card shows only the event (no lead time), so several leads would just
                // be visually-identical duplicates. Fire at the earliest configured lead
                // (the largest minutes) so the heads-up appears as early as the user
                // asked; a lead whose time has already passed fires on the next tick.
                guard let maxLead = popupReminders.compactMap(\.minutes).max() else { continue }
                let fireDate = event.start.addingTimeInterval(-Double(maxLead) * 60)
                out.append(EventReminder(
                    id: event.id,
                    eventId: event.id, title: event.title,
                    start: event.start, isAllDay: false, fireDate: fireDate,
                    joinURL: event.joinURL, location: Self.displayLocation(from: item), htmlLink: htmlLink
                ))
            } else if event.end > now {
                // Event already in progress: surface a single "overdue" reminder that
                // fires immediately — but only for events that had a popup reminder
                // configured, so we don't pop up for every busy block. Any overrides
                // collapse into one card. The id stays `event.id` (no "#overdue"
                // suffix) so an event the user already saw or snoozed before it started
                // isn't treated as a brand-new reminder once it's in progress.
                guard !popupReminders.isEmpty else { continue }
                out.append(EventReminder(
                    id: event.id,
                    eventId: event.id, title: event.title,
                    start: event.start, isAllDay: false, fireDate: now,
                    joinURL: event.joinURL, location: Self.displayLocation(from: item), htmlLink: htmlLink
                ))
            }
            // Events already ended (event.end <= now) are skipped entirely.
        }
        return out
    }

    /// Records the user's RSVP on the calendar event itself (PATCH with
    /// `sendUpdates=all`), so Google — not this app — mails the organizer, with
    /// the same notification it sends when responding in the Calendar UI.
    /// Requires the `calendar.events` scope. Throws when the event isn't on the
    /// primary calendar or the user isn't among its attendees; callers fall back
    /// to an emailed iCalendar REPLY.
    func respond(icalUID: String, attendeeEmail: String, status: String, comment: String) async throws {
        let token = try await auth.accessToken()

        // Google Calendar auto-adds Gmail invitations to the recipient's primary
        // calendar under the invite's iCalendar UID — look the event up by it.
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.queryItems = [.init(name: "iCalUID", value: icalUID)]
        var lookup = URLRequest(url: comps.url!)
        lookup.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: lookup)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MailError.api((resp as? HTTPURLResponse)?.statusCode ?? 0,
                                String(data: data, encoding: .utf8) ?? "")
        }
        let list = try JSONDecoder().decode(EventsList.self, from: data)
        guard let item = list.items.first(where: { $0.status != "cancelled" && $0.id != nil }),
              let eventId = item.id,
              var attendees = item.attendees,
              let mine = attendees.firstIndex(where: {
                  $0.isSelf == true || ($0.email ?? "").caseInsensitiveCompare(attendeeEmail) == .orderedSame
              })
        else {
            throw MailError.other("Event \(icalUID) not found on the primary calendar")
        }

        // Attendees may only change their own entry; Google ignores edits to the
        // rest of the list, so sending it back as-is is safe.
        attendees[mine].responseStatus = status
        if !comment.isEmpty { attendees[mine].comment = comment }

        var patchComps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events/\(eventId)")!
        patchComps.queryItems = [.init(name: "sendUpdates", value: "all")]
        var patch = URLRequest(url: patchComps.url!)
        patch.httpMethod = "PATCH"
        patch.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        patch.setValue("application/json", forHTTPHeaderField: "Content-Type")
        patch.httpBody = try JSONEncoder().encode(AttendeesPatch(attendees: attendees))
        let (patchData, patchResp) = try await URLSession.shared.data(for: patch)
        guard let patchHTTP = patchResp as? HTTPURLResponse, (200..<300).contains(patchHTTP.statusCode) else {
            throw MailError.api((patchResp as? HTTPURLResponse)?.statusCode ?? 0,
                                String(data: patchData, encoding: .utf8) ?? "")
        }
    }

    // MARK: - JSON

    private struct EventsList: Codable {
        var items: [Item]
        var defaultReminders: [Reminder]?
    }
    private struct Item: Codable {
        var id: String?
        var summary: String?
        var status: String?
        var start: When?
        var end: When?
        var reminders: Reminders?
        var location: String?
        var description: String?
        var hangoutLink: String?
        var conferenceData: ConferenceData?
        var htmlLink: String?
        var attendees: [Attendee]?
    }
    private struct Attendee: Codable {
        var email: String?
        var displayName: String?
        var organizer: Bool?
        var isSelf: Bool?
        var resource: Bool?
        var optional: Bool?
        var responseStatus: String?
        var comment: String?

        enum CodingKeys: String, CodingKey {
            case email, displayName, organizer, resource, optional, responseStatus, comment
            case isSelf = "self"
        }
    }
    private struct AttendeesPatch: Codable {
        var attendees: [Attendee]
    }
    private struct ConferenceData: Codable {
        var entryPoints: [EntryPoint]?
    }
    private struct EntryPoint: Codable {
        var entryPointType: String?     // "video" | "phone" | "more" | …
        var uri: String?
    }
    private struct When: Codable {
        var dateTime: String?   // timed events
        var date: String?       // all-day events (yyyy-MM-dd)
    }
    private struct Reminders: Codable {
        var useDefault: Bool?
        var overrides: [Reminder]?
    }
    private struct Reminder: Codable {
        var method: String?     // "popup" | "email"
        var minutes: Int?       // lead time before the event starts
    }

    private static func event(from item: Item) -> CalEvent? {
        guard item.status != "cancelled", let start = item.start, let end = item.end else { return nil }
        let join = meetingURL(from: item)
        if let s = start.dateTime, let e = end.dateTime,
           let sd = parseDateTime(s), let ed = parseDateTime(e) {
            return CalEvent(id: item.id ?? UUID().uuidString,
                            title: item.summary ?? "(busy)", start: sd, end: ed,
                            isAllDay: false, joinURL: join)
        }
        if let s = start.date, let sd = parseDate(s) {
            let ed = parseDate(end.date ?? s) ?? sd
            return CalEvent(id: item.id ?? UUID().uuidString,
                            title: item.summary ?? "(busy)", start: sd, end: ed,
                            isAllDay: true, joinURL: join)
        }
        return nil
    }

    /// Human-readable location for an event's reminder card. Strips URLs out of
    /// the location text (Zoom-scheduled events often carry the join link there,
    /// which would otherwise hide the room name appended after it), and falls
    /// back to booked room resources when the field is empty or link-only.
    private static func displayLocation(from item: Item) -> String? {
        if let raw = item.location {
            var text = raw
            if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
                let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
                for match in matches.reversed() {
                    if let r = Range(match.range, in: text) { text.removeSubrange(r) }
                }
            }
            let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n,;·•-–—"))
            if !cleaned.isEmpty { return cleaned }
        }
        let rooms = (item.attendees ?? [])
            .filter { $0.resource == true }
            .compactMap(\.displayName)
            .filter { !$0.isEmpty }
        return rooms.isEmpty ? nil : rooms.joined(separator: ", ")
    }

    /// Best video-meeting link for an event, preferring the structured conference
    /// data, then the Hangouts/Meet link, then any recognized provider URL found in
    /// the location or description text.
    private static func meetingURL(from item: Item) -> URL? {
        if let uri = item.conferenceData?.entryPoints?
            .first(where: { ($0.entryPointType ?? "") == "video" })?.uri,
           let url = URL(string: uri), MeetingProvider(url: url) != nil {
            return url
        }
        if let link = item.hangoutLink, let url = URL(string: link) { return url }
        for text in [item.location, item.description].compactMap({ $0 }) {
            if let url = firstMeetingLink(in: text) { return url }
        }
        return nil
    }

    /// Scans free text for the first URL belonging to a recognized provider.
    private static func firstMeetingLink(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            if let url = match.url, MeetingProvider(url: url) != nil { return url }
        }
        return nil
    }

    private static func parseDateTime(_ s: String) -> Date? {
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f.date(from: s)
    }
}
