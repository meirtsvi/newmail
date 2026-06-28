import SwiftUI

/// The stack of new-mail popups shown in the floating top-right panel.
struct NotificationStackView: View {
    @Environment(MailboxViewModel.self) private var vm

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(vm.eventReminders) { reminder in
                EventReminderCard(reminder: reminder, showDismissAll: vm.eventReminders.count > 1)
            }
            ForEach(vm.notifications) { note in
                MailNotificationCard(note: note)
            }
        }
        .padding(12)
    }
}

/// A single calendar-event reminder card: the event title, time, and location,
/// with a Snooze menu, Dismiss, and Dismiss All.
private struct EventReminderCard: View {
    @Environment(MailboxViewModel.self) private var vm
    let reminder: EventReminder
    let showDismissAll: Bool

    /// "Thu 3:00 PM · in 14 minutes", or "Thu 9:30 AM · overdue" once the event has
    /// already started. Recomputed against `now` so a per-minute timeline ticks the
    /// countdown down as the event approaches (and flips to "overdue" when it starts).
    private func whenText(now: Date) -> String {
        let time = reminder.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        if reminder.start <= now { return "\(time) · overdue" }
        let relative = reminder.start.formatted(.relative(presentation: .named))
        return "\(time) · \(relative)"
    }

    /// The event location to show, unless it's empty or a bare URL (online-meeting
    /// links are surfaced by the Connect button instead).
    private var locationText: String? {
        guard let raw = reminder.location?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, !raw.lowercased().hasPrefix("http") else { return nil }
        return raw
    }

    /// Opens `url` so the event surfaces in the user's pinned Google Calendar
    /// window: first by navigating an already-open Calendar tab in Chrome, then by
    /// launching the installed Calendar Chrome app, then the default browser.
    private static func openInCalendar(_ url: URL) {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar")
                    .font(.title)
                    .foregroundStyle(.tint)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(reminder.title.isEmpty ? "(no title)" : reminder.title)
                        .font(.headline)
                        .lineLimit(2)
                        .help(reminder.htmlLink == nil ? "" : "Double-click to open in Google Calendar")
                        .onTapGesture(count: 2) {
                            if let link = reminder.htmlLink { Self.openInCalendar(link) }
                        }
                    TimelineView(.periodic(from: reminder.start, by: 60)) { context in
                        Text(whenText(now: context.date))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if let locationText {
                        Label(locationText, systemImage: "mappin.and.ellipse")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)

                Button { vm.dismissReminder(reminder.id) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if let url = reminder.joinURL, let provider = MeetingProvider(url: url) {
                Button {
                    NSWorkspace.shared.open(url)
                    vm.dismissReminder(reminder.id)
                } label: {
                    Label(provider.label, systemImage: "video.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.regular)
            }

            HStack {
                Menu("Snooze") {
                    ForEach(CalendarReminderService.SnoozePreset.allCases) { preset in
                        Button(preset.rawValue) { vm.snoozeReminder(reminder, preset: preset) }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)

                Spacer()

                if showDismissAll {
                    Button("Dismiss All") { vm.dismissAllReminders() }
                        .controlSize(.small)
                }
                Button("Dismiss") { vm.dismissReminder(reminder.id) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
    }
}

/// A single new-mail card: sender, subject, snippet, and a Reply button that
/// expands into an inline plain-text reply editor.
private struct MailNotificationCard: View {
    @Environment(MailboxViewModel.self) private var vm
    let note: MailNotification

    @State private var replying = false
    @State private var replyText = ""
    @State private var sending = false
    @FocusState private var replyFocused: Bool

    private var header: MessageHeader { note.header }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                // Tapping the message area opens the app focused on this message.
                HStack(alignment: .top, spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(header.subject.isEmpty ? "(no subject)" : header.subject)
                            .font(.headline)
                            .lineLimit(1)
                        Text(header.from.display)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(header.snippet)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .onTapGesture { Task { await vm.focusMessage(note) } }

                Button { vm.dismissNotification(note.id) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if replying {
                replyEditor
            } else {
                HStack {
                    Spacer()
                    let moveFolders = vm.quickMoveForAccount(note.accountId)
                    if !moveFolders.isEmpty {
                        Menu {
                            ForEach(moveFolders, id: \.compositeId) { folder in
                                Button {
                                    Task { await vm.moveNotification(note, to: folder) }
                                } label: {
                                    Label(folder.name, systemImage: folder.kind.icon)
                                }
                            }
                        } label: {
                            Label("Move", systemImage: "folder")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .controlSize(.small)
                    }
                    Button(role: .destructive) {
                        Task { await vm.deleteNotification(note) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .controlSize(.small)
                    Button {
                        vm.cancelAutoDismiss(note.id)
                        replying = true
                        replyFocused = true
                    } label: {
                        Label("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
        // Keep the card up while the mouse is over it; restart its countdown on exit.
        .onHover { hovering in
            if hovering {
                vm.cancelAutoDismiss(note.id)
            } else if !replying {
                vm.scheduleAutoDismiss(note.id)
            }
        }
    }

    private var replyEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("To \(header.from.display)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextEditor(text: $replyText)
                .font(.body)
                .frame(height: 80)
                .focused($replyFocused)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            HStack {
                Button("Cancel") {
                    replying = false
                    replyText = ""
                }
                .controlSize(.small)
                Spacer()
                Button {
                    sending = true
                    Task {
                        await vm.sendQuickReply(note, text: replyText)
                        sending = false
                    }
                } label: {
                    if sending { ProgressView().controlSize(.small) }
                    else { Label("Send", systemImage: "paperplane.fill") }
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(sending || replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}
