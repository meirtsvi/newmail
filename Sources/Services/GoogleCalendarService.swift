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
                    joinURL: event.joinURL, location: item.location, htmlLink: htmlLink
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
                    joinURL: event.joinURL, location: item.location, htmlLink: htmlLink
                ))
            }
            // Events already ended (event.end <= now) are skipped entirely.
        }
        return out
    }

    /// Whether the event still exists on the calendar. Returns `false` only when the
    /// server confirms it's gone (404) or cancelled; any transient/network error
    /// returns `true` so a hiccup never wrongly dismisses a live reminder.
    func eventExists(id: String) async -> Bool {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/primary/events")!
        comps.path += "/" + id
        guard let url = comps.url else { return true }
        var req = URLRequest(url: url)
        guard let token = try? await auth.accessToken() else { return true }
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return true }
        if http.statusCode == 404 || http.statusCode == 410 { return false }
        guard (200..<300).contains(http.statusCode) else { return true }
        if let item = try? JSONDecoder().decode(Item.self, from: data), item.status == "cancelled" {
            return false
        }
        return true
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
