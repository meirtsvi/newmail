import SwiftUI
import UniformTypeIdentifiers

/// Attachment chips for a message: each shows the file-type icon, name and size,
/// with a chevron menu (Preview / Open / Download). A Download All • Preview All
/// row sits beneath. Clicking a chip Quick Looks it.
struct AttachmentList: View {
    let attachments: [MailAttachment]
    @Environment(MailboxViewModel.self) private var vm

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 300), spacing: 8, alignment: .leading)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(attachments) { att in chip(att) }
            }
            HStack(spacing: 8) {
                Button("Download All") { Task { await vm.downloadAllAttachments(attachments) } }
                Text("•").foregroundStyle(.secondary)
                Button("Preview All") { Task { await vm.previewAttachments(attachments) } }
            }
            .buttonStyle(.link)
            .font(.callout)
        }
    }

    private func chip(_ att: MailAttachment) -> some View {
        HStack(spacing: 8) {
            Button {
                Task { await vm.previewAttachments(attachments, start: att) }
            } label: {
                HStack(spacing: 8) {
                    Image(nsImage: fileIcon(att))
                        .resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(att.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                        Text(sizeString(att.sizeBytes)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick Look \(att.filename)")

            Divider().frame(height: 28)

            Menu {
                Button("Preview") { Task { await vm.previewAttachments(attachments, start: att) } }
                Button("Open") { Task { await vm.openAttachment(att) } }
                Button("Download") { Task { await vm.downloadAttachment(att) } }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Attachment actions")
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }

    private func fileIcon(_ att: MailAttachment) -> NSImage {
        let ext = (att.filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: type)
        }
        if let type = UTType(mimeType: att.mimeType) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private func sizeString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
