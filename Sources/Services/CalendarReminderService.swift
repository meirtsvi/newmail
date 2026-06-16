import Foundation

/// Background scheduler for calendar event reminder popups. Mirrors `SnoozeService`:
/// it owns two timers — one that periodically refetches the upcoming-reminder
/// schedule from Google Calendar, and one that ticks to fire reminders whose lead
/// time has arrived — and hands fired reminders back to the UI through `onFire`.
///
/// It remembers which reminder ids have already fired or been dismissed so a
/// re-poll never resurfaces a reminder the user has already seen or snoozed.
@MainActor
final class CalendarReminderService {
    enum SnoozePreset: String, CaseIterable, Identifiable {
        case fiveMin  = "5 minutes"
        case tenMin   = "10 minutes"
        case oneHour  = "1 hour"
        case tomorrow = "Tomorrow"
        var id: String { rawValue }
    }

    private let calendar: GoogleCalendarService
    private var pollTimer: Timer?   // refetches the schedule
    private var tickTimer: Timer?   // checks what's due
    /// Reminders scheduled but not yet fired, keyed by id.
    private var scheduled: [String: EventReminder] = [:]
    /// Ids already fired or dismissed — not auto-recreated by a re-poll.
    private var handled: Set<String> = []

    /// Called on the main actor with reminders whose `fireDate` just passed.
    var onFire: (([EventReminder]) -> Void)?

    init(calendar: GoogleCalendarService = .shared) {
        self.calendar = calendar
    }

    // MARK: Lifecycle

    func start() {
        stop()
        let poll = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { await self?.refreshSchedule() }
        }
        let tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pollTimer = poll
        tickTimer = tick
        Task {
            await refreshSchedule()
            // `self.` disambiguates the method from the local `tick` timer above.
            self.tick()
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
    }

    // MARK: Scheduling

    /// Pulls the upcoming reminders and adds any we haven't already scheduled,
    /// fired, or dismissed. Existing scheduled entries (including snoozed ones) are
    /// left untouched so their adjusted fire times survive a re-poll.
    private func refreshSchedule() async {
        guard let fresh = try? await calendar.upcomingReminders() else { return }
        for reminder in fresh where !handled.contains(reminder.id) && scheduled[reminder.id] == nil {
            scheduled[reminder.id] = reminder
        }
    }

    /// Fires every scheduled reminder whose lead time has arrived, moving each from
    /// `scheduled` into `handled` so it isn't fired (or re-polled) twice.
    private func tick() {
        let now = Date()
        let due = scheduled.values.filter { $0.fireDate <= now }
        guard !due.isEmpty else { return }
        for reminder in due {
            scheduled[reminder.id] = nil
            handled.insert(reminder.id)
        }
        onFire?(due.sorted { $0.start < $1.start })
    }

    // MARK: User actions

    /// Reschedules a fired reminder to a later time and re-arms it.
    func snooze(_ reminder: EventReminder, preset: SnoozePreset) {
        var rescheduled = reminder
        rescheduled.fireDate = Self.wakeDate(for: preset)
        handled.remove(reminder.id)
        scheduled[reminder.id] = rescheduled
    }

    /// Permanently drops a reminder for this session — it won't fire again or be
    /// recreated by the next poll.
    func dismiss(_ id: String) {
        scheduled[id] = nil
        handled.insert(id)
    }

    static func wakeDate(for preset: SnoozePreset, now: Date = .init(), calendar: Calendar = .current) -> Date {
        switch preset {
        case .fiveMin:  return now.addingTimeInterval(5 * 60)
        case .tenMin:   return now.addingTimeInterval(10 * 60)
        case .oneHour:  return now.addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        }
    }
}
