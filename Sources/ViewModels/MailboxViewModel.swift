import Foundation
import Observation

/// Drives the entire UI. Holds the folder tree, the current message list,
/// selection, search state, and the action methods invoked by the toolbar,
/// hover buttons, and context menu (one shared command surface).
@MainActor
@Observable
final class MailboxViewModel {
    // Backend (Gmail for the MVP).
    let provider: MailProvider
    let snooze: SnoozeService
    let store = MailStore()

    // Account / folders
    var accountEmail = ""
    var folders: [MailFolder] = []
    var favorites: [MailFolder] = []
    private var favoriteIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favoriteFolderIds") ?? [])

    // Currently presented modal sheet (compose / message window / custom snooze).
    // A single sheet driven by an enum — stacking multiple .sheet modifiers on
    // one view does not present reliably.
    var activeSheet: ActiveSheet?
    // Body for the message shown in the modal window.
    var modalBody: MessageBody?

    // Selection in the sidebar (unique row id, e.g. "acct:INBOX").
    var sidebarSelection: String?
    var currentFolder: MailFolder?

    // Message list
    var messages: [MessageHeader] = []
    var selection: Set<String> = []
    var sortOrder: [KeyPathComparator<MessageHeader>] = [
        .init(\MessageHeader.date, order: .reverse)
    ]
    var nextPageToken: String?

    // Preview
    var currentBody: MessageBody?
    var isLoadingBody = false

    // Search
    var searchText = ""
    var searchScope: SearchScope = .currentFolder
    private var isSearching = false


    // Status
    var isLoading = false
    var errorMessage: String?
    var authMessage: String?
    var isSigningIn = false
    var hasWriteScope = true

    init(provider: MailProvider = GmailProvider()) {
        self.provider = provider
        self.snooze = SnoozeService(provider: provider)
        self.snooze.onWake = { [weak self] in
            Task { await self?.reloadCurrentFolder() }
        }
    }

    var displayedMessages: [MessageHeader] {
        // Sorting by the flag column groups flagged messages first, then sorts
        // by date descending within each group.
        if let primary = sortOrder.first, primary.keyPath == \MessageHeader.flagSort {
            let flaggedFirst = primary.order == .forward
            return messages.sorted { a, b in
                if a.isFlagged != b.isFlagged {
                    return flaggedFirst ? a.isFlagged : b.isFlagged
                }
                return a.date > b.date
            }
        }
        return messages.sorted(using: sortOrder)
    }

    var selectedHeaders: [MessageHeader] {
        messages.filter { selection.contains($0.id) }
    }

    // MARK: - Bootstrap

    func bootstrap() async {
        hasWriteScope = (try? await GoogleAuth.shared.hasWriteScope) ?? false
        // Paint instantly from cache before any network call.
        let cachedFolders = store.cachedFolders()
        if !cachedFolders.isEmpty {
            folders = cachedFolders
            recomputeFavorites()
        }
        do {
            try await provider.loadProfile()
            accountEmail = provider.accountEmail
            try await loadFolders()
            if let inbox = folders.first(where: { $0.kind == .inbox }) {
                sidebarSelection = "acct:\(inbox.id)"
                await selectFolder(inbox)
            }
            snooze.start()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Folders

    func loadFolders() async throws {
        folders = try await provider.listFolders()
        recomputeFavorites()
        store.saveFolders(folders)
    }

    func isFavorite(_ folderId: String) -> Bool { favoriteIds.contains(folderId) }

    func toggleFavorite(_ folderId: String) {
        if favoriteIds.contains(folderId) { favoriteIds.remove(folderId) }
        else { favoriteIds.insert(folderId) }
        UserDefaults.standard.set(Array(favoriteIds), forKey: "favoriteFolderIds")
        recomputeFavorites()
    }

    private func recomputeFavorites() {
        // Seed with the Inbox the first time, if nothing is pinned yet.
        if favoriteIds.isEmpty, let inbox = folders.first(where: { $0.kind == .inbox }) {
            favoriteIds = [inbox.id]
            UserDefaults.standard.set(Array(favoriteIds), forKey: "favoriteFolderIds")
        }
        favorites = folders
            .filter { favoriteIds.contains($0.id) }
            .sorted { $0.kind.sortWeight < $1.kind.sortWeight }
    }

    func selectRow(_ rowId: String) async {
        // rowId is "fav:<id>" or "acct:<id>"; map back to the folder.
        let folderId = String(rowId.drop(while: { $0 != ":" }).dropFirst())
        guard let folder = folders.first(where: { $0.id == folderId }) else { return }
        await selectFolder(folder)
    }

    func selectFolder(_ folder: MailFolder) async {
        // Avoid reloading the folder that's already selected (e.g. the sidebar
        // onChange firing for the same id bootstrap just selected).
        guard currentFolder?.id != folder.id else { return }
        currentFolder = folder
        selection = []
        currentBody = nil
        searchText = ""
        // Instant paint from cache, then refresh from the network.
        messages = store.cachedHeaders(folderId: folder.id)
        await loadMessages()
        await refreshCurrentFolderCount()
    }

    /// Fetches the accurate total/unread count for the selected folder so the
    /// list header can show e.g. "Inbox (103)".
    private func refreshCurrentFolderCount() async {
        guard let folder = currentFolder,
              let count = try? await provider.folderCount(id: folder.id) else { return }
        currentFolder?.unreadCount = count.unread
        currentFolder?.totalCount = count.total
        if let i = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[i].unreadCount = count.unread
            folders[i].totalCount = count.total
        }
    }

    func loadMessages() async {
        guard let folder = currentFolder else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: nil)
            messages = result.headers
            nextPageToken = result.nextPageToken
            store.saveHeaders(result.headers)
        } catch {
            // Offline / failure: keep whatever the cache already provided.
            if messages.isEmpty {
                messages = store.cachedHeaders(folderId: folder.id)
            }
            errorMessage = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let folder = currentFolder, let token = nextPageToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: token)
            messages.append(contentsOf: result.headers)
            nextPageToken = result.nextPageToken
            store.saveHeaders(result.headers)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadCurrentFolder() async {
        if isSearching { await runSearch() } else { await loadMessages() }
        try? await loadFolders()
    }

