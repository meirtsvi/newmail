import SwiftUI
import AppKit

/// Right pane: header block (avatar, from/to/date) plus the rendered HTML body,
/// with inline reply/forward controls.
struct MessagePreviewView: View {
    @Environment(MailboxViewModel.self) private var vm
    /// Persisted message-body zoom, driven by ⌘+ / ⌘- / ⌘0.
    @AppStorage("messageZoom") private var zoom: Double = 1.0
    /// Hebrew translate/summarize state for the shown message.
    @State private var translation = BodyTranslationModel()
    /// In-message find (⇧⌘F), mirroring the detail window's find bar.
    @StateObject private var finder = WebFindController()
    @State private var showFind = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    private static let zoomRange = 0.5...3.0

    private var selectedHeader: MessageHeader? {
        guard vm.selection.count == 1, let id = vm.selection.first else { return nil }
        return vm.messages.first { $0.id == id }
    }

    /// The invite to show for this message (requests, cancellations, and
    /// proposed-new-time counters).
    private func inviteFor(_ header: MessageHeader) -> CalendarInvite? {
        guard let body = vm.currentBody, body.headerId == header.id,
              let invite = body.calendar,
              invite.method == .request || invite.method == .cancel
                || invite.method == .counter else { return nil }
        return invite
    }

    var body: some View {
        if let header = selectedHeader {
            VStack(alignment: .leading, spacing: 0) {
                headerBlock(header)
                Divider()
                if showFind {
                    findBar
                    Divider()
                }
                if let invite = inviteFor(header) {
                    CalendarInviteView(invite: invite, messageId: header.id)
                        .padding(.vertical, 10)
                    Divider()
                }
                bodyBlock(header)
            }
            .background(zoomShortcuts)
            .onChange(of: header.id) { _, _ in
                translation.reset()
                finder.status = ""
            }
        } else {
            ContentUnavailableView(
                vm.selection.count > 1 ? "\(vm.selection.count) messages selected" : "No message selected",
                systemImage: "envelope",
                description: Text("Select a message to read it here.")
            )
        }
    }

