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