    // MARK: - Preview

    func openMessage(_ id: String) async {
        isLoadingBody = true
        defer { isLoadingBody = false }
        // Instant from cache if we've fetched this body before.
        if let cached = store.cachedBody(id: id) {
            currentBody = cached
        }
        do {
            let body = try await provider.fetchBody(id: id)
            currentBody = body
            store.saveBody(body)
            // Mark read on open (best effort; needs write scope).
            if let header = messages.first(where: { $0.id == id }), !header.isRead {
                try? await provider.setRead(ids: [id], read: true)
                mutateLocal(ids: [id]) { $0.isRead = true }
                store.updateRead(ids: [id], read: true)
            }
        } catch {
            if currentBody == nil { errorMessage = error.localizedDescription }
        }
    }

    // MARK: - Open in modal window (double-click)

    func openInWindow(_ id: String) {
        guard let header = messages.first(where: { $0.id == id }) else { return }
        modalBody = store.cachedBody(id: id)
        activeSheet = .message(header)
        Task {
            do {
                let body = try await provider.fetchBody(id: id)
                modalBody = body
                store.saveBody(body)
            } catch {
                if modalBody == nil { errorMessage = error.localizedDescription }
            }
            if !header.isRead {
                try? await provider.setRead(ids: [id], read: true)
                mutateLocal(ids: [id]) { $0.isRead = true }
                store.updateRead(ids: [id], read: true)
            }
        }
    }

    // MARK: - Custom snooze

    func requestCustomSnooze(_ ids: [String]) {
        activeSheet = .customSnooze(ids)
    }

    // MARK: - Interactive OAuth sign-in

