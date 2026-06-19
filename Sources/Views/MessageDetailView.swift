import SwiftUI

/// A message opened in its own resizable window (double-click). Shows the full
/// header and body, reply/forward actions, and an in-message find bar (⌘F) with
/// next/previous navigation. The displayed message is read from `vm.modalHeader`
/// so reopening the window onto another message retargets it in place.
struct MessageDetailView: View {
    @Environment(MailboxViewModel.self) private var vm
    /// Closes the hosting window (Done button / Escape).
    let onClose: () -> Void

    @StateObject private var finder = WebFindController()
    @State private var showFind = false
    @State private var findText = ""
    @FocusState private var findFocused: Bool

    var body: some View {
        if let header = vm.modalHeader {
            content(header)
        } else {
            Color.clear
        }
    }

    private func content(_ header: MessageHeader) -> some View {
        VStack(spacing: 0) {
            toolbar(header)
            Divider()
            if showFind {
                findBar
                Divider()
            }
            headerBlock(header)
            Divider()
            if let invite = inviteForModal(header) {
                CalendarInviteView(invite: invite, messageId: header.id)
                    .padding(.vertical, 10)
                Divider()
            }
            bodyBlock
        }
        .frame(minWidth: 480, minHeight: 360)
    }

    private func toolbar(_ header: MessageHeader) -> some View {
        HStack(spacing: 14) {
            Text(header.subject).font(.headline).lineLimit(1)
            Spacer()
            Button { reply(header, all: false) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help("Reply")
            Button { reply(header, all: true) } label: { Image(systemName: "arrowshape.turn.up.left.2") }
                .help("Reply All")
            Button { forward(header) } label: { Image(systemName: "arrowshape.turn.up.right") }
                .help("Forward")
            Button {
                showFind.toggle()
                if showFind { findFocused = true }
            } label: { Image(systemName: "magnifyingglass") }
                .help("Find in Message (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
            Button("Done") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func headerBlock(_ header: MessageHeader) -> some View {
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
            Text(header.date.mailFullString).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
    }

    /// The invite to show for the opened message (only requests and cancellations).
    private func inviteForModal(_ header: MessageHeader) -> CalendarInvite? {
        guard let body = vm.modalBody, body.headerId == header.id,
              let invite = body.calendar,
              invite.method == .request || invite.method == .cancel else { return nil }
        return invite
    }

    @ViewBuilder
    private var bodyBlock: some View {
        if let body = vm.modalBody {
            HTMLView(html: body.html, finder: finder)
        } else {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        }
    }

    private func reply(_ header: MessageHeader, all: Bool) {
        vm.selection = [header.id]
        vm.startReply(all: all)
    }

    private func forward(_ header: MessageHeader) {
        vm.selection = [header.id]
        vm.startForward()
    }
}
