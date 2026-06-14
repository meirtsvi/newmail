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

    // MARK: - JSON

    private struct EventsList: Codable { var items: [Item] }
    private struct Item: Codable {
        var id: String?
        var summary: String?
        var status: String?
        var start: When?
        var end: When?
    }
    private struct When: Codable {
        var dateTime: String?   // timed events
        var date: String?       // all-day events (yyyy-MM-dd)
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
