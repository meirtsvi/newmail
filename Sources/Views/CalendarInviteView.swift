import SwiftUI

/// A calendar-invite card shown above a message body. For a request it shows the
/// event details, an optional note to the organizer, Accept / Maybe / Decline
/// (which send an iCalendar REPLY and remove the message), and a scrollable day
/// timeline with the user's Google Calendar schedule. For a cancellation it
/// shows a notice and a delete action.
struct CalendarInviteView: View {
    let invite: CalendarInvite
    let messageId: String
    @Environment(MailboxViewModel.self) private var vm

    @State private var sending: InviteResponse?
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            details
            switch invite.method {
            case .cancel:  canceledControls
            case .counter: counterControls
            default:       rsvpSection
            }
            if invite.start != nil {
                timelineSection
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .padding(.horizontal, 16)
    }

    // MARK: Event details

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: titleSymbol)
                    .foregroundStyle(invite.method == .cancel ? .red : .accentColor)
                Text(invite.summary).font(.headline).lineLimit(2)
            }
            detail("clock", invite.whenText)
            if !invite.location.isEmpty { detail("mappin.and.ellipse", invite.location) }
            // A counter's organizer is the recipient themselves, so "Organized by
            // (you)" is just noise — the proposer is named in the controls instead.
            if invite.method != .counter, let organizer = invite.organizer {
                detail("person.crop.circle", "Organized by \(organizer.display)")
            }
            if invite.attendees.count > 1 {
                detail("person.2", "\(invite.attendees.count) attendees")
            }
        }
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private var titleSymbol: String {
        switch invite.method {
        case .cancel:  return "calendar.badge.minus"
        case .counter: return "calendar.badge.clock"
        default:       return "calendar"
        }
    }

    // MARK: Counter (proposed new time)

    /// A guest proposed a different time. We can't accept it over email (the user
    /// is the organizer, and only their calendar can move the event), so the card
    /// shows the proposed slot and hands off to Google Calendar to accept or pick
    /// another time. See the design note in the model's `Method.counter`.
    private var counterControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let proposer = invite.attendees.first {
                Text("\(proposer.display) proposed a new time.")
                    .font(.subheadline)
            } else {
                Text("A guest proposed a new time.").font(.subheadline)
            }
            Button {
                CalendarLauncher.open(invite.eventURL
                    ?? URL(string: "https://calendar.google.com/calendar/r")!)
            } label: {
                Label("Open in Google Calendar", systemImage: "calendar")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("Accept the proposed time or choose another in Google Calendar.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: RSVP

    private var rsvpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RSVP to this event").font(.headline)
            noteBox
            rsvpControls
        }
    }

    private var noteBox: some View {
        TextEditor(text: $note)
            .font(.body)
            .frame(height: 60)
            .padding(4)
            .overlay(alignment: .topLeading) {
                if note.isEmpty {
                    Text("Optional message to organizer")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9).padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 6).fill(.background))
    }

    private var rsvpControls: some View {
        HStack(spacing: 8) {
            rsvpButton(.accepted, "Accept", "checkmark.circle.fill", .green)
            rsvpButton(.tentative, "Maybe", "questionmark.circle.fill", .orange)
            rsvpButton(.declined, "Decline", "xmark.circle.fill", .red)
        }
    }

    private func rsvpButton(_ response: InviteResponse, _ title: String, _ symbol: String, _ tint: Color) -> some View {
        Button {
            respond(response)
        } label: {
            HStack(spacing: 4) {
                if sending == response { ProgressView().controlSize(.small) }
                else { Image(systemName: symbol) }
                Text(title)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .disabled(sending != nil)
    }

    private func respond(_ response: InviteResponse) {
        sending = response
        Task {
            let ok = await vm.respondToInvite(invite, response: response, note: note)
            sending = nil
            // On a sent RSVP, remove the invitation and advance the selection.
            if ok { await vm.deleteMessages([messageId]) }
        }
    }

    // MARK: Timeline

    private var dayEvents: [CalEvent] {
        vm.inviteContextHeaderId == messageId ? vm.inviteDayEvents : []
    }

    @ViewBuilder
    private var timelineSection: some View {
        let mine = vm.inviteContextHeaderId == messageId
        VStack(alignment: .leading, spacing: 6) {
            if mine && vm.inviteNeedsCalendarAuth {
                VStack(alignment: .leading, spacing: 4) {
                    Button {
                        Task { await vm.connectGoogleCalendar(forHeaderId: messageId, invite: invite) }
                    } label: {
                        Label("Connect Google Calendar", systemImage: "calendar.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    Text("See your schedule and conflicts next to invitations.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if mine, let error = vm.inviteEventsError {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Couldn’t load your calendar").font(.caption.weight(.medium))
                        Button("Retry") {
                            Task { await vm.loadInviteContext(headerId: messageId, invite: invite) }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                    Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            CalendarDayTimeline(
                day: invite.start ?? Date(),
                events: dayEvents,
                inviteStart: invite.start,
                inviteEnd: invite.end ?? invite.start?.addingTimeInterval(3600)
            )
            .frame(height: 260)
            .overlay(alignment: .center) {
                if vm.inviteEventsLoading && mine {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    // MARK: Cancellation

    private var canceledControls: some View {
        HStack {
            Text("This event was canceled by the organizer.")
                .font(.subheadline).foregroundStyle(.red)
            Spacer()
            Button(role: .destructive) {
                Task { await vm.deleteMessages([messageId]) }
            } label: {
                Label("Delete message", systemImage: "trash")
            }
            .buttonStyle(.bordered)
        }
    }
}
