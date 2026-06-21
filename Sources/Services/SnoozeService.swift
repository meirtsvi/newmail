import Foundation
import SwiftData

/// Computes snooze wake-times and runs the 60-second timer that returns expired
/// messages to the Inbox. Runs only while the app is open (per design); on
/// launch it immediately processes anything already past its wake time.
@MainActor
final class SnoozeService {
    enum Preset: String, CaseIterable, Identifiable {
        case endOfToday = "Later Today"
        case tomorrow = "Tomorrow"
        case nextWeek = "Next Week"
        case nextMonth = "Next Month"
        var id: String { rawValue }
    }

    private let provider: MailProvider
    private let accountId: String
    private let context: ModelContext
    private var timer: Timer?

    /// Notifies the UI (e.g. to refresh the current folder) after messages wake.
    var onWake: (() -> Void)?

    init(provider: MailProvider, accountId: String, context: ModelContext? = nil) {
        self.provider = provider
        self.accountId = accountId
        self.context = context ?? Persistence.container.mainContext
    }

    // MARK: Wake-time computation (morning/evening scheme)

    static func wakeDate(for preset: Preset, now: Date = .init(), calendar: Calendar = .current) -> Date {
        switch preset {
        case .endOfToday:
            return calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now)
                ?? now.addingTimeInterval(3600)
        case .tomorrow:
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
            return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        case .nextWeek:
            // Next Sunday at 08:00.
            var comps = DateComponents()
            comps.weekday = 1 // Sunday
            comps.hour = 8
            let next = calendar.nextDate(after: now, matching: comps, matchingPolicy: .nextTime) ?? now
            return next
        case .nextMonth:
            let firstNextMonth = calendar.date(byAdding: .month, value: 1, to: now) ?? now
            var comps = calendar.dateComponents([.year, .month], from: firstNextMonth)
            comps.day = 1
            comps.hour = 8
            return calendar.date(from: comps) ?? firstNextMonth
        }
    }

    // MARK: Snoozing

    func snooze(ids: [String], headers: [MessageHeader], until wake: Date, fromFolderId: String) async throws {
        guard !ids.isEmpty else { return }
        let snoozedId = try await provider.ensureFolder(named: "Snoozed")
        try await provider.move(ids: ids, toFolderId: snoozedId, fromFolderId: fromFolderId)

        for id in ids {
            let record = SnoozeRecord(
                messageId: id,
                accountId: accountId,
                accountEmail: provider.accountEmail,
                wakeDate: wake,
                originLabelId: fromFolderId,
                snoozedLabelId: snoozedId
            )
            context.insert(record)
        }
        try? context.save()
    }

    /// Returns the snoozed messages to their origin folder immediately and drops
    /// their records (manual "unsnooze").
    func unsnooze(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let scopedAccountId = accountId
        let descriptor = FetchDescriptor<SnoozeRecord>(
            predicate: #Predicate { $0.accountId == scopedAccountId }
        )
        let records = (try? context.fetch(descriptor))?.filter { ids.contains($0.messageId) } ?? []
        for record in records {
            try await provider.move(
                ids: [record.messageId],
                toFolderId: record.originLabelId.isEmpty ? "INBOX" : record.originLabelId,
                fromFolderId: record.snoozedLabelId
            )
            context.delete(record)
        }
        try? context.save()
    }

    /// The wake time for a snoozed message, if one is recorded (used by the
    /// "Snoozed Until" column).
    func wakeDate(forMessageId id: String) -> Date? {
        let scopedAccountId = accountId
        var descriptor = FetchDescriptor<SnoozeRecord>(
            predicate: #Predicate { $0.messageId == id && $0.accountId == scopedAccountId }
        )
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first?.wakeDate
    }

    // MARK: Timer

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.processExpired() }
        }
        self.timer = timer
        Task { await processExpired() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func processExpired() async {
        let now = Date()
        let scopedAccountId = accountId
        let descriptor = FetchDescriptor<SnoozeRecord>(
            predicate: #Predicate { $0.accountId == scopedAccountId && $0.wakeDate <= now }
        )
        guard let due = try? context.fetch(descriptor), !due.isEmpty else { return }

        var awoke = false
        for record in due {
            do {
                try await provider.move(
                    ids: [record.messageId],
                    toFolderId: record.originLabelId.isEmpty ? "INBOX" : record.originLabelId,
                    fromFolderId: record.snoozedLabelId
                )
                context.delete(record)
                awoke = true
            } catch {
                // Leave the record in place; retry on the next tick.
                continue
            }
        }
        if awoke {
            try? context.save()
            onWake?()
        }
    }
}
