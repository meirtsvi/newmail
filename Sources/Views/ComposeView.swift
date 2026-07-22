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
    /// When on, the sent message is marked flagged (⌘W or the flag toolbar button).
    @State private var flagged = false
    @State private var showImporter = false
    @State private var showLinkPrompt = false
    @State private var linkURL = ""
    @State private var fontFamily = RichTextController.defaultFamily
    @State private var fontSize: CGFloat = RichTextController.defaultSize
    /// Snapshot of the fields at the last successful draft save, so the 10-second
    /// autosave skips when nothing has changed.
    @State private var lastSavedSnapshot = ""
    /// In-flight server draft save. Send awaits it before deleting the draft, so
    /// it deletes the id the save actually leaves behind — a save can mint a fresh
    /// draft id (always on Graph, and on the first save everywhere), and deleting
    /// the stale id would orphan the new draft.
    @State private var draftSave: Task<Void, Never>?
    /// Shared keyboard focus across the To/Cc/Subject fields so Tab and Shift-Tab
    /// move between them in order; the body editor is reached via `rich`.
    @FocusState private var focus: ComposeField?
    /// Measured size of the body editor, used to decide how much of the quoted
    /// original's space the reply text needs.
    @State private var editorSize: CGSize = .zero
    /// Current height of the quoted-original pane; nil means "the base height".
    /// Shrinks as the reply outgrows the editor, so the divider moves down.
    @State private var quotedHeight: CGFloat?

    /// The editor never gives up its last rows even when the quote is at full height.
    private static let minEditorHeight: CGFloat = 100
    /// The quoted original stays at least this tall (it scrolls within itself).
    private static let minQuotedHeight: CGFloat = 120

    /// Replies open with the recipients and subject already filled in, so keyboard
    /// focus starts in the body instead of the To field.
    private var startsInBody: Bool {
        request.kind == .reply || request.kind == .replyAll
    }

    var body: some View {
        GeometryReader { geo in
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
                        .frame(minHeight: Self.minEditorHeight)
                        // Measure the editor so the quoted pane below can yield
                        // space once the reply text no longer fits.
                        .background(GeometryReader { editor in
                            Color.clear
                                .onAppear { editorSize = editor.size }
                                .onChange(of: editor.size) { _, size in editorSize = size }
                        })
                }
                if !attachments.isEmpty || !rich.inlineImages.isEmpty || loadingAttachments {
                    Divider()
                    attachmentBar
                }
                if !request.quotedHTML.isEmpty {
                    Divider()
                    // The quoted original gets up to two thirds of the window,
                    // capped so the title bar, fields, toolbar and editor stay
                    // usable when the window is short — and it yields space to
                    // the editor as the reply grows past what fits above it.
                    quotedPreview
                        .frame(height: min(quotedHeight ?? quotedBase(geo), quotedBase(geo)))
                }
            }
            // Re-balance editor vs. quote when the reply text grows or shrinks,
            // and when the editor is resized (window resize, attachment bar).
            // The editor's size change also re-wraps the text, so its content
            // height is refreshed first.
            .onChange(of: editorSize) { _, _ in
                rich.refreshContentHeight()
                updateQuotedHeight(base: quotedBase(geo))
            }
            .onChange(of: rich.contentHeight) { _, _ in
                updateQuotedHeight(base: quotedBase(geo))
            }
        }
        .frame(minWidth: 480, idealWidth: 640, minHeight: 380,
               idealHeight: request.quotedHTML.isEmpty ? 560 : 680)
        .background(ZoomShortcuts(zoom: Binding(
            get: { Double(rich.zoom) },
            set: { rich.setZoom(CGFloat($0)) }
        )))
        .onAppear {
            // Shift-Tab out of the body editor returns to the Subject field. Both the
            // rich-text body (new/reply/forward) and the WebView body (edit) route it.
            rich.onShiftTab = { focus = .subject }
            htmlEditor.onShiftTab = { focus = .subject }
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
            // Files shared in (e.g. from the macOS Share menu) are already local.
            if !request.localAttachments.isEmpty {
                attachments.append(contentsOf: request.localAttachments)
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
            // Deferred a runloop so the body grabs focus after the freshly opened
            // window has become key (same reason the To field defers its focus).
            if startsInBody {
                DispatchQueue.main.async { rich.focus() }
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
            // ⌘S saves the draft immediately (or, when editing, saves the edited
            // message and closes); the hidden button just carries the shortcut.
            Button("") {
                if request.kind == .edit { saveEditAndClose() }
                else { Task { await autosaveDraft() } }
            }
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
        let save = Task {
            request.draftId = await vm.saveDraft(
                to: request.to, cc: request.cc, subject: request.subject,
                html: html, attachments: attachments, inlineImages: inlineImages, draftId: request.draftId
            )
            lastSavedSnapshot = snapshot
        }
        draftSave = save
        await save.value
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
            Button("Cancel") { closeKeepingDraft() }
            if request.kind == .edit { saveButton } else { sendButton }
        }
        .padding()
    }

    private var sendButton: some View {
        Button {
            sending = true
            let (html, inlineImages) = composedBody()
            Task {
                // Wait out any in-flight autosave so request.draftId below is the
                // draft that actually exists on the server when we delete it.
                await draftSave?.value
                await vm.sendComposed(
                    to: request.to, cc: request.cc, subject: request.subject,
                    html: html, attachments: attachments, inlineImages: inlineImages, draftId: request.draftId,
                    flagged: flagged
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
            saveEditAndClose()
        } label: {
            if sending { ProgressView().controlSize(.small) }
            else { Label("Save", systemImage: "checkmark") }
        }
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(sending || loadingAttachments)
    }

    /// Save action for edit mode: replaces the original message with the edited
    /// copy and closes the window. Shared by the Save button and ⌘S.
    private func saveEditAndClose() {
        guard !sending, !loadingAttachments else { return }
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
    }

    private var fields: some View {
        VStack(spacing: 8) {
            // When editing a message only Subject + body change; recipients are
            // shown for context but kept as-is.
            RecipientField(title: "To", text: $request.to,
                           suggest: vm.contactSuggestions, focus: $focus,
                           field: .to, next: .cc, focusOnAppear: !startsInBody)
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
                    // skipping the bold/italic/underline/link/attach buttons.
                    // Shift-Tab steps back to the Cc field — but when editing, To/Cc
                    // are disabled, so there's no field before Subject and it stays put
                    // rather than losing focus into a disabled field.
                    .onKeyPress(keys: [.tab], phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            if request.kind != .edit { focus = .cc }
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

    /// Full height of the quoted-original pane: two thirds of the window, capped
    /// so the title bar, fields, toolbar and editor keep at least 300pt.
    private func quotedBase(_ geo: GeometryProxy) -> CGFloat {
        min(geo.size.height * 2 / 3, geo.size.height - 300)
    }

    /// Re-balances the editor and the quoted pane. Whatever the reply text needs
    /// beyond the editor's current height is taken from the quote (down to its
    /// minimum); space freed by deleting text goes back to the quote (up to its
    /// base height). The editor is the only flexible view in the stack, so height
    /// given up by the quote lands in the editor and vice versa — which keeps
    /// `editor + quote` constant and the computation stable across passes.
    private func updateQuotedHeight(base: CGFloat) {
        guard !request.quotedHTML.isEmpty, request.kind != .edit, editorSize.height > 0 else { return }
        let needed = max(Self.minEditorHeight, rich.contentHeight)
        let current = min(quotedHeight ?? base, base)
        let target = min(base, max(Self.minQuotedHeight, current + (editorSize.height - needed)))
        if abs(target - current) > 0.5 { quotedHeight = target }
    }

    /// Moves keyboard focus from a compose field into the body editor. The SwiftUI
    /// focus is released first, then the body is made first responder on the next
    /// runloop — otherwise SwiftUI's focus pass runs afterwards and steals it back.
    private func focusBody() {
        focus = nil
        // Editing uses the WebView body; every other kind uses the rich-text body.
        DispatchQueue.main.async {
            if request.kind == .edit { htmlEditor.focus() } else { rich.focus() }
        }
    }

    // Spacing 8 keeps the bar's fixed content within the window's 640pt ideal
    // width now that the list buttons are in it.
    private var formattingBar: some View {
        HStack(spacing: 8) {
            Button { rich.toggleBold() } label: { Image(systemName: "bold") }
                .keyboardShortcut("b", modifiers: .command)
                .help("Bold (⌘B)")
            Button { rich.toggleItalic() } label: { Image(systemName: "italic") }
                .keyboardShortcut("i", modifiers: .command)
                .help("Italic (⌘I)")
            Button { rich.toggleUnderline() } label: { Image(systemName: "underline") }
                .keyboardShortcut("u", modifiers: .command)
                .help("Underline (⌘U)")
            colorMenu
            Button { showLinkPrompt = true } label: { Image(systemName: "link") }.help("Insert link")
            Divider().frame(height: 16)
            Button { rich.alignLeft() } label: { Image(systemName: "text.alignleft") }.help("Align left")
            Button { rich.alignRight() } label: { Image(systemName: "text.alignright") }.help("Align right")
            Button { rich.makeLeftToRight() } label: { Image(systemName: "arrow.right") }.help("Left-to-right")
            Button { rich.makeRightToLeft() } label: { Image(systemName: "arrow.left") }.help("Right-to-left")
            Divider().frame(height: 16)
            Button { rich.toggleBulletList() } label: { Image(systemName: "list.bullet") }.help("Bulleted list")
            Button { rich.toggleNumberedList() } label: { Image(systemName: "list.number") }.help("Numbered list")
            Divider().frame(height: 16)
            fontPickers
            Divider().frame(height: 16)
            Button { showImporter = true } label: { Image(systemName: "paperclip") }.help("Attach file")
            Button {
                flagged.toggle()
            } label: {
                Image(systemName: flagged ? "flag.fill" : "flag")
                    .foregroundStyle(flagged ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            }
                .keyboardShortcut("w", modifiers: .command)
                .help(flagged ? "Send unflagged (⌘W)" : "Send flagged (⌘W)")
            Divider().frame(height: 16)
            ZoomControls(zoom: Binding(
                get: { Double(rich.zoom) },
                set: { rich.setZoom(CGFloat($0)) }
            ))
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
                .frame(maxHeight: .infinity)
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
