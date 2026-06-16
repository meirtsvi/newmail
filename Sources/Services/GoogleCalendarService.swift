import Foundation

/// A single event on the user's calendar, used to render the day timeline next
/// to a meeting invitation.
struct CalEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
}

/// One popup reminder for a calendar event: a title/time plus the moment the
/// popup should appear (the event's start minus the reminder's lead minutes).
struct EventReminder: Identifiable, Hashable {
    var id: String          // "<eventId>#<minutes>" — distinct per override
    var eventId: String
    var title: String
    var start: Date
    var isAllDay: Bool
    var fireDate: Date      // mutable: snooze reschedules it
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
    func upcomingReminders(within window: TimeInterval = 36 * 3600) async throws -> [EventReminder] {
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
            // A nil method means popup (Google omits it for default reminders).
            let isPopup: (Reminder) -> Bool = { ($0.method ?? "popup") == "popup" }
            let source: [Reminder]
            if item.reminders?.useDefault ?? true {
                source = defaults
            } else {
                source = item.reminders?.overrides ?? []
            }
            for reminder in source where isPopup(reminder) {
                guard let minutes = reminder.minutes else { continue }
                let fireDate = event.start.addingTimeInterval(-Double(minutes) * 60)
                // Skip reminders for events already over; keep ones whose lead time
                // has already passed (they fire immediately on the next tick).
                guard fireDate <= event.start, event.start > now else { continue }
                out.append(EventReminder(
                    id: "\(event.id)#\(minutes)",
                    eventId: event.id, title: event.title,
                    start: event.start, isAllDay: false, fireDate: fireDate
                ))
            }
        }
        return out
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
        if let s = start.dateTime, let e = end.dateTime,
           let sd = parseDateTime(s), let ed = parseDateTime(e) {
            return CalEvent(id: item.id ?? UUID().uuidString,
                            title: item.summary ?? "(busy)", start: sd, end: ed, isAllDay: false)
        }
        if let s = start.date, let sd = parseDate(s) {
            let ed = parseDate(end.date ?? s) ?? sd
            return CalEvent(id: item.id ?? UUID().uuidString,
                            title: item.summary ?? "(busy)", start: sd, end: ed, isAllDay: true)
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
