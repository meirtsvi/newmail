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
                            if let link = reminder.htmlLink { CalendarLauncher.open(link) }
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
                // Default the primary action (and label) to whatever snooze makes
                // sense for how close the event is, since presets that land in the
                // past would just re-fire immediately:
                //   • more than 5 min out → "5 minutes before start"
                //   • within 5 min of start → "At the time of event"
                //   • already started → "5 minutes" (from now)
                // Re-evaluated each minute so it flips as those thresholds pass.
                TimelineView(.periodic(from: reminder.start, by: 60)) { context in
                    let toStart = reminder.start.timeIntervalSince(context.date)
                    let started = toStart <= 0
                    let preset: CalendarReminderService.SnoozePreset =
                        started ? .fiveMin : (toStart < 5 * 60 ? .atEventTime : .beforeStart)
                    // Once the event has started, the event-relative presets would
                    // land in the past and re-fire immediately, so drop them.
                    let presets = CalendarReminderService.SnoozePreset.allCases.filter {
                        !started || ($0 != .atEventTime && $0 != .beforeStart)
                    }
                    Menu(preset.rawValue) {
                        ForEach(presets) { preset in
                            Button(preset.rawValue) { vm.snoozeReminder(reminder, preset: preset) }
                        }
                    } primaryAction: {
                        vm.snoozeReminder(reminder, preset: preset)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.small)
                }

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
/// expands into an inline plain-text reply editor. When the message is a calendar
/// invitation, the expanded preview shows the invite instead of the raw body:
/// event details, a note to the organizer, Accept / Maybe / Decline, and a day
/// timeline of the user's schedule — the same affordances as the reading pane.
private struct MailNotificationCard: View {
    @Environment(MailboxViewModel.self) private var vm
    let note: MailNotification

    @State private var replying = false
    @State private var replyText = ""
    @State private var sending = false
    /// Set while the pointer is over the message area (title or body); grows the card
    /// into a full, scrollable body preview. Stays true until the pointer leaves the
    /// whole card (see card onHover).
    @State private var expanded = false
    /// The fetched full message shown when expanded; nil until first loaded.
    @State private var messageBody: MessageBody?
    /// RSVP state for an invite message: the optional note to the organizer, the
    /// response currently being sent, and the schedule for the invite's day.
    @State private var inviteNote = ""
    @State private var inviteSending: InviteResponse?
    @State private var dayEvents: [CalEvent] = []
    @State private var dayEventsLoaded = false
    /// Pending expand triggered by hovering the message area; fires after a short dwell
    /// so a quick pass over the card doesn't pop it open. Cancelled if the pointer leaves.
    @State private var expandTask: Task<Void, Never>?
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
                            .lineLimit(expanded ? 3 : 1)
                        Text(header.from.display)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        // Collapsed: the short list snippet. When expanded, the full
                        // body is shown full-width below instead (see bodyPreview).
                        if !expanded {
                            Text(header.snippet)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                // Hovering the message area (title or body) expands the card after a
                // one-second dwell; it collapses again only once the pointer leaves the
                // whole card. Leaving the message area cancels a not-yet-fired expand.
                .onHover { hovering in
                    expandTask?.cancel()
                    guard hovering, !expanded else { expandTask = nil; return }
                    expandTask = Task {
                        try? await Task.sleep(for: .seconds(1))
                        if !Task.isCancelled { expanded = true }
                    }
                }
                .onTapGesture { Task { await vm.focusMessage(note) } }

                Button { vm.dismissNotification(note.id) } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if expanded {
                if let invite {
                    inviteSection(invite)
                } else {
                    bodyPreview
                }
            }

            if replying {
                replyEditor
                    .focusWindowOnHover()
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
                .focusWindowOnHover()
            }
        }
        .padding(14)
        .frame(width: expanded ? 460 : 340, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
        .animation(.easeInOut(duration: 0.15), value: expanded)
        // Fetch the full body the first time the card expands; reused on later hovers.
        .task(id: expanded) {
            if expanded, messageBody == nil {
                messageBody = await vm.notificationBody(note)
            }
        }
        // Keep the card up while the mouse is over it; restart its countdown on exit.
        .onHover { hovering in
            if hovering {
                vm.cancelAutoDismiss(note.id)
            } else {
                // Leaving the card collapses the expanded preview and resumes the
                // auto-dismiss countdown (unless an inline reply or an RSVP — a typed
                // note or a response in flight — is in progress).
                expandTask?.cancel()
                expandTask = nil
                let rsvping = inviteSending != nil || !inviteNote.isEmpty
                if !rsvping { expanded = false }
                if !replying && !rsvping { vm.scheduleAutoDismiss(note.id) }
            }
        }
    }

