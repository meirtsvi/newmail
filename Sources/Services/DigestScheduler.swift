import Foundation

/// Fires the daily digest at the hour chosen in Settings, with catch-up.
///
/// Modeled on `FeedService` / `SnoozeService`: a plain repeating timer that
/// runs only while the app is open. Each tick asks one question — is it past
/// today's digest hour, and has today's digest not run yet? — so a Mac that was
/// asleep or an app that was closed produces the digest late on the next
/// launch, never skips it. The day marker is written *before* generating, so a
/// failure doesn't retry every five minutes for the rest of the day.
@MainActor
final class DigestScheduler {
    /// Coarse: the schedule is an hour, not a minute, so this only bounds how
    /// late a catch-up run can be.
    private static let interval: TimeInterval = 300

    private var timer: Timer?
    private var inFlight = false

    /// Runs the digest. Supplied by the view model, which owns the accounts,
    /// the destination provider, and the post-run cache updates.
    private let generate: () async -> Void

    init(generate: @escaping () async -> Void) {
        self.generate = generate
    }

    func start() {
        stop()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { await self.tick() }
        }
        self.timer = timer
        Task { await tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func tick() async {
        guard !inFlight, DigestPrefs.scheduleEnabled, GeminiConfig.isConfigured else { return }
        // Delivering the digest inserts a real received message, which needs
        // Gmail write scope — skip the pass quietly rather than failing loudly.
        guard (try? await GoogleAuth.shared.hasWriteScope) == true else { return }

        let now = Date()
        guard Self.isDue(at: now) else { return }
        let today = Self.dayKey(for: now)
        guard UserDefaults.standard.string(forKey: DigestPrefs.lastRunDayKey) != today else { return }

        inFlight = true
        defer { inFlight = false }
        UserDefaults.standard.set(today, forKey: DigestPrefs.lastRunDayKey)
        await generate()
    }

    /// True once the local clock has passed today's configured digest hour.
    static func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        calendar.component(.hour, from: now) >= DigestPrefs.scheduleHour
    }

    /// Local calendar day, as the marker that keeps the digest to once a day.
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
