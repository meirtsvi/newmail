import Foundation
import Observation
import AppKit

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
    /// Background pass that flags the current folder's calendar invites.
    private var calendarScanTask: Task<Void, Never>?

    // Accounts / folders
    private(set) var sessions: [Session] = []
    var foldersByAccount: [String: [MailFolder]] = [:]
    var favorites: [MailFolder] = []
    // Ordered list of favorite folder composite ids (UserDefaults preserves order).
    private var favoriteOrder: [String] = UserDefaults.standard.stringArray(forKey: "favoriteFolderIds2") ?? []

    // Quick-move bar: a separate, user-configured ordered set of target folders.
    var quickMoveFolders: [MailFolder] = []
    private var quickMoveOrder: [String] = UserDefaults.standard.stringArray(forKey: "quickMoveFolderIds") ?? []

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
    /// Message ids known to be calendar invitations (drives the calendar column).
    /// Populated lazily from cached bodies and as bodies are fetched this session.
    var calendarMessageIds: Set<String> = []
    var sortOrder: [KeyPathComparator<MessageHeader>] = [
        .init(\MessageHeader.date, order: .reverse)
    ]
    var nextPageToken: String?

    /// Whether the list can pull an older page on demand. False while searching,
    /// since `loadMore()` pages the folder listing, not the search results.
    var canLoadMore: Bool { !isSearching && nextPageToken != nil }

    // Preview
    var currentBody: MessageBody?
    var isLoadingBody = false

    // Calendar context for the invitation currently shown (Gmail only).
    var inviteContextHeaderId: String?
    var inviteDayEvents: [CalEvent] = []
    var inviteEventsLoading = false
    var inviteNeedsCalendarAuth = false
    var inviteEventsError: String?

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
        if let primary = sortOrder.first, primary.keyPath == \MessageHeader.calendarSort {
            let eventsFirst = primary.order == .forward
            return messages.sorted { a, b in
                if a.isCalendarEvent != b.isCalendarEvent {
                    return eventsFirst ? a.isCalendarEvent : b.isCalendarEvent
                }
                return a.date > b.date
            }
        }
        return messages.sorted(using: sortOrder)
    }

    var selectedHeaders: [MessageHeader] {
        messages.filter { selection.contains($0.id) }
    }

    /// Whether the message is a known calendar invitation.
    func isCalendarEvent(_ id: String) -> Bool { calendarMessageIds.contains(id) }

    /// Remembers a fetched body's calendar status so the column updates as soon as
    /// a message is opened (and across launches via the cache).
    private func noteCalendar(_ body: MessageBody) {
        if body.calendar != nil {
            calendarMessageIds.insert(body.headerId)
            applyCalendarFlags()
        }
    }

    /// Hydrates the calendar-event set from already-cached bodies for the listed ids.
    private func hydrateCalendarIds() {
        calendarMessageIds.formUnion(store.calendarMessageIds(among: messages.map(\.id)))
        applyCalendarFlags()
    }

    /// Mirrors the invite set onto the loaded headers so the calendar column reads
    /// and (when sorted) orders correctly.
    private func applyCalendarFlags() {
        for i in messages.indices {
            let isEvent = calendarMessageIds.contains(messages[i].id)
            if messages[i].isCalendarEvent != isEvent { messages[i].isCalendarEvent = isEvent }
        }
    }

    /// Background pass: asks the provider which messages in the folder are invites
    /// and flags the column for the whole list (cancelled/superseded on folder change).
    private func scanCalendarEvents(for folder: MailFolder) {
        calendarScanTask?.cancel()
        guard let provider = currentProvider else { return }
        let folderId = folder.id
        let accountId = folder.accountId
        calendarScanTask = Task { [weak self] in
            guard let ids = try? await provider.calendarInviteIds(folderId: folderId) else { return }
            guard let self, !Task.isCancelled,
                  self.currentFolder?.id == folderId, self.currentAccountId == accountId else { return }
            self.calendarMessageIds.formUnion(ids)
            self.applyCalendarFlags()
        }
    }

    /// Sums unread in every account's inbox and reflects it on the Dock icon.
    private func updateDockBadge() {
        let unread = sessions.reduce(0) { sum, session in
            sum + (foldersByAccount[session.account.id]?.first { $0.kind == .inbox }?.unreadCount ?? 0)
        }
        NSApplication.shared.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
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
        updateDockBadge()
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
        favoriteOrder.removeAll { $0.hasPrefix("\(accountId)\u{1}") }
        quickMoveOrder.removeAll { $0.hasPrefix("\(accountId)\u{1}") }
        UserDefaults.standard.set(quickMoveOrder, forKey: "quickMoveFolderIds")
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

    func isFavorite(_ folder: MailFolder) -> Bool { favoriteOrder.contains(favKey(folder)) }

    func toggleFavorite(_ folder: MailFolder) {
        let key = favKey(folder)
        if let idx = favoriteOrder.firstIndex(of: key) { favoriteOrder.remove(at: idx) }
        else { favoriteOrder.append(key) }
        persistFavorites()
        recomputeFavorites()
    }

    /// Reorders favorites (drag-to-reorder in the sidebar). Offsets are indices
    /// into the displayed `favorites` list; ids for folders not currently loaded
    /// keep their relative position at the end.
    func moveFavorite(fromOffsets: IndexSet, toOffset: Int) {
        var displayed = favorites.map { favKey($0) }
        let moving = fromOffsets.sorted().map { displayed[$0] }
        for i in fromOffsets.sorted(by: >) { displayed.remove(at: i) }
        let insertAt = min(max(toOffset - fromOffsets.filter { $0 < toOffset }.count, 0), displayed.count)
        displayed.insert(contentsOf: moving, at: insertAt)
        let shown = Set(displayed)
        favoriteOrder = displayed + favoriteOrder.filter { !shown.contains($0) }
        persistFavorites()
        recomputeFavorites()
    }

    private func favKey(_ folder: MailFolder) -> String { folder.compositeId }

    private func persistFavorites() {
        UserDefaults.standard.set(favoriteOrder, forKey: "favoriteFolderIds2")
    }

    private func recomputeFavorites() {
        let all = sessions.flatMap { foldersByAccount[$0.account.id] ?? [] }
        if favoriteOrder.isEmpty {
            // Seed each account's inbox.
            for folders in all where folders.kind == .inbox {
                favoriteOrder.append(favKey(folders))
            }
            persistFavorites()
        }
        let byId = Dictionary(all.map { (favKey($0), $0) }, uniquingKeysWith: { first, _ in first })
        favorites = favoriteOrder.compactMap { byId[$0] }
        recomputeQuickMove()
    }

    // MARK: - Quick-move bar

    /// Quick-move targets for the current account (moves stay within a provider).
    var quickMoveForCurrentAccount: [MailFolder] {
        quickMoveFolders.filter { $0.accountId == currentAccountId }
    }

    func isQuickMove(_ folder: MailFolder) -> Bool { quickMoveOrder.contains(folder.compositeId) }

    func toggleQuickMove(_ folder: MailFolder) {
        let key = folder.compositeId
        if let i = quickMoveOrder.firstIndex(of: key) { quickMoveOrder.remove(at: i) }
        else { quickMoveOrder.append(key) }
        UserDefaults.standard.set(quickMoveOrder, forKey: "quickMoveFolderIds")
        recomputeQuickMove()
    }

    private func recomputeQuickMove() {
        let all = sessions.flatMap { foldersByAccount[$0.account.id] ?? [] }
        let byId = Dictionary(all.map { ($0.compositeId, $0) }, uniquingKeysWith: { first, _ in first })
        quickMoveFolders = quickMoveOrder.compactMap { byId[$0] }
    }

    /// Whether `folder` can receive a drop of the current selection: same account,
    /// and not the folder already being viewed.
    func isDropTarget(_ folder: MailFolder) -> Bool {
        folder.accountId == currentAccountId && folder.compositeId != currentFolder?.compositeId
    }

    /// Moves dropped/quick-moved messages, rejecting cross-account targets.
    func moveDropped(_ ids: [String], to folder: MailFolder) async {
        guard !ids.isEmpty else { return }
        guard folder.accountId == currentAccountId else {
            statusMessage = "Can’t move across accounts."
            return
        }
        guard folder.compositeId != currentFolder?.compositeId else { return }
        await move(ids, to: folder)
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
        hydrateCalendarIds()
        scanCalendarEvents(for: folder)
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
        updateDockBadge()
    }

    // MARK: - Message loading

    /// How many headers to pull when first opening a folder. Providers page in
    /// small batches (Graph 50, Gmail 100), so we keep fetching until we reach
    /// this many — otherwise the list stops a week or two back and older mail is
    /// only reachable via search. Further pages load on demand via `loadMore()`.
    private static let initialLoadTarget = 300

    func loadMessages() async {
        guard let folder = currentFolder, let provider = currentProvider else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            var result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: nil)
            messages = result.headers
            nextPageToken = result.nextPageToken
            store.saveHeaders(result.headers)
            hydrateCalendarIds()
            recordContacts(from: result.headers, folder: folder)

            // Keep paging until we hit the target or run out of mail. Bail if the
            // user navigated to a different folder while we were fetching.
            while messages.count < Self.initialLoadTarget,
                  let token = result.nextPageToken,
                  currentFolder?.id == folder.id {
                result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: token)
                messages.append(contentsOf: result.headers)
                nextPageToken = result.nextPageToken
                store.saveHeaders(result.headers)
                recordContacts(from: result.headers, folder: folder)
            }
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
            hydrateCalendarIds()
            recordContacts(from: result.headers, folder: folder)
            statusMessage = nil
        } catch {
            statusMessage = "Couldn’t load more: \(error.localizedDescription)"
        }
    }

    func reloadCurrentFolder() async {
        // An auto/periodic refresh must not disturb what the user is looking at:
        //  - while searching, leave the result list alone — re-running the search
        //    would replace it (briefly flashing folder mail) and reset scroll;
        //  - otherwise merge fresh mail in place so scroll position is preserved.
        if !isSearching {
            await refreshMessages()
        }
        if let session = sessions.first(where: { $0.account.id == currentAccountId }) {
            try? await loadFolders(for: session)
        }
        if !isSearching, let folder = currentFolder { scanCalendarEvents(for: folder) }
        await refreshCurrentFolderCount()
    }

    /// In-place refresh used by the periodic timer and manual sync: updates the
    /// headers already on screen and prepends any new mail without rebuilding the
    /// list, so the scroll position is preserved. (A full `loadMessages` momentarily
    /// shrinks the list to the first page, which snaps the table back to the top.)
    private func refreshMessages() async {
        guard let folder = currentFolder, let provider = currentProvider else { return }
        do {
            let result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: nil)
            // Bail if the user navigated away or started a search meanwhile.
            guard currentFolder?.id == folder.id, !isSearching else { return }
            mergeFresh(result.headers)
            store.saveHeaders(result.headers)
            recordContacts(from: result.headers, folder: folder)
            hydrateCalendarIds()
            statusMessage = nil
        } catch {
            statusMessage = "Couldn’t refresh \(folder.name): \(error.localizedDescription)"
        }
    }

    /// Merges a freshly fetched first page into `messages`: updates the fields of
    /// messages still present (read/flag/…) and prepends genuinely new mail, leaving
    /// already-loaded older messages — and the array's order/identity — intact.
    private func mergeFresh(_ fresh: [MessageHeader]) {
        let freshById = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in messages.indices {
            guard var updated = freshById[messages[i].id] else { continue }
            // Keep the runtime-derived calendar flag (not part of list metadata).
            updated.isCalendarEvent = messages[i].isCalendarEvent
            if updated != messages[i] { messages[i] = updated }
        }
        let existingIds = Set(messages.map(\.id))
        let additions = fresh.filter { !existingIds.contains($0.id) }
        if !additions.isEmpty { messages.insert(contentsOf: additions, at: 0) }
    }

    func openMessage(_ id: String) async {
        guard let provider = currentProvider else { return }
        // Paint the cached body instantly so the preview is immediate; only show the
        // loading spinner when there's nothing cached to display yet.
        if let cached = store.cachedBody(id: id) {
            currentBody = cached
            isLoadingBody = false
        } else {
            isLoadingBody = true
        }
        defer { isLoadingBody = false }
        do {
            let body = try await provider.fetchBody(id: id)
            store.saveBody(body)
            noteCalendar(body)
            // Ignore a late network result if the user has moved to another message.
            if selection.count == 1, selection.first == id {
                currentBody = body
                await loadInviteContextIfNeeded(headerId: id, body: body)
            }
            if let header = messages.first(where: { $0.id == id }), !header.isRead {
                try? await provider.setRead(ids: [id], read: true)
                mutateLocal(ids: [id]) { $0.isRead = true }
                store.updateRead(ids: [id], read: true)
            }
        } catch {
            if currentBody == nil { errorMessage = error.localizedDescription }
        }
        prefetchAdjacentBodies(around: id)
    }

    /// Bodies for which a background prefetch is already in flight (avoids
    /// duplicate fetches when navigating back and forth).
    private var prefetchingBodies: Set<String> = []

    /// Warms the on-disk body cache for the messages immediately above and below
    /// `id` so navigating to a neighbour (arrow keys or click) is instant.
    private func prefetchAdjacentBodies(around id: String) {
        guard let provider = currentProvider else { return }
        let ids = displayedMessages.map(\.id)
        guard let idx = ids.firstIndex(of: id) else { return }
        let neighbours = [idx - 1, idx + 1].filter(ids.indices.contains).map { ids[$0] }
        for nid in neighbours where store.cachedBody(id: nid) == nil && !prefetchingBodies.contains(nid) {
            prefetchingBodies.insert(nid)
            Task {
                defer { prefetchingBodies.remove(nid) }
                if let body = try? await provider.fetchBody(id: nid) {
                    store.saveBody(body)
                    noteCalendar(body)
                }
            }
        }
    }

    /// Loads calendar context for an invitation body, or clears it otherwise.
    private func loadInviteContextIfNeeded(headerId: String, body: MessageBody) async {
        if let invite = body.calendar, invite.method == .request || invite.method == .cancel {
            await loadInviteContext(headerId: headerId, invite: invite)
        } else if inviteContextHeaderId == headerId {
            inviteContextHeaderId = nil
            inviteDayEvents = []
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
                noteCalendar(body)
                await loadInviteContextIfNeeded(headerId: id, body: body)
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

    /// Called when the search field is cleared (the X button): drop search mode
    /// and reload the folder's message list.
    func clearSearch() async {
        guard isSearching else { return }
        isSearching = false
        await loadMessages()
    }

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

    /// Junk-folder action: removes the messages from Spam and files them in the Inbox.
    func markNotSpam(_ ids: [String]) async {
        await withProvider { try await $0.markNotSpam(ids: ids) }
        removeLocal(ids: ids)
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
        Task {
            let body = await ensureBody(for: header)
            let to = header.from.email
            let subject = header.subject.hasPrefix("Re:") ? header.subject : "Re: \(header.subject)"
            let quoted = """
            <br><br>
            <p>On \(header.date.mailFullString), \(escape(header.from.display)) &lt;\(escape(header.from.email))&gt; wrote:</p>
            <blockquote style="margin:0 0 0 8px;padding-left:10px;border-left:2px solid #ccc">
            \(quotedBody(body, fallbackSnippet: header.snippet))
            </blockquote>
            """
            activeSheet = .compose(ComposeRequest(
                kind: all ? .replyAll : .reply,
                to: to,
                subject: subject,
                quotedHTML: quoted
            ))
        }
    }

    func startForward() {
        guard let header = selectedHeaders.first else { return }
        Task {
            let body = await ensureBody(for: header)
            let subject = header.subject.hasPrefix("Fwd:") ? header.subject : "Fwd: \(header.subject)"
            let forwardHeader = """
            <p>---------- Forwarded message ----------<br>
            From: \(escape(header.from.display)) &lt;\(escape(header.from.email))&gt;<br>
            Date: \(header.date.mailFullString)<br>
            Subject: \(escape(header.subject))</p>
            """
            activeSheet = .compose(ComposeRequest(
                kind: .forward,
                subject: subject,
                quotedHTML: forwardHeader + quotedBody(body, fallbackSnippet: header.snippet),
                attachments: body?.attachments ?? []
            ))
        }
    }

    /// Returns the message body for quoting/forwarding: the open preview, then the
    /// disk cache, then a fresh fetch — so reply/forward include the full original
    /// even when the message wasn't the one being previewed.
    private func ensureBody(for header: MessageHeader) async -> MessageBody? {
        if let body = bodyFor(header) { return body }
        if let cached = store.cachedBody(id: header.id) { return cached }
        guard let provider = currentProvider else { return nil }
        if let body = try? await provider.fetchBody(id: header.id) {
            store.saveBody(body)
            noteCalendar(body)
            return body
        }
        return nil
    }

    /// The original content to quote: HTML when present, else plain text, else the
    /// list snippet as a last resort. The HTML is carried through verbatim (only the
    /// `<body>` fragment is taken so it nests cleanly), preserving the original
    /// formatting — including inline images, which `fetchBody` has already embedded.
    private func quotedBody(_ body: MessageBody?, fallbackSnippet snippet: String) -> String {
        if let html = body?.html, !html.isEmpty { return PlainTextHTML.bodyFragment(html) }
        if let text = body?.plainText, !text.isEmpty {
            return "<p>\(escape(text).replacingOccurrences(of: "\n", with: "<br>"))</p>"
        }
        return "<p>\(escape(snippet))</p>"
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

    private var currentAccountIsGmail: Bool {
        sessions.first { $0.account.id == currentAccountId }?.account.providerKind == .gmail
    }

    /// Loads the user's Google Calendar events for the invitation's day so the
    /// card can show their schedule. Gmail-only; no-op (with an auth prompt) when
    /// the calendar scope hasn't been granted.
    func loadInviteContext(headerId: String, invite: CalendarInvite) async {
        inviteContextHeaderId = headerId
        inviteDayEvents = []
        inviteNeedsCalendarAuth = false
        inviteEventsError = nil
        guard let day = invite.start, currentAccountIsGmail else { return }
        guard (try? await GoogleAuth.shared.hasCalendarScope) == true else {
            inviteNeedsCalendarAuth = true
            return
        }
        inviteEventsLoading = true
        defer { inviteEventsLoading = false }
        do {
            let events = try await GoogleCalendarService.shared.events(onDayOf: day)
            if inviteContextHeaderId == headerId { inviteDayEvents = events }
        } catch {
            guard inviteContextHeaderId == headerId else { return }
            // Distinguish a missing/insufficient scope (re-consent helps → show the
            // Connect button) from any other failure such as the Calendar API being
            // disabled in the Cloud project (re-consent won't help → show the error,
            // which carries Google's "enable the API" link).
            if case let MailError.api(403, body) = error,
               body.contains("ACCESS_TOKEN_SCOPE_INSUFFICIENT") {
                inviteNeedsCalendarAuth = true
            } else {
                inviteEventsError = error.localizedDescription
            }
        }
    }

    /// Re-runs Google sign-in (now including the calendar scope) and reloads.
    func connectGoogleCalendar(forHeaderId headerId: String, invite: CalendarInvite) async {
        await signInForWriteAccess()
        await loadInviteContext(headerId: headerId, invite: invite)
        if inviteNeedsCalendarAuth {
            authMessage = """
            Calendar access wasn’t granted. On Google’s sign-in screen: pick your account; if it warns \
            “Google hasn’t verified this app”, click Advanced → “Go to newmail (unsafe)”; then keep the \
            “See the events on all your calendars” permission checked and click Continue.
            """
        }
    }

    /// Sends an RSVP to the invitation's organizer as an iCalendar REPLY email.
    /// Returns whether the reply was sent (the caller updates its UI state).
    @discardableResult
    func respondToInvite(_ invite: CalendarInvite, response: InviteResponse, note: String = "") async -> Bool {
        guard let provider = currentProvider else {
            errorMessage = "No account is selected."
            return false
        }
        guard let organizer = invite.organizer, !organizer.email.isEmpty else {
            errorMessage = "This invitation has no organizer to reply to."
            return false
        }
        let me = MailAddress(name: "", email: accountEmail)
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let ics = ICSReplyBuilder.reply(to: invite, attendee: me, response: response,
                                        comment: trimmedNote, now: Date())
        let subject = "\(response.subjectPrefix): \(invite.summary)"
        let mime = MIMEBuilder.buildICSReply(
            from: accountEmail, to: organizer.email, subject: subject, ics: ics, note: trimmedNote
        )
        do {
            try await provider.send(rawMIME: mime)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // MARK: - Attachments

    /// Opens an attachment with the system default app.
    func openAttachment(_ att: MailAttachment) async {
        if let url = await downloadToTemp(att) { NSWorkspace.shared.open(url) }
    }

    /// Saves a single attachment to ~/Downloads and reveals it in Finder.
    func downloadAttachment(_ att: MailAttachment) async {
        await saveToDownloads([att])
    }

    /// Saves all of a message's attachments to ~/Downloads.
    func downloadAllAttachments(_ atts: [MailAttachment]) async {
        await saveToDownloads(atts)
    }

    /// Previews attachments in Quick Look (optionally starting at one of them).
    func previewAttachments(_ atts: [MailAttachment], start: MailAttachment? = nil) async {
        var urls: [URL] = []
        for att in atts {
            if let url = await downloadToTemp(att) { urls.append(url) }
        }
        guard !urls.isEmpty else { return }
        let index = start.flatMap { s in atts.firstIndex { $0.id == s.id } } ?? 0
        QuickLookController.shared.preview(urls, startIndex: index)
    }

    /// Downloads remote attachments to temp files so they can be re-sent (forward).
    func materializeAttachments(_ atts: [MailAttachment]) async -> [URL] {
        var urls: [URL] = []
        for att in atts {
            if let url = await downloadToTemp(att) { urls.append(url) }
        }
        return urls
    }

    private func downloadToTemp(_ att: MailAttachment) async -> URL? {
        guard let provider = currentProvider else { return nil }
        do {
            let data = try await provider.fetchAttachment(messageId: att.messageId, attachmentId: att.id)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("attachments", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(att.filename)
            try data.write(to: url)
            return url
        } catch {
            statusMessage = "Couldn’t open \(att.filename): \(error.localizedDescription)"
            return nil
        }
    }

    private func saveToDownloads(_ atts: [MailAttachment]) async {
        guard let provider = currentProvider else { return }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        var savedURLs: [URL] = []
        for att in atts {
            do {
                let data = try await provider.fetchAttachment(messageId: att.messageId, attachmentId: att.id)
                let url = Self.uniqueURL(in: downloads, filename: att.filename)
                try data.write(to: url)
                savedURLs.append(url)
            } catch {
                statusMessage = "Couldn’t download \(att.filename): \(error.localizedDescription)"
            }
        }
        if savedURLs.count == 1 {
            NSWorkspace.shared.activateFileViewerSelecting(savedURLs)
        } else if savedURLs.count > 1 {
            statusMessage = "Downloaded \(savedURLs.count) attachments to Downloads."
        }
    }

    private static func uniqueURL(in dir: URL, filename: String) -> URL {
        let fm = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var url = dir.appendingPathComponent(filename)
        var i = 1
        while fm.fileExists(atPath: url.path) {
            let name = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            url = dir.appendingPathComponent(name)
            i += 1
        }
        return url
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
    /// Remote attachments to carry over (used when forwarding); fetched and
    /// attached by the compose view on appear.
    var attachments: [MailAttachment]

    init(kind: ComposeKind, to: String = "", subject: String = "", quoted: String = "",
         quotedHTML: String = "", attachments: [MailAttachment] = []) {
        self.kind = kind
        self.to = to
        self.cc = ""
        self.subject = subject
        self.body = quoted
        self.quotedHTML = quotedHTML
        self.attachments = attachments
    }
}