    /// The calendar invite carried by this message (once its body has loaded), for
    /// the kinds the reading pane's card handles too.
    private var invite: CalendarInvite? {
        guard let invite = messageBody?.calendar,
              invite.method == .request || invite.method == .cancel || invite.method == .counter
        else { return nil }
        return invite
    }

    /// The full message rendered in a fixed-height, natively-scrollable web view
    /// (inline images and formatting intact). Shows a brief loading state until the
    /// body has been fetched.
    @ViewBuilder private var bodyPreview: some View {
        Group {
            if let html = messageBody?.html {
                HTMLView(html: html)
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    // MARK: Calendar invite

    /// The expanded preview for an invite message: event details plus the same
    /// affordances as the reading pane's invite card — a note to the organizer,
    /// Accept / Maybe / Decline (a cancellation gets a notice and Delete; a
    /// proposed new time hands off to Google Calendar), and a day timeline with
    /// the user's schedule around the proposed slot.
    @ViewBuilder private func inviteSection(_ invite: CalendarInvite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            inviteDetail("clock", invite.whenText)
            if !invite.location.isEmpty { inviteDetail("mappin.and.ellipse", invite.location) }
            if invite.method != .counter, let organizer = invite.organizer {
                inviteDetail("person.crop.circle", "Organized by \(organizer.display)")
            }

            switch invite.method {
            case .cancel:  inviteCanceledControls
            case .counter: inviteCounterControls(invite)
            default:       inviteRSVPControls(invite)
            }

            if let start = invite.start {
                CalendarDayTimeline(
                    day: start,
                    events: dayEvents,
                    inviteStart: start,
                    inviteEnd: invite.end ?? start.addingTimeInterval(3600)
                )
                .frame(height: 200)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .focusWindowOnHover()
        .task {
            if !dayEventsLoaded {
                dayEventsLoaded = true
                dayEvents = await vm.notificationDayEvents(for: invite, accountId: note.accountId)
            }
        }
    }

    private func inviteDetail(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func inviteRSVPControls(_ invite: CalendarInvite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $inviteNote)
                .font(.body)
                .frame(height: 48)
                .padding(4)
                .overlay(alignment: .topLeading) {
                    if inviteNote.isEmpty {
                        Text("Optional message to organizer")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 9).padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background))
            HStack(spacing: 8) {
                rsvpButton(invite, .accepted, "Accept", "checkmark.circle.fill", .green)
                rsvpButton(invite, .tentative, "Maybe", "questionmark.circle.fill", .orange)
                rsvpButton(invite, .declined, "Decline", "xmark.circle.fill", .red)
            }
        }
    }

    private func rsvpButton(_ invite: CalendarInvite, _ response: InviteResponse,
                            _ title: String, _ symbol: String, _ tint: Color) -> some View {
        Button {
            inviteSending = response
            vm.cancelAutoDismiss(note.id)
            Task {
                let ok = await vm.respondToInvite(invite, response: response, note: inviteNote,
                                                  accountId: note.accountId)
                inviteSending = nil
                // On a sent RSVP the invitation is dealt with — trash it and close
                // the card (same as the reading pane removing the message).
                if ok { await vm.deleteNotification(note) }
            }
        } label: {
            HStack(spacing: 4) {
                if inviteSending == response { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(.small)
        .disabled(inviteSending != nil)
    }

    private var inviteCanceledControls: some View {
        HStack {
            Text("This event was canceled by the organizer.")
                .font(.subheadline).foregroundStyle(.red)
            Spacer()
            Button(role: .destructive) {
                Task { await vm.deleteNotification(note) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }

    private func inviteCounterControls(_ invite: CalendarInvite) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(invite.attendees.first?.display ?? "A guest") proposed a new time.")
                .font(.subheadline)
            Button {
                CalendarLauncher.open(invite.eventURL
                    ?? URL(string: "https://calendar.google.com/calendar/r")!)
                vm.dismissNotification(note.id)
            } label: {
                Label("Open in Google Calendar", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
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

private extension View {
    /// Makes the hosting panel key as soon as the pointer enters, so a control
    /// inside actuates on the *first* click even when newmail is in the background.
    /// Without it, the nonactivating notification panel eats the first click just to
    /// become key, forcing a second click on the button/menu.
    func focusWindowOnHover() -> some View {
        background(WindowKeyOnHover().allowsHitTesting(false))
    }
}

/// Transparent backing view that makes its window key when the mouse enters its
/// bounds. Used to give the new-mail card's action controls single-click response.
private struct WindowKeyOnHover: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HoverFocusView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HoverFocusView: NSView {
        private var tracking: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            if let window, !window.isKeyWindow { window.makeKey() }
        }
    }
}