    func signInForWriteAccess() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await OAuthService.shared.signIn()
            hasWriteScope = (try? await GoogleAuth.shared.hasWriteScope) ?? false
            if hasWriteScope {
                authMessage = "Signed in successfully. Your organization permits this app and granted write access — delete, move, snooze, and send now work."
            } else {
                authMessage = "Signed in, but write scopes were not granted. Your organization or account may restrict modify/send for this app."
            }
            // Refresh with the new token.
            try? await loadFolders()
            await reloadCurrentFolder()
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    func runSearch() async {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            isSearching = false
            await loadMessages()
            return
        }
        isSearching = true
        isLoading = true
        defer { isLoading = false }
        do {
            let result: (headers: [MessageHeader], nextPageToken: String?)
            switch searchScope {
            case .currentFolder:
                let labelId = currentFolder?.id ?? "INBOX"
                result = try await provider.listMessages(folderId: labelId, query: text, pageToken: nil)
            case .allFolders:
                result = try await provider.search(query: text, pageToken: nil)
            }
            messages = result.headers
            nextPageToken = result.nextPageToken
            store.saveHeaders(result.headers)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions (toolbar / hover / context menu share these)

    func markRead(_ ids: [String], read: Bool) async {
        await perform { try await self.provider.setRead(ids: ids, read: read) }
        mutateLocal(ids: ids) { $0.isRead = read }
        store.updateRead(ids: ids, read: read)
    }

    func toggleFlag(_ ids: [String]) async {
        let shouldFlag = !(selectedAllFlagged(ids))
        await perform { try await self.provider.setFlagged(ids: ids, flagged: shouldFlag) }
        mutateLocal(ids: ids) { $0.isFlagged = shouldFlag }
        store.updateFlag(ids: ids, flagged: shouldFlag)
    }

    func deleteMessages(_ ids: [String]) async {
        await perform { try await self.provider.trash(ids: ids) }
        removeLocal(ids: ids)
    }

    func archiveMessages(_ ids: [String]) async {
        await perform { try await self.provider.archive(ids: ids) }
        if currentFolder?.kind == .inbox { removeLocal(ids: ids) }
    }

    func move(_ ids: [String], to folder: MailFolder) async {
        await perform {
            try await self.provider.move(ids: ids, toFolderId: folder.id, fromFolderId: self.currentFolder?.id)
        }
        removeLocal(ids: ids)
    }

    func snoozeMessages(_ ids: [String], until wake: Date) async {
        let headers = messages.filter { ids.contains($0.id) }
        let from = currentFolder?.id ?? "INBOX"
        await perform {
            try await self.snooze.snooze(ids: ids, headers: headers, until: wake, fromFolderId: from)
        }
        removeLocal(ids: ids)
    }

    func sync() async {
        await reloadCurrentFolder()
    }

    // MARK: - Compose

    func startNewMail() {
        activeSheet = .compose(ComposeRequest(kind: .new))
    }

    func startReply(all: Bool) {
        guard let header = selectedHeaders.first else { return }
        let to = header.from.email
        let subject = header.subject.hasPrefix("Re:") ? header.subject : "Re: \(header.subject)"
        // Show the full original message (rendered) below the reply, like forward.
        let original = bodyFor(header)?.html ?? ""
        let quoted = """
        <br><br>
        <p>On \(header.date.mailFullString), \(escape(header.from.display)) &lt;\(escape(header.from.email))&gt; wrote:</p>
        <blockquote style="margin:0 0 0 8px;padding-left:10px;border-left:2px solid #ccc">
        \(original.isEmpty ? "<p>\(escape(header.snippet))</p>" : original)
        </blockquote>
        """
        activeSheet = .compose(ComposeRequest(
            kind: all ? .replyAll : .reply,
            to: to,
            subject: subject,
            quotedHTML: quoted
        ))
    }

    func startForward() {
        guard let header = selectedHeaders.first else { return }
        let subject = header.subject.hasPrefix("Fwd:") ? header.subject : "Fwd: \(header.subject)"
        // Show the original message as a preview inside the compose body.
        let original = bodyFor(header)?.html ?? ""
        let forwardHeader = """
        <p>---------- Forwarded message ----------<br>
        From: \(escape(header.from.display)) &lt;\(escape(header.from.email))&gt;<br>
        Date: \(header.date.mailFullString)<br>
        Subject: \(escape(header.subject))</p>
        """
        activeSheet = .compose(ComposeRequest(
            kind: .forward,
            subject: subject,
            quotedHTML: forwardHeader + (original.isEmpty ? "<p>\(escape(header.snippet))</p>" : original)
        ))
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The loaded body for a header, whether it came from the preview pane or
    /// the modal window.
    private func bodyFor(_ header: MessageHeader) -> MessageBody? {
        if currentBody?.headerId == header.id { return currentBody }
        if modalBody?.headerId == header.id { return modalBody }
        return nil
    }

    func sendComposed(to: String, cc: String, subject: String, html: String, attachments: [URL]) async {
        // Sandbox: gain access to user-selected files while reading them.
        let scoped = attachments.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let mime = MIMEBuilder.buildHTML(
            from: accountEmail, to: to, cc: cc, subject: subject, html: html, attachments: attachments
        )
        await perform { try await self.provider.send(rawMIME: mime) }
    }

    // MARK: - Helpers

    private func selectedAllFlagged(_ ids: [String]) -> Bool {
        let set = Set(ids)
        let chosen = messages.filter { set.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy { $0.isFlagged }
    }

    private func perform(_ work: @escaping () async throws -> Void) async {
        do {
            try await work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mutateLocal(ids: [String], _ change: (inout MessageHeader) -> Void) {
        let set = Set(ids)
        for i in messages.indices where set.contains(messages[i].id) {
            change(&messages[i])
        }
    }

    private func removeLocal(ids: [String]) {
        let set = Set(ids)
        messages.removeAll { set.contains($0.id) }
        selection.subtract(set)
        if let body = currentBody, set.contains(body.headerId) { currentBody = nil }
        store.deleteMessages(ids: ids)
    }
}

// MARK: - Modal sheets

enum ActiveSheet: Identifiable {
    case compose(ComposeRequest)
    case message(MessageHeader)
    case customSnooze([String])

    var id: String {
        switch self {
        case .compose(let r): return "compose-\(r.id)"
        case .message(let h): return "message-\(h.id)"
        case .customSnooze: return "snooze"
        }
    }
}

// MARK: - Compose request

enum ComposeKind {
    case new, reply, replyAll, forward
    var title: String {
        switch self {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        }
    }
}

@Observable
final class ComposeRequest: Identifiable {
    let id = UUID()
    let kind: ComposeKind
    var to: String
    var cc: String
    var subject: String
    var body: String
    /// Original message HTML to show as the rendered quote (reply/forward).
    var quotedHTML: String

    init(kind: ComposeKind, to: String = "", subject: String = "", quoted: String = "", quotedHTML: String = "") {
        self.kind = kind
        self.to = to
        self.cc = ""
        self.subject = subject
        self.body = quoted
        self.quotedHTML = quotedHTML
    }
}
