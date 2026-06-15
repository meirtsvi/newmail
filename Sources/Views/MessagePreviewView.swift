import SwiftUI

/// Right pane: header block (avatar, from/to/date) plus the rendered HTML body,
/// with inline reply/forward controls.
struct MessagePreviewView: View {
    @Environment(MailboxViewModel.self) private var vm
    /// Persisted message-body zoom, driven by ⌘+ / ⌘- / ⌘0.
    @AppStorage("messageZoom") private var zoom: Double = 1.0

    private static let zoomRange = 0.5...3.0

    private var selectedHeader: MessageHeader? {
        guard vm.selection.count == 1, let id = vm.selection.first else { return nil }
        return vm.messages.first { $0.id == id }
    }

    /// The invite to show for this message (only requests and cancellations).
    private func inviteFor(_ header: MessageHeader) -> CalendarInvite? {
        guard let body = vm.currentBody, body.headerId == header.id,
              let invite = body.calendar,
              invite.method == .request || invite.method == .cancel else { return nil }
        return invite
    }

    var body: some View {
        if let header = selectedHeader {
            VStack(alignment: .leading, spacing: 0) {
                headerBlock(header)
                Divider()
                if let invite = inviteFor(header) {
                    CalendarInviteView(invite: invite, messageId: header.id)
                        .padding(.vertical, 10)
                    Divider()
                }
                bodyBlock(header)
            }
            .background(zoomShortcuts)
        } else {
            ContentUnavailableView(
                vm.selection.count > 1 ? "\(vm.selection.count) messages selected" : "No message selected",
                systemImage: "envelope",
                description: Text("Select a message to read it here.")
            )
        }
    }

    private func headerBlock(_ header: MessageHeader) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(header.subject).font(.title3.weight(.semibold))
                Spacer()
                Text(header.date.mailFullString)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Avatar(address: header.from)
                VStack(alignment: .leading, spacing: 2) {
                    Text(header.from.display).font(.body.weight(.semibold))
                    if !header.to.isEmpty {
                        Text("To: \(header.to.map(\.display).joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                replyControls
            }
            if let body = vm.currentBody, !body.attachments.isEmpty {
                AttachmentList(attachments: body.attachments)
            }
        }
        .padding(16)
    }

    private var replyControls: some View {
        HStack(spacing: 14) {
            Button { vm.startReply(all: false) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help("Reply")
            Button { vm.startReply(all: true) } label: { Image(systemName: "arrowshape.turn.up.left.2") }
                .help("Reply All")
            Button { vm.startForward() } label: { Image(systemName: "arrowshape.turn.up.right") }
                .help("Forward")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func bodyBlock(_ header: MessageHeader) -> some View {
        // Show the body the moment we have it for this message (from cache it's
        // instant); the spinner only appears while fetching with nothing to show.
        if let body = vm.currentBody, body.headerId == header.id {
            HTMLView(html: body.html, zoom: zoom)
        } else if vm.isLoadingBody {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else {
            Color.clear
        }
    }

    /// Zero-size hidden buttons that register the zoom keyboard shortcuts. Both
    /// "+" (⌘⇧=) and "=" map to zoom-in so the unshifted key works too.
    private var zoomShortcuts: some View {
        Group {
            Button("") { zoom = min(Self.zoomRange.upperBound, zoom + 0.1) }
                .keyboardShortcut("+", modifiers: .command)
            Button("") { zoom = min(Self.zoomRange.upperBound, zoom + 0.1) }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { zoom = max(Self.zoomRange.lowerBound, zoom - 0.1) }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { zoom = 1.0 }
                .keyboardShortcut("0", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}
