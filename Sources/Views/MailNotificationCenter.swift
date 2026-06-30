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
                    let preset: CalendarReminderService.SnoozePreset =
                        toStart <= 0 ? .fiveMin : (toStart < 5 * 60 ? .atEventTime : .beforeStart)
                    Menu(preset.rawValue) {
                        ForEach(CalendarReminderService.SnoozePreset.allCases) { preset in
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
/// expands into an inline plain-text reply editor.
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
    /// The fetched full-message HTML body shown when expanded; nil until first loaded.
    @State private var bodyHTML: String?
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
                bodyPreview
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
        .frame(width: expanded ? 460 : 340, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.20), radius: 12, y: 5)
        .animation(.easeInOut(duration: 0.15), value: expanded)
        // Fetch the full body the first time the card expands; reused on later hovers.
        .task(id: expanded) {
            if expanded, bodyHTML == nil {
                bodyHTML = await vm.notificationBodyHTML(note)
            }
        }
        // Keep the card up while the mouse is over it; restart its countdown on exit.
        .onHover { hovering in
            if hovering {
                vm.cancelAutoDismiss(note.id)
            } else {
                // Leaving the card collapses the expanded preview and resumes the
                // auto-dismiss countdown (unless an inline reply is in progress).
                expandTask?.cancel()
                expandTask = nil
                expanded = false
                if !replying { vm.scheduleAutoDismiss(note.id) }
            }
        }
    }

    /// The full message rendered in a fixed-height, natively-scrollable web view
    /// (inline images and formatting intact). Shows a brief loading state until the
    /// body has been fetched.
    @ViewBuilder private var bodyPreview: some View {
        Group {
            if let bodyHTML {
                HTMLView(html: bodyHTML)
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
