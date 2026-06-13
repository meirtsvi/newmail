import SwiftUI

/// Right pane: header block (avatar, from/to/date) plus the rendered HTML body,
/// with inline reply/forward controls.
struct MessagePreviewView: View {
    @Environment(MailboxViewModel.self) private var vm

    private var selectedHeader: MessageHeader? {
        guard vm.selection.count == 1, let id = vm.selection.first else { return nil }
        return vm.messages.first { $0.id == id }
    }

    var body: some View {
        if let header = selectedHeader {
            VStack(alignment: .leading, spacing: 0) {
                headerBlock(header)
                Divider()
                bodyBlock
            }
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
                attachments(body.attachments)
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

    private func attachments(_ items: [MailAttachment]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(items) { att in
                    Label(att.filename, systemImage: "paperclip")
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var bodyBlock: some View {
        if vm.isLoadingBody {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity)
        } else if let body = vm.currentBody {
            HTMLView(html: body.html)
        } else {
            Color.clear
        }
    }
}
