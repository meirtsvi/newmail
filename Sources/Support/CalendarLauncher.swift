import AppKit

/// Opens a Google Calendar URL in the user's pinned Calendar window: first by
/// pointing an already-open Calendar tab in Chrome at it, then by launching the
/// installed Calendar Chrome app, then the default browser. Shared by the event
/// reminder cards and the calendar-invite card.
enum CalendarLauncher {
    static func open(_ url: URL) {
        // Force the app frontmost so the one-time "control Google Chrome" Automation
        // prompt can appear — the nonactivating reminder panel can't show it, and
        // TCC silently denies (-1743) when the requesting app isn't active. Defer the
        // (blocking) Apple event to a later runloop turn so activation takes effect
        // before TCC evaluates the request.
        NSApplication.shared.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if navigateExistingCalendarWindow(to: url) { return }
            if let app = googleCalendarApp {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = true
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Asks Chrome to point an already-open Google Calendar tab at `url` and bring
    /// its window forward, so the event reuses the user's pinned Calendar window.
    /// Returns false (so the caller falls back to launching the app) when Chrome
    /// isn't running, no Calendar window is open, or scripting is denied.
    private static func navigateExistingCalendarWindow(to url: URL) -> Bool {
        // Only script Chrome if it's already running, so we never launch a blank
        // browser just to look for a Calendar window.
        let chromeRunning = NSWorkspace.shared.runningApplications.contains {
            ($0.bundleIdentifier ?? "").hasPrefix("com.google.Chrome")
        }
        guard chromeRunning else { return false }

        let target = url.absoluteString
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        // Address Chrome by bundle id (resolving it by name fails under sandbox),
        // and step tabs by integer index: `index of t` from a `repeat with t in
        // tabs` loop resolves to a plural reference and throws.
        let source = """
        tell application id "com.google.Chrome"
            repeat with w in windows
                set n to count of tabs of w
                repeat with i from 1 to n
                    if (URL of (tab i of w)) contains "calendar.google.com" then
                        set URL of (tab i of w) to "\(target)"
                        set active tab index of w to i
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
            return "none"
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return false }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return false }
        return result.stringValue == "ok"
    }

    /// Location of the "Google Calendar" app installed by Chrome as a standalone
    /// app, if present. Chrome keeps these under ~/Applications/Chrome Apps[.localized].
    private static let googleCalendarApp: URL? = {
        let fm = FileManager.default
        let roots = [fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                     URL(fileURLWithPath: "/Applications")]
        for root in roots {
            for sub in ["Chrome Apps.localized", "Chrome Apps"] {
                let candidate = root.appendingPathComponent(sub)
                    .appendingPathComponent("Google Calendar.app")
                if fm.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }()
}
