import Foundation
import Observation

/// Drives the entire UI. Holds one `Session` per configured account (each with
/// its own provider), the per-account folder trees, the current message list,
/// selection, search state, and the action methods invoked by the toolbar,
/// hover buttons, and context menu (one shared command surface).
///
/// Only one folder is "open" at a time (Outlook-style): the message list and all
/// actions route to the provider of the currently selected folder's account.
@MainActor
@Observable
final class MailboxViewModel {

    /// An account plus its live provider.
    struct Session: Identifiable {
        var account: MailAccount
        let provider: MailProvider
        var id: String { account.id }
    }

    let store = MailStore()
    let contactStore = ContactStore()
    let accountStore = AccountStore()
    private var refreshTimer: Timer?

    // Accounts / folders
    private(set) var sessions: [Session] = []
    var foldersByAccount: [String: [MailFolder]] = [:]
    var favorites: [MailFolder] = []
    private var favoriteIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "favoriteFolderIds2") ?? [])

    // One MSAL app backs all Microsoft accounts; created lazily on first use.
    private var _graphAuth: GraphAuth?
    // Per-account snooze timers.
    private var snoozeServices: [String: SnoozeService] = [:]
    // Cached Gmail write-scope status (Graph accounts can always write).
    private var gmailWriteScope = true

    /// Email of the currently selected account (used as the compose "from").
    var accountEmail = ""

    // Currently presented modal sheet (compose / message window / custom snooze).
    var activeSheet: ActiveSheet?
    var modalBody: MessageBody?

    // Sidebar selection (tag like "acct:<accountId>\u{1}<folderId>").
    var sidebarSelection: String?
    var currentFolder: MailFolder?
    private var currentAccountId: String?

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
    // Non-modal status-bar message for connection / sync / load problems (shown
    // in the bottom bar instead of an alert). Cleared on the next success.
    var statusMessage: String?
    var authMessage: String?
    var isSigningIn = false
    var hasWriteScope = true

    init() {}

    /// Provider for the currently selected account.
    var currentProvider: MailProvider? {
        sessions.first { $0.account.id == currentAccountId }?.provider
    }

    /// Folders of the currently selected account (move targets, etc.).
    var currentFolders: [MailFolder] {
        foldersByAccount[currentAccountId ?? ""] ?? []
    }

    var displayedMessages: [MessageHeader] {
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

    // MARK: - Bootstrap & accounts

    func bootstrap() async {
        gmailWriteScope = (try? await GoogleAuth.shared.hasWriteScope) ?? false

        let accounts = ensureSeedAccounts()
        buildSessions(for: accounts)

        // Paint cached folders for an instant UI.
        for session in sessions {
            let cached = store.cachedFolders(accountId: session.account.id)
            if !cached.isEmpty { foldersByAccount[session.account.id] = cached }
        }
        recomputeFavorites()

        // Reconcile each account from the network. Connection failures here go to
        // the status bar (non-modal) rather than an interrupting alert.
        statusMessage = nil
        for session in sessions {
            do {
                try await session.provider.loadProfile()
                updateAccountEmail(session.account.id, email: session.provider.accountEmail)
                try await loadFolders(for: session)
                startSnooze(for: session)
            } catch {
                statusMessage = "Couldn’t connect \(connectLabel(session)): \(error.localizedDescription)"
            }
        }

        // Open the first account's inbox.
        if let first = sessions.first,
           let inbox = foldersByAccount[first.account.id]?.first(where: { $0.kind == .inbox }) {
            sidebarSelection = "acct:\(inbox.compositeId)"
            await selectFolder(inbox)
        }
        startPeriodicRefresh()
    }

    /// Loads persisted accounts, seeding a Gmail account on first launch (the app
    /// ships with a bundled Gmail token).
    private func ensureSeedAccounts() -> [MailAccount] {
        var accounts = accountStore.load()
        if accounts.isEmpty {
            let gmail = MailAccount(id: "gmail", providerKind: .gmail, email: "", displayName: "Google")
            accountStore.upsert(gmail)
            accounts = [gmail]
        }
        return accounts
    }

    private func buildSessions(for accounts: [MailAccount]) {
        var built: [Session] = []
        for account in accounts {
            switch account.providerKind {
            case .gmail:
                built.append(Session(account: account, provider: GmailProvider(accountId: account.id)))
            case .graph:
                do {
                    let auth = try graphAuth()
                    built.append(Session(account: account, provider: GraphProvider(account: account, auth: auth)))
                } catch {
                    errorMessage = "Couldn't initialize \(account.email): \(error.localizedDescription)"
                }
            }
        }
        sessions = built
    }

    private func graphAuth() throws -> GraphAuth {
        if let auth = _graphAuth { return auth }
        guard AppConfig.isMicrosoftConfigured else {
            throw MailError.auth("Microsoft client ID not set — fill in AppConfig.microsoftClientID.")
        }
        let auth = try GraphAuth(clientId: AppConfig.microsoftClientID)
        _graphAuth = auth
        return auth
    }

    private func loadFolders(for session: Session) async throws {
        let folders = try await session.provider.listFolders()
        foldersByAccount[session.account.id] = folders
        store.saveFolders(folders, accountId: session.account.id)
        recomputeFavorites()
    }

    private func startSnooze(for session: Session) {
        guard snoozeServices[session.account.id] == nil else { return }
        let service = SnoozeService(provider: session.provider, accountId: session.account.id)
        service.onWake = { [weak self] in
            Task { await self?.reloadCurrentFolder() }
        }
        service.start()
        snoozeServices[session.account.id] = service
    }

    private func updateAccountEmail(_ accountId: String, email: String) {
        guard !email.isEmpty, let i = sessions.firstIndex(where: { $0.account.id == accountId }) else { return }
        guard sessions[i].account.email != email else { return }
        sessions[i].account.email = email
        if sessions[i].account.displayName.isEmpty || sessions[i].account.displayName == sessions[i].account.providerKind.providerName {
            sessions[i].account.displayName = email
        }
        accountStore.upsert(sessions[i].account)
        if currentAccountId == accountId { accountEmail = email }
    }

    /// Runs the Microsoft interactive sign-in and adds the account.
    func addMicrosoftAccount() async {
        guard !isSigningIn else { return }
        guard AppConfig.isMicrosoftConfigured else {
            errorMessage = "Set your Azure client ID in AppConfig.microsoftClientID before adding a Microsoft account."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let auth = try graphAuth()
            let result = try await auth.signIn()
            let accountId = "graph:\(result.homeAccountId)"

            // Reuse an existing session if present (it may be half-loaded from a
            // prior failed attempt); otherwise create and persist a new one. We
            // always (re)load the profile + folders so an incomplete account
            // finishes loading rather than getting stuck behind an early return.
            let session: Session
            let isNew: Bool
            if let existing = sessions.first(where: { $0.account.id == accountId }) {
                session = existing
                isNew = false
            } else {
                let account = MailAccount(
                    id: accountId, providerKind: .graph, email: result.email,
                    displayName: result.email, externalId: result.homeAccountId
                )
                accountStore.upsert(account)
                session = Session(account: account, provider: GraphProvider(account: account, auth: auth))
                sessions.append(session)
                isNew = true
            }

            do {
                try await session.provider.loadProfile()
                updateAccountEmail(session.account.id, email: session.provider.accountEmail)
                try await loadFolders(for: session)
            } catch {
                // Don't leave a brand-new account half-added if it can't load.
                if isNew { removeAccount(session.account.id) }
                throw error
            }
            startSnooze(for: session)
            authMessage = "Added \(session.provider.accountEmail)."

            if let inbox = foldersByAccount[session.account.id]?.first(where: { $0.kind == .inbox }) {
                sidebarSelection = "acct:\(inbox.compositeId)"
                await selectFolder(inbox)
            }
        } catch {
            errorMessage = "Microsoft sign-in failed: \(error.localizedDescription)"
        }
    }

    func removeAccount(_ accountId: String) {
        guard let session = sessions.first(where: { $0.account.id == accountId }) else { return }
        if session.account.providerKind == .graph {
            _graphAuth?.signOut(homeAccountId: session.account.externalId)
        }
        snoozeServices[accountId]?.stop()
        snoozeServices[accountId] = nil
        sessions.removeAll { $0.account.id == accountId }
        foldersByAccount[accountId] = nil
        accountStore.remove(id: accountId)
        favoriteIds = favoriteIds.filter { !$0.hasPrefix("\(accountId)\u{1}") }
        persistFavorites()
        recomputeFavorites()

        if currentAccountId == accountId {
            currentAccountId = nil
            currentFolder = nil
            messages = []
            currentBody = nil
            if let first = sessions.first,
               let inbox = foldersByAccount[first.account.id]?.first(where: { $0.kind == .inbox }) {
                sidebarSelection = "acct:\(inbox.compositeId)"
                Task { await selectFolder(inbox) }
            }
        }
    }

    func startPeriodicRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { await self?.reloadCurrentFolder() }
        }
    }

    // MARK: - Favorites

    func isFavorite(_ folder: MailFolder) -> Bool { favoriteIds.contains(favKey(folder)) }

    func toggleFavorite(_ folder: MailFolder) {
        let key = favKey(folder)
        if favoriteIds.contains(key) { favoriteIds.remove(key) }
        else { favoriteIds.insert(key) }
        persistFavorites()
        recomputeFavorites()
    }

    private func favKey(_ folder: MailFolder) -> String { folder.compositeId }

    private func persistFavorites() {
        UserDefaults.standard.set(Array(favoriteIds), forKey: "favoriteFolderIds2")
    }

    private func recomputeFavorites() {
        let all = sessions.flatMap { foldersByAccount[$0.account.id] ?? [] }
        if favoriteIds.isEmpty {
            // Seed each account's inbox.
            for folders in all where folders.kind == .inbox {
                favoriteIds.insert(favKey(folders))
            }
            persistFavorites()
        }
        favorites = all
            .filter { favoriteIds.contains(favKey($0)) }
            .sorted { ($0.accountId, $0.kind.sortWeight) < ($1.accountId, $1.kind.sortWeight) }
    }

    // MARK: - Selection

    private func parseTag(_ tag: String) -> (accountId: String, folderId: String)? {
        guard let colon = tag.firstIndex(of: ":") else { return nil }
        let composite = String(tag[tag.index(after: colon)...])
        let parts = composite.split(separator: "\u{1}", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1])
    }

    func selectRow(_ rowId: String) async {
        guard let (accountId, folderId) = parseTag(rowId),
              let folder = foldersByAccount[accountId]?.first(where: { $0.id == folderId }) else { return }
        await selectFolder(folder)
    }

    func selectFolder(_ folder: MailFolder) async {
        guard currentFolder?.compositeId != folder.compositeId else { return }
        currentAccountId = folder.accountId
        currentFolder = folder
        accountEmail = sessions.first { $0.account.id == folder.accountId }?.account.email ?? ""
        hasWriteScope = currentAccountCanWrite
        selection = []
        currentBody = nil
        searchText = ""
        isSearching = false
        messages = store.cachedHeaders(folderId: folder.id, accountId: folder.accountId)
        await loadMessages()
        await refreshCurrentFolderCount()
    }

    private var currentAccountCanWrite: Bool {
        guard let session = sessions.first(where: { $0.account.id == currentAccountId }) else { return true }
        switch session.account.providerKind {
        case .graph: return true
        case .gmail: return gmailWriteScope
        }
    }

    private func refreshCurrentFolderCount() async {
        guard let folder = currentFolder, let provider = currentProvider,
              let count = try? await provider.folderCount(id: folder.id) else { return }
        currentFolder?.unreadCount = count.unread
        currentFolder?.totalCount = count.total
        if let i = foldersByAccount[folder.accountId]?.firstIndex(where: { $0.id == folder.id }) {
            foldersByAccount[folder.accountId]?[i].unreadCount = count.unread
            foldersByAccount[folder.accountId]?[i].totalCount = count.total
        }
    }

    // MARK: - Message loading

    func loadMessages() async {
        guard let folder = currentFolder, let provider = currentProvider else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: nil)
            messages = result.headers
            nextPageToken = result.nextPageToken
            store.saveHeaders(result.headers)
            recordContacts(from: result.headers, folder: folder)
            statusMessage = nil
        } catch {
            if messages.isEmpty {
                messages = store.cachedHeaders(folderId: folder.id, accountId: folder.accountId)
            }
            statusMessage = "Couldn’t load \(folder.name): \(error.localizedDescription)"
        }
    }

    func loadMore() async {
        guard let folder = currentFolder, let provider = currentProvider,
              let token = nextPageToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: token)
            messages.append(contentsOf: result.headers)
            nextPageToken = result.nextPageToken
            store.saveHeaders(result.headers)
            recordContacts(from: result.headers, folder: folder)
            statusMessage = nil
        } catch {
            statusMessage = "Couldn’t load more: \(error.localizedDescription)"
        }
    }

    func reloadCurrentFolder() async {
        if isSearching { await runSearch() } else { await loadMessages() }
        if let session = sessions.first(where: { $0.account.id == currentAccountId }) {
            try? await loadFolders(for: session)
        }
        await refreshCurrentFolderCount()
    }

    func openMessage(_ id: String) async {
        guard let provider = currentProvider else { return }
        isLoadingBody = true
        defer { isLoadingBody = false }
        if let cached = store.cachedBody(id: id) {
            currentBody = cached
        }
        do {
            let body = try await provider.fetchBody(id: id)
            currentBody = body
            store.saveBody(body)
            if let header = messages.first(where: { $0.id == id }), !header.isRead {
                try? await provider.setRead(ids: [id], read: true)
                mutateLocal(ids: [id]) { $0.isRead = true }
                store.updateRead(ids: [id], read: true)
            }
        } catch {
            if currentBody == nil { errorMessage = error.localizedDescription }
        }
    }

    func openInWindow(_ id: String) {
        guard let header = messages.first(where: { $0.id == id }), let provider = currentProvider else { return }
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

    func requestCustomSnooze(_ ids: [String]) {
        activeSheet = .customSnooze(ids)
    }

    /// Gmail-only: re-authorize the current Google account for write access.
    func signInForWriteAccess() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await OAuthService.shared.signIn()
            gmailWriteScope = (try? await GoogleAuth.shared.hasWriteScope) ?? false
            hasWriteScope = currentAccountCanWrite
            if gmailWriteScope {
                authMessage = "Signed in successfully. Write access (delete, move, snooze, send) is now enabled."
            } else {
                authMessage = "Signed in, but write scopes were not granted. Your organization may restrict modify/send for this app."
            }
            if let session = sessions.first(where: { $0.account.id == currentAccountId }) {
                try? await loadFolders(for: session)
            }
            await reloadCurrentFolder()
        } catch {
            errorMessage = "Sign-in failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Search

    func runSearch() async {
        guard let provider = currentProvider else { return }
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
                let folderId = currentFolder?.id ?? "INBOX"
                result = try await provider.listMessages(folderId: folderId, query: text, pageToken: nil)
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

    // MARK: - Actions

    func markRead(_ ids: [String], read: Bool) async {
        await withProvider { try await $0.setRead(ids: ids, read: read) }
        mutateLocal(ids: ids) { $0.isRead = read }
        store.updateRead(ids: ids, read: read)
    }

    func toggleFlag(_ ids: [String]) async {
        let shouldFlag = !(selectedAllFlagged(ids))
        await withProvider { try await $0.setFlagged(ids: ids, flagged: shouldFlag) }
        mutateLocal(ids: ids) { $0.isFlagged = shouldFlag }
        store.updateFlag(ids: ids, flagged: shouldFlag)
    }

    func deleteMessages(_ ids: [String]) async {
        await withProvider { try await $0.trash(ids: ids) }
        removeLocal(ids: ids)
    }

    func archiveMessages(_ ids: [String]) async {
        await withProvider { try await $0.archive(ids: ids) }
        if currentFolder?.kind == .inbox { removeLocal(ids: ids) }
    }

    func move(_ ids: [String], to folder: MailFolder) async {
        await withProvider {
            try await $0.move(ids: ids, toFolderId: folder.id, fromFolderId: self.currentFolder?.id)
        }
        removeLocal(ids: ids)
    }

    func snoozeMessages(_ ids: [String], until wake: Date) async {
        guard let accountId = currentAccountId, let service = snoozeServices[accountId] else { return }
        let headers = messages.filter { ids.contains($0.id) }
        let from = currentFolder?.id ?? "INBOX"
        await perform {
            try await service.snooze(ids: ids, headers: headers, until: wake, fromFolderId: from)
        }
        removeLocal(ids: ids)
    }

    func unsnoozeMessages(_ ids: [String]) async {
        guard let accountId = currentAccountId, let service = snoozeServices[accountId] else { return }
        await perform {
            try await service.unsnooze(ids: ids)
        }
        removeLocal(ids: ids)
    }

    /// Wake time for a snoozed message (drives the "Snoozed Until" column).
    func snoozedUntil(_ messageId: String) -> Date? {
        guard let accountId = currentAccountId else { return nil }
        return snoozeServices[accountId]?.wakeDate(forMessageId: messageId)
    }

    func sync() async {
        await reloadCurrentFolder()
    }

    // MARK: - Compose

    /// Ranked address suggestions for the compose To/Cc autocomplete.
    func contactSuggestions(_ query: String) -> [MailAddress] {
        contactStore.suggestions(matching: query)
    }

    func startNewMail() {
        activeSheet = .compose(ComposeRequest(kind: .new))
    }

    func startReply(all: Bool) {
        guard let header = selectedHeaders.first else { return }
        let to = header.from.email
        let subject = header.subject.hasPrefix("Re:") ? header.subject : "Re: \(header.subject)"
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

    private func bodyFor(_ header: MessageHeader) -> MessageBody? {
        if currentBody?.headerId == header.id { return currentBody }
        if modalBody?.headerId == header.id { return modalBody }
        return nil
    }

    func sendComposed(to: String, cc: String, subject: String, html: String, attachments: [URL]) async {
        // Remember who we send to so they autocomplete next time.
        contactStore.record(MailAddress.parseList(to) + MailAddress.parseList(cc))
        let scoped = attachments.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let mime = MIMEBuilder.buildHTML(
            from: accountEmail, to: to, cc: cc, subject: subject, html: html, attachments: attachments
        )
        await withProvider { try await $0.send(rawMIME: mime) }
    }

    // MARK: - Calendar invites

    /// Sends an RSVP to the invitation's organizer as an iCalendar REPLY email.
    /// Returns whether the reply was sent (the caller updates its UI state).
    @discardableResult
    func respondToInvite(_ invite: CalendarInvite, response: InviteResponse) async -> Bool {
        guard let provider = currentProvider else {
            errorMessage = "No account is selected."
            return false
        }
        guard let organizer = invite.organizer, !organizer.email.isEmpty else {
            errorMessage = "This invitation has no organizer to reply to."
            return false
        }
        let me = MailAddress(name: "", email: accountEmail)
        let ics = ICSReplyBuilder.reply(to: invite, attendee: me, response: response, now: Date())
        let subject = "\(response.subjectPrefix): \(invite.summary)"
        let mime = MIMEBuilder.buildICSReply(
            from: accountEmail, to: organizer.email, subject: subject, ics: ics
        )
        do {
            try await provider.send(rawMIME: mime)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Helpers

    /// Feeds the autocomplete address book: senders of every message, plus the
    /// recipients of mail in the Sent folder ("addresses I've sent mail to").
    private func recordContacts(from headers: [MessageHeader], folder: MailFolder) {
        contactStore.record(headers.map(\.from))
        if folder.kind == .sent {
            contactStore.record(headers.flatMap(\.to))
        }
    }

    /// A human label for an account used in connection status messages.
    private func connectLabel(_ session: Session) -> String {
        let email = session.provider.accountEmail
        if !email.isEmpty, email != "me" { return email }
        return session.account.displayName.isEmpty
            ? session.account.providerKind.providerName
            : session.account.displayName
    }

    private func selectedAllFlagged(_ ids: [String]) -> Bool {
        let set = Set(ids)
        let chosen = messages.filter { set.contains($0.id) }
        return !chosen.isEmpty && chosen.allSatisfy { $0.isFlagged }
    }

    private func withProvider(_ work: @escaping (MailProvider) async throws -> Void) async {
        guard let provider = currentProvider else {
            errorMessage = "No account is selected."
            return
        }
        await perform { try await work(provider) }
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
        // Remember where the removed rows sat (in the visible order) so we can
        // land the selection on whatever message takes their place.
        let firstRemovedIndex = displayedMessages.firstIndex { set.contains($0.id) }

        messages.removeAll { set.contains($0.id) }
        selection.subtract(set)
        if let body = currentBody, set.contains(body.headerId) { currentBody = nil }
        store.deleteMessages(ids: ids)

        // If the removal cleared the selection, advance to the next message (or
        // the last one when the tail was removed) so the list keeps a focused row
        // and the preview follows along.
        if selection.isEmpty, let idx = firstRemovedIndex {
            let remaining = displayedMessages
            if !remaining.isEmpty {
                selection = [remaining[min(idx, remaining.count - 1)].id]
            }
        }
    }
}

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
