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
        case atEventTime = "At the time of event"
        case beforeStart = "5 minutes before start"
        case fiveMin    = "5 minutes"
        case tenMin     = "10 minutes"
        case fifteenMin = "15 minutes"
        case thirtyMin  = "30 minutes"
        case oneHour    = "1 hour"
        case twoHours   = "2 hours"
        case fourHours  = "4 hours"
        case endOfToday = "End of today"
        case tomorrow   = "Tomorrow morning"
        case oneDay     = "1 day"
        case twoDays    = "2 days"
        case fourDays   = "4 days"
        case endOfWeek  = "End of week"
        case nextWeek   = "Next week"
        case oneWeek    = "1 week"
        case twoWeeks   = "2 weeks"
        var id: String { rawValue }
    }

    private let calendar: GoogleCalendarService
    private var pollTimer: Timer?   // refetches the schedule
    private var tickTimer: Timer?   // checks what's due
    private var verifyTimer: Timer? // checks fired reminders' events still exist
    /// Reminders scheduled but not yet fired, keyed by id.
    private var scheduled: [String: EventReminder] = [:]
    /// Ids already fired or dismissed — not auto-recreated by a re-poll.
    private var handled: Set<String> = []
    /// Reminders that have fired and whose card is still on screen, keyed by id.
    /// Used to detect when their calendar event is deleted out from under them.
    private var presented: [String: EventReminder] = [:]
    private var verifying = false

    /// Called on the main actor with reminders whose `fireDate` just passed.
    var onFire: (([EventReminder]) -> Void)?
    /// Called on the main actor with ids of presented reminders that should close —
    /// their event was deleted, ended, turned all-day, or moved out of its reminder
    /// window (in which case it's also rescheduled to re-fire at the new lead time).
    var onCancelled: (([String]) -> Void)?
    /// Called on the main actor with presented reminders whose event details changed
    /// (time, title, location, or meeting link) so the visible card can refresh.
    var onUpdate: (([EventReminder]) -> Void)?

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
        let verify = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { await self?.reconcilePresented() }
        }
        pollTimer = poll
        tickTimer = tick
        verifyTimer = verify
        Task {
            await refreshSchedule()
            // `self.` disambiguates the method from the local `tick` timer above.
            self.tick()
        }
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        tickTimer?.invalidate(); tickTimer = nil
        verifyTimer?.invalidate(); verifyTimer = nil
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
            presented[reminder.id] = reminder
        }
        onFire?(due.sorted { $0.start < $1.start })
    }

    /// Re-checks every still-presented reminder against a fresh fetch and keeps the
    /// visible cards in sync with the calendar:
    ///  - Event gone (deleted/cancelled), ended, or turned all-day → close the card.
    ///  - Event moved so its reminder window hasn't started yet (`fireDate` now in the
    ///    future) → close the card now and reschedule so it re-fires at the new time.
    ///  - Event details changed (start/title/location/meeting link) → refresh the card.
    /// A failed fetch is a no-op, so a network hiccup never wrongly closes a live card.
    private func reconcilePresented() async {
        guard !verifying, !presented.isEmpty else { return }
        verifying = true
        defer { verifying = false }

        guard let fresh = try? await calendar.upcomingReminders() else { return }
        let freshById = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let now = Date()
        var closed: [String] = []
        var updated: [EventReminder] = []

        for reminder in Array(presented.values) {   // snapshot: the loop mutates `presented`
            guard let current = freshById[reminder.id] else {
                // No longer an upcoming/in-progress popup reminder: deleted, cancelled,
                // ended, or now all-day. Close for good.
                presented[reminder.id] = nil
                scheduled[reminder.id] = nil
                handled.insert(reminder.id)
                closed.append(reminder.id)
                continue
            }
            if current.fireDate > now {
                // Moved beyond its reminder window — close now, and put it back on the
                // schedule (no longer "handled") so it re-fires at the new lead time.
                presented[reminder.id] = nil
                handled.remove(reminder.id)
                scheduled[reminder.id] = current
                closed.append(reminder.id)
            } else if current.title != reminder.title || current.start != reminder.start
                        || current.location != reminder.location || current.joinURL != reminder.joinURL {
                presented[reminder.id] = current
                updated.append(current)
            }
        }

        if !closed.isEmpty { onCancelled?(closed) }
        if !updated.isEmpty { onUpdate?(updated) }
    }

    // MARK: User actions

    /// Reschedules a fired reminder to a later time and re-arms it.
    func snooze(_ reminder: EventReminder, preset: SnoozePreset) {
        var rescheduled = reminder
        // The event-relative presets are anchored to the event start, not to now;
        // the duration presets are relative to now and don't need the reminder.
        switch preset {
        case .atEventTime: rescheduled.fireDate = reminder.start
        case .beforeStart: rescheduled.fireDate = reminder.start.addingTimeInterval(-5 * 60)
        default:           rescheduled.fireDate = Self.wakeDate(for: preset)
        }
        handled.remove(reminder.id)
        scheduled[reminder.id] = rescheduled
        presented[reminder.id] = nil
    }

    /// Permanently drops a reminder for this session — it won't fire again or be
    /// recreated by the next poll.
    func dismiss(_ id: String) {
        scheduled[id] = nil
        handled.insert(id)
        presented[id] = nil
    }

    static func wakeDate(for preset: SnoozePreset, now: Date = .init(), calendar: Calendar = .current) -> Date {
        switch preset {
        // Event-relative; handled in `snooze`. Falls back to "now" if ever routed here.
        case .atEventTime: return now
        case .beforeStart: return now
        case .fiveMin:    return now.addingTimeInterval(5 * 60)
        case .tenMin:     return now.addingTimeInterval(10 * 60)
        case .fifteenMin: return now.addingTimeInterval(15 * 60)
        case .thirtyMin:  return now.addingTimeInterval(30 * 60)
        case .oneHour:    return now.addingTimeInterval(3600)
        case .twoHours:   return now.addingTimeInterval(2 * 3600)
        case .fourHours:  return now.addingTimeInterval(4 * 3600)
        case .endOfToday:
            // 18:00 today, or 18:00 tomorrow if that's already past, so snoozing in
            // the evening never lands in the past (which would fire immediately).
            if let todayAt18 = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now), todayAt18 > now {
                return todayAt18
            }
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow)
                ?? now.addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .oneDay:
            return calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(24 * 3600)
        case .twoDays:
            return calendar.date(byAdding: .day, value: 2, to: now) ?? now.addingTimeInterval(48 * 3600)
        case .fourDays:
            return calendar.date(byAdding: .day, value: 4, to: now) ?? now.addingTimeInterval(96 * 3600)
        case .endOfWeek:
            // Next Friday at 18:00.
            var comps = DateComponents()
            comps.weekday = 6 // Friday
            comps.hour = 18
            return calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(24 * 3600)
        case .nextWeek:
            // Next Sunday at 08:00.
            var comps = DateComponents()
            comps.weekday = 1 // Sunday
            comps.hour = 8
            return calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(7 * 24 * 3600)
        case .oneWeek:
            return calendar.date(byAdding: .day, value: 7, to: now) ?? now.addingTimeInterval(7 * 24 * 3600)
        case .twoWeeks:
            return calendar.date(byAdding: .day, value: 14, to: now) ?? now.addingTimeInterval(14 * 24 * 3600)
        }
    }
}