    /// The in-message find bar shown below the header when ⇧⌘F toggles it on.
    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in message", text: $findText)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { finder.find(findText, forward: true) }
                .frame(maxWidth: 280)
            Button { finder.find(findText, forward: false) } label: { Image(systemName: "chevron.up") }
                .help("Previous")
                .disabled(findText.isEmpty)
            Button { finder.find(findText, forward: true) } label: { Image(systemName: "chevron.down") }
                .help("Next")
                .disabled(findText.isEmpty)
            if !finder.status.isEmpty {
                Text(finder.status).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { showFind = false } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
        .onExitCommand { showFind = false }
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
                if let info = unsubscribeFor(header) {
                    UnsubscribeButton(header: header, info: info)
                }
                Spacer()
                if let body = vm.currentBody, body.headerId == header.id {
                    TranslateControls(model: translation, messageId: body.headerId,
                                      html: body.html, plainText: body.plainText)
                        .foregroundStyle(.secondary)
                }
                replyControls
            }
            recipientsBlock(header)
            if let count = vm.digestSourceCount(for: header) {
                Button(role: .destructive) {
                    Task { await vm.deleteDigestSources(for: header) }
                } label: {
                    Label("Delete source mails (\(count))", systemImage: "trash")
                }
                .help("Trash the \(count) newsletter messages this digest covers")
            }
            if let body = vm.currentBody, !body.attachments.isEmpty {
                AttachmentList(attachments: body.attachments)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// To/Cc recipient chips. The To list lives on the header (always present);
    /// Cc is read from the loaded body for this message.
    @ViewBuilder
    private func recipientsBlock(_ header: MessageHeader) -> some View {
        if !header.to.isEmpty {
            // Key by message so the row's expand/collapse state resets when you
            // switch messages — otherwise a stale "expanded" leaves an empty
            // scroll box (a gap) on the next message's short recipient list.
            RecipientRow(label: "To", addresses: header.to)
                .id("\(header.id)-to")
        }
        let cc = ccFor(header)
        if !cc.isEmpty {
            RecipientRow(label: "Cc", addresses: cc)
                .id("\(header.id)-cc")
        }
    }

    /// Cc recipients for this message, available once its body has loaded.
    private func ccFor(_ header: MessageHeader) -> [MailAddress] {
        guard let body = vm.currentBody, body.headerId == header.id else { return [] }
        return body.cc
    }

    /// Unsubscribe targets for this message, available once its body has loaded.
    private func unsubscribeFor(_ header: MessageHeader) -> UnsubscribeInfo? {
        guard let body = vm.currentBody, body.headerId == header.id else { return nil }
        return body.unsubscribe
    }

    private var replyControls: some View {
        HStack(spacing: 14) {
            ZoomControls(zoom: $zoom, range: Self.zoomRange)
            Divider().frame(height: 16)
            Button { vm.startReply(all: false) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help("Reply")
            Button { vm.startReply(all: true) } label: { Image(systemName: "arrowshape.turn.up.left.2") }
                .help("Reply All")
            Button { vm.startForward() } label: { Image(systemName: "arrowshape.turn.up.right") }
                .help("Forward")
            Divider().frame(height: 16)
            Button { Task { await vm.deleteMessages(Array(vm.selection)) } } label: { Image(systemName: "trash") }
                .help("Delete")
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
            // The 24pt text margin lives inside the page (horizontalMargin), not
            // as SwiftUI padding, so the scrollbar sits at the pane's right edge.
            HTMLView(html: translation.displayHTML(original: body.html), finder: finder, zoom: zoom, horizontalMargin: 24)
        } else if vm.isLoadingBody {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else {
            Color.clear
        }
    }

    /// Zero-size hidden buttons that register the zoom keyboard shortcuts. Both
    /// "+" (⌘⇧=) and "=" map to zoom-in so the unshifted key works too.
    /// ⇧⌘F toggles the in-message find bar.
    private var zoomShortcuts: some View {
        Group {
            Button("") {
                showFind.toggle()
                if showFind { findFocused = true }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
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

/// A "To"/"Cc" label followed by a wrapping run of recipient chips. A long
/// list (e.g. every invitee on a calendar event) collapses to roughly two
/// lines with a "+N more" toggle; left unbounded it grows the header until it
/// overflows the pane and collides with the window toolbar.
private struct RecipientRow: View {
    let label: String
    let addresses: [MailAddress]
    @State private var expanded = false

    /// Above this count the list collapses by default (≈ two lines at a typical
    /// pane width).
    private static let collapsedLimit = 12

    var body: some View {
        let overflow = addresses.count > Self.collapsedLimit
        let shown = (expanded || !overflow) ? addresses : Array(addresses.prefix(Self.collapsedLimit))
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
                .padding(.top, 3)
            chips(shown: shown, overflow: overflow)
        }
    }

    @ViewBuilder
    private func chips(shown: [MailAddress], overflow: Bool) -> some View {
        let layout = FlowLayout(spacing: 6, lineSpacing: 6) {
            // Keyed by position, not by address: a recipient list can repeat
            // the same address (Reply-All / list expansion), and duplicate
            // ids would make SwiftUI drop the repeated chip.
            ForEach(Array(shown.enumerated()), id: \.offset) { _, address in
                RecipientChip(address: address)
            }
            if overflow { moreToggle }
        }
        // Once expanded the full list can be long; let it scroll inside a
        // bounded box rather than pushing the header over the toolbar. Only when
        // there's overflow to scroll — an empty scroll box would leave a gap.
        if expanded && overflow {
            ScrollView(.vertical) { layout }.frame(maxHeight: 160)
        } else {
            layout
        }
    }

    private var moreToggle: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 3) {
                Text(expanded ? "Show less" : "+\(addresses.count - Self.collapsedLimit) more")
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .imageScale(.small)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// Gmail-style Unsubscribe chip next to the sender. Silent unsubscribes
/// (one-click POST or a mailto message) ask for confirmation first; a web-only
/// target just opens the sender's unsubscribe page.
private struct UnsubscribeButton: View {
    @Environment(MailboxViewModel.self) private var vm
    let header: MessageHeader
    let info: UnsubscribeInfo
    @State private var confirming = false

    var body: some View {
        Button {
            if info.oneClick || info.mailto != nil {
                confirming = true
            } else {
                Task { await vm.unsubscribe(from: header, info: info) }
            }
        } label: {
            Text("Unsubscribe")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Unsubscribe from this mailing list")
        .confirmationDialog("Unsubscribe from \(header.from.display)?",
                            isPresented: $confirming) {
            Button("Unsubscribe") {
                Task { await vm.unsubscribe(from: header, info: info) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You’ll stop receiving messages from this mailing list.")
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
                // Cap the width so a very long sender name ellipsizes instead of
                // pushing the reply/zoom controls off the right edge of the pane;
                // no .fixedSize so it can compress further when the pane is narrow.
                .frame(maxWidth: 260, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
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
