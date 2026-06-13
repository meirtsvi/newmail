import SwiftUI
import UniformTypeIdentifiers

/// Compose window for new mail, reply, reply-all, and forward. Rich HTML body
/// (bold/italic/underline/link) plus file attachments; the body is exported to
/// HTML and sent as multipart/mixed via Gmail.
struct ComposeView: View {
    @Environment(MailboxViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @Bindable var request: ComposeRequest

    @StateObject private var rich = RichTextController()
    @State private var attachments: [URL] = []
    @State private var sending = false
    @State private var showImporter = false
    @State private var showLinkPrompt = false
    @State private var linkURL = ""

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            fields
            Divider()
            formattingBar
            RichTextEditor(controller: rich)
                .frame(minHeight: 240)
            if !attachments.isEmpty {
                Divider()
                attachmentBar
            }
        }
        .frame(width: 640, height: 560)
        .onAppear {
            if !request.quotedHTML.isEmpty {
                // Render the original message as a rich preview in the editable body.
                let wrapped = "<br><br>\(request.quotedHTML)"
                if let data = wrapped.data(using: .utf8),
                   let attr = try? NSAttributedString(
                       data: data,
                       options: [.documentType: NSAttributedString.DocumentType.html,
                                 .characterEncoding: String.Encoding.utf8.rawValue],
                       documentAttributes: nil
                   ) {
                    rich.setInitial(attr)
                }
            } else if !request.body.isEmpty {
                rich.setInitial(NSAttributedString(
                    string: request.body,
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
                ))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachments.append(contentsOf: urls) }
        }
        .sheet(isPresented: $showLinkPrompt) { linkPrompt }
    }

    private var titleBar: some View {
        HStack {
            Text(request.kind.title).font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                sending = true
                let html = rich.exportHTML()
                Task {
                    await vm.sendComposed(
                        to: request.to, cc: request.cc, subject: request.subject,
                        html: html, attachments: attachments
                    )
                    sending = false
                    dismiss()
                }
            } label: {
                if sending { ProgressView().controlSize(.small) }
                else { Label("Send", systemImage: "paperplane.fill") }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(request.to.isEmpty || sending)
        }
        .padding()
    }

    private var fields: some View {
        Form {
            TextField("To", text: $request.to)
            TextField("Cc", text: $request.cc)
            TextField("Subject", text: $request.subject)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var formattingBar: some View {
        HStack(spacing: 12) {
            Button { rich.toggleBold() } label: { Image(systemName: "bold") }.help("Bold")
            Button { rich.toggleItalic() } label: { Image(systemName: "italic") }.help("Italic")
            Button { rich.toggleUnderline() } label: { Image(systemName: "underline") }.help("Underline")
            Button { showLinkPrompt = true } label: { Image(systemName: "link") }.help("Insert link")
            Divider().frame(height: 16)
            Button { showImporter = true } label: { Image(systemName: "paperclip") }.help("Attach file")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(attachments, id: \.self) { url in
                    HStack(spacing: 4) {
                        Image(systemName: "doc")
                        Text(url.lastPathComponent).lineLimit(1)
                        Button {
                            attachments.removeAll { $0 == url }
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 36)
    }

    private var linkPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Insert link").font(.headline)
            Text("Select text in the body first, then enter a URL.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("https://…", text: $linkURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { showLinkPrompt = false; linkURL = "" }
                Button("Add") {
                    rich.applyLink(linkURL)
                    showLinkPrompt = false
                    linkURL = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(linkURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
