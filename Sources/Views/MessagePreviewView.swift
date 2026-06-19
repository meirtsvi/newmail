import SwiftUI
import AppKit

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
                    .textSelection(.enabled)
                Spacer()
                Text(header.date.mailFullString)
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Avatar(address: header.from)
                FromField(address: header.from)
                Spacer()
                replyControls
            }
            recipientsBlock(header)
            if let body = vm.currentBody, !body.attachments.isEmpty {
                AttachmentList(attachments: body.attachments)
            }
        }
        .padding(16)
    }

    /// To/Cc recipient chips. The To list lives on the header (always present);
    /// Cc is read from the loaded body for this message.
    @ViewBuilder
    private func recipientsBlock(_ header: MessageHeader) -> some View {
        if !header.to.isEmpty {
            RecipientRow(label: "To", addresses: header.to)
        }
        let cc = ccFor(header)
        if !cc.isEmpty {
            RecipientRow(label: "Cc", addresses: cc)
        }
    }

    /// Cc recipients for this message, available once its body has loaded.
    private func ccFor(_ header: MessageHeader) -> [MailAddress] {
        guard let body = vm.currentBody, body.headerId == header.id else { return [] }
        return body.cc
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

/// A "To"/"Cc" label followed by a wrapping run of recipient chips.
private struct RecipientRow: View {
    let label: String
    let addresses: [MailAddress]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
                .padding(.top, 3)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                // Keyed by position, not by address: a recipient list can repeat
                // the same address (Reply-All / list expansion), and duplicate
                // ids would make SwiftUI drop the repeated chip.
                ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                    RecipientChip(address: address)
                }
            }
        }
    }
}

/// The sender's name in the header block; clicking opens a menu to copy the
/// address or start a new message to it, matching the recipient chips.
private struct FromField: View {
    @Environment(MailboxViewModel.self) private var vm
    let address: MailAddress

    var body: some View {
        Menu {
            Text(address.nameAndEmail)
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address.email, forType: .string)
            }
            Button("New Message") { vm.startNewMail(to: address.email) }
        } label: {
            Text(address.display)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(address.nameAndEmail)
    }
}

/// A single recipient as a capsule chip; clicking opens a menu to copy the
/// address or start a new message to it.
private struct RecipientChip: View {
    @Environment(MailboxViewModel.self) private var vm
    let address: MailAddress

    var body: some View {
        Menu {
            Text(address.nameAndEmail)
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(address.email, forType: .string)
            }
            Button("New Message") { vm.startNewMail(to: address.email) }
        } label: {
            Text(address.display)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                // Cap the width so a very long single name ellipsizes instead of
                // overflowing the chip (`.fixedSize` below otherwise ignores the
                // line limit and lets it run off the pane edge).
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(address.nameAndEmail)
    }
}

/// Minimal wrapping layout: places children left-to-right, wrapping to a new
/// line when the next child would overflow the proposed width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > bounds.width {
                x = 0; y += lineHeight + lineSpacing; lineHeight = 0
            }
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                      anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
