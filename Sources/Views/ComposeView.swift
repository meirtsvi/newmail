import SwiftUI
import UniformTypeIdentifiers

/// Compose window for new mail, reply, reply-all, and forward. Rich HTML body
/// (bold/italic/underline/link) plus file attachments; the body is exported to
/// HTML and sent as multipart/mixed via Gmail.
struct ComposeView: View {
    @Environment(MailboxViewModel.self) private var vm
    @Bindable var request: ComposeRequest
    /// Closes the compose window (it lives in its own non-modal NSWindow, so there's
    /// no SwiftUI `dismiss` to fall back on).
    let onClose: () -> Void

    @StateObject private var rich = RichTextController()
    /// WebView-based editor used only for "Edit message", where the original HTML's
    /// formatting (fonts, sizes, bold, spacing, inline images) must survive intact —
    /// the NSAttributedString round-trip behind `rich` would degrade it.
    @StateObject private var htmlEditor = HTMLEditorController()
    @State private var attachments: [URL] = []
    @State private var loadingAttachments = false
    @State private var sending = false
    @State private var showImporter = false
    @State private var showLinkPrompt = false
    @State private var linkURL = ""
    @State private var fontFamily = RichTextController.defaultFamily
    @State private var fontSize: CGFloat = RichTextController.defaultSize
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
            if request.kind == .edit {
                // Edit in place on the real HTML so the message keeps its formatting.
                HTMLEditorView(html: request.bodyHTML, controller: htmlEditor)
                    .frame(minHeight: 240)
            } else {
                formattingBar
                RichTextEditor(controller: rich)
                    .frame(minHeight: 160)
            }
            if !attachments.isEmpty || !rich.inlineImages.isEmpty || loadingAttachments {
                Divider()
                attachmentBar
            }
            if !request.quotedHTML.isEmpty {
                Divider()
                quotedPreview
            }
        }
        .frame(minWidth: 480, idealWidth: 640, minHeight: 380,
               idealHeight: request.quotedHTML.isEmpty ? 560 : 680)
        .onAppear {
            // Shift-Tab out of the body editor returns to the Subject field.
            rich.onShiftTab = { focus = .subject }
            // A non-image file pasted or dropped into the body (e.g. a PDF) is
            // added as a real attachment rather than inlined as a picture.
            rich.onAttachFiles = { urls in attachments.append(contentsOf: urls) }
            // The quoted original is no longer dropped into the editor (the HTML
            // round-trip degraded its formatting). It's shown read-only below and
            // appended verbatim at send time; the editor holds only the new reply.
            if request.kind == .edit {
                // The WebView editor loads the original HTML itself; `rich` is unused.
            } else if !request.bodyHTML.isEmpty {
                // Continuing a saved draft: load its HTML as editable rich text.
                rich.setInitialHTML(request.bodyHTML)
            } else if !request.body.isEmpty {
                rich.setInitial(NSAttributedString(
                    string: request.body,
                    attributes: [.font: RichTextController.defaultFont]
                ))
            }
            // Carry the original message's attachments when forwarding or continuing
            // a draft; seed the draft autosave baseline once they're in place.
            if !request.attachments.isEmpty {
                loadingAttachments = true
                Task {
                    let urls = await vm.materializeAttachments(request.attachments)
                    attachments.append(contentsOf: urls)
                    loadingAttachments = false
                    seedDraftBaseline()
                }
            } else {
                seedDraftBaseline()
            }
        }
        // A draft save changes the underlying message (Gmail re-versions it, Graph
        // recreates it), which the in-place list merge can't reconcile. Reload the
        // Drafts list when this window closes so its rows reopen to the live message.
        .onDisappear {
            Task { await vm.reloadDraftsAfterCompose() }
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
            // Escape closes the window, saving whatever's been typed as a draft
            // first so it isn't lost. (When the autocomplete dropdown is open,
            // RecipientField consumes Escape to dismiss it before it reaches here.)
            Button("") { closeKeepingDraft() }
                .keyboardShortcut(.cancelAction)
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
        !request.to.isEmpty || !request.cc.isEmpty || !request.subject.isEmpty
            || !attachments.isEmpty || !rich.exportHTML().isEmpty
    }

    /// Change-detection key for autosave. Includes the attachment list so adding or
    /// removing a file — which doesn't alter the body HTML — still triggers a save.
    private func draftSnapshot(html: String) -> String {
        [request.to, request.cc, request.subject, html,
         attachments.map(\.path).joined(separator: ",")].joined(separator: "\u{1}")
    }

    /// For a reopened draft, records the loaded state as the autosave baseline so the
    /// first autosave fires only once the user actually changes something (otherwise
    /// merely opening a draft would re-save it — needless churn, and on Graph it
    /// recreates the message with a new id).
    private func seedDraftBaseline() {
        guard request.kind == .draft else { return }
        lastSavedSnapshot = draftSnapshot(html: composedBody().html)
    }

    /// Saves the in-progress message as a server draft if it has content and has
    /// changed since the last save. Records the returned draft id on the request so
    /// later saves replace it and it can be deleted on send.
    private func autosaveDraft() async {
        // Editing replaces a message on Save; it must never spawn drafts.
        guard request.kind != .edit else { return }
        guard !sending, hasDraftContent else { return }
        let (html, inlineImages) = composedBody()
        let snapshot = draftSnapshot(html: html)
        guard snapshot != lastSavedSnapshot else { return }
        let id = await vm.saveDraft(
            to: request.to, cc: request.cc, subject: request.subject,
            html: html, attachments: attachments, inlineImages: inlineImages, draftId: request.draftId
        )
        request.draftId = id
        lastSavedSnapshot = snapshot
    }

    /// Escape handler: persist whatever's been typed as a draft (if anything),
    /// then close the window — so dismissing never loses work.
    private func closeKeepingDraft() {
        Task {
            await autosaveDraft()
            onClose()
        }
    }

    private var titleBar: some View {
        HStack {
            Text(request.kind.title).font(.headline)
            Spacer()
            Button("Cancel") { onClose() }
            if request.kind == .edit { saveButton } else { sendButton }
        }
        .padding()
    }

    private var sendButton: some View {
        Button {
            sending = true
            let (html, inlineImages) = composedBody()
            Task {
                await vm.sendComposed(
                    to: request.to, cc: request.cc, subject: request.subject,
                    html: html, attachments: attachments, inlineImages: inlineImages, draftId: request.draftId
                )
                sending = false
                onClose()
            }
        } label: {
            if sending { ProgressView().controlSize(.small) }
            else { Label("Send", systemImage: "paperplane.fill") }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(request.to.isEmpty || sending || loadingAttachments)
    }

    /// Editing replaces the original message with an edited copy (messages are
    /// immutable on the server), so the primary action is Save, not Send.
    private var saveButton: some View {
        Button {
            sending = true
            Task {
                // Pull the edited document straight from the WebView, then re-embed
                // its inline images as related parts so the stored copy is a normal
                // email rather than one carrying giant data: URIs.
                let rawHTML = await htmlEditor.exportHTML()
                let (html, inlineImages) = MIMEBuilder.extractDataURIImages(from: rawHTML)
                await vm.saveEditedMessage(request, html: html, attachments: attachments, inlineImages: inlineImages)
                sending = false
                onClose()
            }
        } label: {
            if sending { ProgressView().controlSize(.small) }
            else { Label("Save", systemImage: "checkmark") }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(sending || loadingAttachments)
    }

    private var fields: some View {
        VStack(spacing: 8) {
            // When editing a message only Subject + body change; recipients are
            // shown for context but kept as-is.
            RecipientField(title: "To", text: $request.to,
                           suggest: vm.contactSuggestions, focus: $focus,
                           field: .to, next: .cc, focusOnAppear: true)
                .disabled(request.kind == .edit)
            RecipientField(title: "Cc", text: $request.cc,
                           suggest: vm.contactSuggestions, focus: $focus,
                           field: .cc, next: .subject, previous: .to)
                .disabled(request.kind == .edit)
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
            colorMenu
            Button { showLinkPrompt = true } label: { Image(systemName: "link") }.help("Insert link")
            Divider().frame(height: 16)
            Button { rich.alignLeft() } label: { Image(systemName: "text.alignleft") }.help("Align left")
            Button { rich.alignRight() } label: { Image(systemName: "text.alignright") }.help("Align right")
            Button { rich.makeLeftToRight() } label: { Image(systemName: "arrow.right") }.help("Left-to-right")
            Button { rich.makeRightToLeft() } label: { Image(systemName: "arrow.left") }.help("Right-to-left")
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

    /// A short palette of text colors offered in the compose toolbar.
    private static let textColors: [(name: String, color: NSColor)] = [
        ("Automatic", .textColor), ("Gray", .systemGray), ("Red", .systemRed),
        ("Orange", .systemOrange), ("Green", .systemGreen),
        ("Blue", .systemBlue), ("Purple", .systemPurple),
    ]

    /// A simple menu of preset text colors; picking one applies it to the selected
    /// text (or to subsequent typing when nothing is selected).
    private var colorMenu: some View {
        Menu {
            ForEach(Self.textColors, id: \.name) { item in
                Button {
                    rich.setFontColor(item.color)
                } label: {
                    // SwiftUI menus strip tint off symbol images, so feed a
                    // pre-colored swatch image instead of a tinted SF Symbol.
                    Label {
                        Text(item.name)
                    } icon: {
                        Image(nsImage: Self.colorSwatch(item.color))
                    }
                }
            }
        } label: {
            Image(systemName: "textformat")
        }
        .menuIndicator(.hidden)
        .frame(width: 28)
        .help("Text color")
    }

    /// Draws a small filled circle in `color` for use as a menu item icon.
    private static func colorSwatch(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
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
                ForEach(rich.inlineImages) { image in
                    HStack(spacing: 4) {
                        Image(systemName: "photo")
                        Text("Image").lineLimit(1)
                        Button {
                            rich.removeInlineImage(image.id)
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
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

    /// The reply the user typed (with any pasted images rewritten to `cid:` refs and
    /// returned as related parts), followed by the original message appended verbatim
    /// so its formatting (and inline images) survive intact.
    private func composedBody() -> (html: String, inlineImages: [ComposeInlineImage]) {
        let (userHTML, images) = rich.exportBody()
        guard !request.quotedHTML.isEmpty else { return (userHTML, images) }
        let userInner = PlainTextHTML.bodyFragment(userHTML)
        let html = "<html><head><meta charset=\"utf-8\"></head><body>\(userInner)\(request.quotedHTML)</body></html>"
        return (html, images)
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
