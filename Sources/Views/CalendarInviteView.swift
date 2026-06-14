import SwiftUI

/// A calendar-invite card shown above a message body. For a request it shows the
/// event details plus Accept / Maybe / Decline (which send an iCalendar REPLY to
/// the organizer). For a cancellation it shows a notice and a delete action.
struct CalendarInviteView: View {
    let invite: CalendarInvite
    let messageId: String
    @Environment(MailboxViewModel.self) private var vm

    @State private var sending: InviteResponse?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: invite.method == .cancel ? "calendar.badge.minus" : "calendar")
                    .foregroundStyle(invite.method == .cancel ? .red : .accentColor)
                Text(invite.summary).font(.headline).lineLimit(2)
            }

            detail("clock", invite.whenText)
            if !invite.location.isEmpty { detail("mappin.and.ellipse", invite.location) }
            if let organizer = invite.organizer {
                detail("person.crop.circle", "Organized by \(organizer.display)")
            }
            if invite.attendees.count > 1 {
                detail("person.2", "\(invite.attendees.count) attendees")
            }

            if invite.method == .cancel {
                canceledControls
            } else {
                rsvpControls
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        .padding(.horizontal, 16)
    }

    private func detail(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    // MARK: Request — Accept / Maybe / Decline

    private var rsvpControls: some View {
        HStack(spacing: 8) {
            rsvpButton(.accepted, "Accept", "checkmark.circle.fill", .green)
            rsvpButton(.tentative, "Maybe", "questionmark.circle.fill", .orange)
            rsvpButton(.declined, "Decline", "xmark.circle.fill", .red)
        }
        .padding(.top, 4)
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
            let ok = await vm.respondToInvite(invite, response: response)
            sending = nil
            // On a sent RSVP, remove the invitation from the list (and advance
            // the selection to the next message).
            if ok { await vm.deleteMessages([messageId]) }
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
        .padding(.top, 4)
    }
}
