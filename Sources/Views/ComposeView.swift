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
    @State private var loadingAttachments = false
    @State private var sending = false
    @State private var showImporter = false
    @State private var showLinkPrompt = false
    @State private var linkURL = ""
    @State private var fontFamily = RichTextController.systemFamily
    @State private var fontSize: CGFloat = NSFont.systemFontSize
    /// Snapshot of the fields at the last successful draft save, so the 10-second
    /// autosave skips when nothing has changed.
    @State private var lastSavedSnapshot = ""
    /// Shared keyboard focus across the To/Cc/Subject fields so Tab and Shift-Tab
    /// move between them in order; the body editor is reached via `rich`.
    @FocusState private var focus: ComposeField?

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            fields
            Divider()
            formattingBar
            RichTextEditor(controller: rich)
                .frame(minHeight: 160)
            if !attachments.isEmpty || loadingAttachments {
                Divider()
                attachmentBar
            }
            if !request.quotedHTML.isEmpty {
                Divider()
                quotedPreview
            }
        }
        .frame(width: 640, height: request.quotedHTML.isEmpty ? 560 : 680)
        .onAppear {
            // Shift-Tab out of the body editor returns to the Subject field.
            rich.onShiftTab = { focus = .subject }
            // The quoted original is no longer dropped into the editor (the HTML
            // round-trip degraded its formatting). It's shown read-only below and
            // appended verbatim at send time; the editor holds only the new reply.
            if !request.body.isEmpty {
                rich.setInitial(NSAttributedString(
                    string: request.body,
                    attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
                ))
            }
            // Carry the original message's attachments when forwarding.
            if !request.attachments.isEmpty {
                loadingAttachments = true
                Task {
                    let urls = await vm.materializeAttachments(request.attachments)
                    attachments.append(contentsOf: urls)
                    loadingAttachments = false
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { attachments.append(contentsOf: urls) }
        }
        .sheet(isPresented: $showLinkPrompt) { linkPrompt }
        .background {
            // ⌘S saves the draft immediately; the hidden button just carries the shortcut.
            Button("") { Task { await autosaveDraft() } }
                .keyboardShortcut("s", modifiers: .command)
                .hidden()
        }
        // Autosave the draft to the server every 10 seconds while composing; the
        // task is cancelled automatically when the window closes.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                await autosaveDraft()
            }
        }
    }

    /// True once there's anything worth keeping (recipients, subject, or body).
    private var hasDraftContent: Bool {
        !request.to.isEmpty || !request.cc.isEmpty
            || !request.subject.isEmpty || !rich.exportHTML().isEmpty
    }

    /// Saves the in-progress message as a server draft if it has content and has
    /// changed since the last save. Records the returned draft id on the request so
    /// later saves replace it and it can be deleted on send.
    private func autosaveDraft() async {
        guard !sending, hasDraftContent else { return }
        let html = composedHTML()
        let snapshot = [request.to, request.cc, request.subject, html].joined(separator: "\u{1}")
        guard snapshot != lastSavedSnapshot else { return }
        let id = await vm.saveDraft(
            to: request.to, cc: request.cc, subject: request.subject,
            html: html, attachments: attachments, draftId: request.draftId
        )
        request.draftId = id
        lastSavedSnapshot = snapshot
    }

    private var titleBar: some View {
        HStack {
            Text(request.kind.title).font(.headline)
            Spacer()
            Button("Cancel") { dismiss() }
            Button {
                sending = true
                let html = composedHTML()
                Task {
                    await vm.sendComposed(
                        to: request.to, cc: request.cc, subject: request.subject,
                        html: html, attachments: attachments, draftId: request.draftId
                    )
                    sending = false
                    dismiss()
                }
            } label: {
                if sending { ProgressView().controlSize(.small) }
                else { Label("Send", systemImage: "paperplane.fill") }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(request.to.isEmpty || sending || loadingAttachments)
        }
        .padding()
    }

    private var fields: some View {
        VStack(spacing: 8) {
            RecipientField(title: "To", text: $request.to,
                           suggest: vm.contactSuggestions, focus: $focus,
                           field: .to, next: .cc, focusOnAppear: true)
            RecipientField(title: "Cc", text: $request.cc,
                           suggest: vm.contactSuggestions, focus: $focus,
                           field: .cc, next: .subject, previous: .to)
            HStack(spacing: 8) {
                Text("Subject")
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                TextField("", text: $request.subject)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .subject)
                    // Tab or Return from the subject jumps straight to the body,
                    // skipping the bold/italic/underline/link/attach buttons;
                    // Shift-Tab goes back to the Cc field.
                    .onKeyPress(keys: [.tab], phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            focus = .cc
                            return .handled
                        }
                        focusBody()
                        return .handled
                    }
                    .onKeyPress(.return) {
                        focusBody()
                        return .handled
                    }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        // Keep the autocomplete dropdown above the formatting bar and editor.
        .zIndex(1)
    }

    /// Moves keyboard focus from a compose field into the body editor. The SwiftUI
    /// focus is released first, then the body is made first responder on the next
    /// runloop — otherwise SwiftUI's focus pass runs afterwards and steals it back.
    private func focusBody() {
        focus = nil
        DispatchQueue.main.async { rich.focus() }
    }

    private var formattingBar: some View {
        HStack(spacing: 12) {
            Button { rich.toggleBold() } label: { Image(systemName: "bold") }.help("Bold")
            Button { rich.toggleItalic() } label: { Image(systemName: "italic") }.help("Italic")
            Button { rich.toggleUnderline() } label: { Image(systemName: "underline") }.help("Underline")
            Button { showLinkPrompt = true } label: { Image(systemName: "link") }.help("Insert link")
            Divider().frame(height: 16)
            fontPickers
            Divider().frame(height: 16)
            Button { showImporter = true } label: { Image(systemName: "paperclip") }.help("Attach file")
            Spacer()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// Font-family and size pickers; selecting one applies it to the selected text
    /// (or to subsequent typing when nothing is selected).
    private var fontPickers: some View {
        HStack(spacing: 6) {
            Picker("Font", selection: $fontFamily) {
                ForEach(RichTextController.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 130)
            .onChange(of: fontFamily) { _, family in rich.setFontFamily(family) }

            Picker("Size", selection: $fontSize) {
                ForEach(RichTextController.fontSizes, id: \.self) { Text("\(Int($0))").tag($0) }
            }
            .labelsHidden()
            .frame(width: 60)
            .onChange(of: fontSize) { _, size in rich.setFontSize(size) }
        }
        .font(.body)
    }

    private var attachmentBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                if loadingAttachments {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Attaching…").lineLimit(1)
                    }
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                }
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

    /// Read-only, faithful render of the original message that will be quoted. It
    /// is not editable (so its formatting can't be degraded); it's appended exactly
    /// as-is when sending.
    private var quotedPreview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(request.kind == .forward ? "Forwarded message" : "Original message")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 6)
            HTMLView(html: request.quotedHTML)
                .frame(height: 180)
        }
    }

    /// The reply the user typed, followed by the original message appended verbatim
    /// so its formatting (and inline images) survive intact.
    private func composedHTML() -> String {
        let userHTML = rich.exportHTML()
        guard !request.quotedHTML.isEmpty else { return userHTML }
        let userInner = PlainTextHTML.bodyFragment(userHTML)
        return "<html><head><meta charset=\"utf-8\"></head><body>\(userInner)\(request.quotedHTML)</body></html>"
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
