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
    /// Polls every account's inbox for new mail to raise top-right popups.
    private var inboxPollTimer: Timer?
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

    // Currently presented modal sheet (custom snooze).
    var activeSheet: ActiveSheet?
    // The message shown in the read-only detail window, and its loaded body.
    // The window reads these reactively, so reopening retargets the same window.
    var modalHeader: MessageHeader?
    var modalBody: MessageBody?

    // Compose/reply/forward open in their own non-modal, movable, resizable windows.
    @ObservationIgnored private let composeWindows = ComposeWindowController()
    // The double-click message view opens in its own resizable window too.
    @ObservationIgnored private let messageWindows = MessageWindowController()

    // New-mail popups shown in a floating panel pinned to the top-right of the screen.
    var notifications: [MailNotification] = []
    // Calendar event reminder popups shown in the same floating panel.
    var eventReminders: [EventReminder] = []
    @ObservationIgnored private var reminderService: CalendarReminderService?
    // Last time a reminder alert sound played, to debounce simultaneous pop-ups.
    @ObservationIgnored private var lastReminderSound: Date?
    // Inbox message ids already seen per account, so only genuinely new mail pops.
    private var seenInboxIds: [String: Set<String>] = [:]
    @ObservationIgnored private var notificationPanel: NotificationPanelController?
    // Per-popup auto-dismiss timers (cancelled if the user starts a reply).
    @ObservationIgnored private var dismissTasks: [String: Task<Void, Never>] = [:]
    private static let maxNotifications = 5
    private static let autoDismissSeconds = 10

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
        .init(\MessageHeader.date, order: .reverse),
        // Unique tiebreaker: see `stableComparators`. Keeping it in the bound
        // sort order makes the Table's own click→row resolution unambiguous too.
        .init(\MessageHeader.id)
    ]
    var nextPageToken: String?

    /// Whether the list can pull an older page on demand — for both the folder
    /// listing and search results (`loadMore()` pages whichever is on screen).
    var canLoadMore: Bool { nextPageToken != nil }

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
    // Whether the list currently shows search results (not the plain folder listing).
    var isSearching = false
    // True only while a search request is in flight — drives the inline search-bar
    // spinner and the "Searching…" status, distinct from the background-sync `isLoading`.
    var isSearchInProgress = false
    // Set when a search completes ("Found 23 results" / "No results"); shown in the
    // status bar while viewing results. Cleared on clear / folder switch / new search.
    var searchResultSummary: String?
    // The query backing the current result set, so `loadMore()` can page it.
    private var activeSearchQuery: String?
    // The in-flight search, cancelled when a newer query supersedes it.
    private var searchTask: Task<Void, Never>?
    // Toggled by ⌘F to pull keyboard focus into the search field.
    var focusSearchRequested = false

    // Status
    var isLoading = false
    var errorMessage: String?
    // Non-modal status-bar message for connection / sync / load problems (shown
    // in the bottom bar instead of an alert). Cleared on the next success.
    var statusMessage: String?
    var authMessage: String?
    var isSigningIn = false
    var hasWriteScope = true
    // Conversation-cleanup progress and its transient result line in the status bar.
    var isCleaningUp = false
    // The live phase message shown while cleanup runs (started → comparing → …).
    var cleanupProgress: String?
    var cleanupResult: String?

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
                if a.date != b.date { return a.date > b.date }
                return a.id < b.id
            }
        }
        if let primary = sortOrder.first, primary.keyPath == \MessageHeader.calendarSort {
            let eventsFirst = primary.order == .forward
            return messages.sorted { a, b in
                if a.isCalendarEvent != b.isCalendarEvent {
                    return eventsFirst ? a.isCalendarEvent : b.isCalendarEvent
                }
                if a.date != b.date { return a.date > b.date }
                return a.id < b.id
            }
        }
        return messages.sorted(using: stableComparators)
    }

    /// The active sort with a unique `id` tiebreaker appended so no two rows ever
    /// compare equal. Messages that share a sort value (e.g. the same timestamp)
    /// are otherwise ambiguous to the Table, and a click can land on the wrong
    /// tied row — selecting/opening a different message than the one clicked.
    private var stableComparators: [KeyPathComparator<MessageHeader>] {
        if sortOrder.contains(where: { $0.keyPath == \MessageHeader.id }) { return sortOrder }
        return sortOrder + [KeyPathComparator(\MessageHeader.id)]
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

        // Float the new-mail popup panel and record a baseline of what's already
        // in each inbox (so the existing backlog doesn't pop on launch).
        notificationPanel = NotificationPanelController(
            rootView: NotificationStackView().environment(self)
        )
        await pollInboxes()
        startPeriodicRefresh()
        await startCalendarReminders()
    }

    /// Begins the background calendar-reminder scheduler for the Google account
    /// (no-op unless the token carries the calendar scope).
    private func startCalendarReminders() async {
        guard reminderService == nil,
              (try? await GoogleAuth.shared.hasCalendarScope) == true else { return }
        let service = CalendarReminderService()
        service.onFire = { [weak self] reminders in self?.presentReminders(reminders) }
        service.onCancelled = { [weak self] ids in self?.cancelReminders(ids) }
        service.start()
        reminderService = service
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
        // Skip the work (and the sidebar re-render) when nothing changed. The
        // periodic refresh runs this often; rebuilding an identical tree only
        // churns the List and is the main trigger for a stale selection
        // highlight lingering on a previously-selected row.
        guard foldersByAccount[session.account.id] != folders else { return }
        foldersByAccount[session.account.id] = folders
        store.saveFolders(folders, accountId: session.account.id)
        recomputeFavorites()
        updateDockBadge()
    }

    // MARK: - Folder management

    /// Number of sub-folders nested under `folder` (used to phrase the delete
    /// confirmation). Derived from the cached folder list by path prefix.
    func descendantCount(of folder: MailFolder) -> Int {
        let prefix = folder.path + "/"
        return (foldersByAccount[folder.accountId] ?? []).filter { $0.path.hasPrefix(prefix) }.count
    }

    /// Creates a folder named `name` in `accountId`, optionally nested under
    /// `parent`, then refreshes that account's folder list.
    func createFolder(named name: String, under parent: MailFolder?, accountId: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !trimmed.contains("/") else {
            errorMessage = "Folder names can't contain a “/”."
            return
        }
        guard let session = sessions.first(where: { $0.account.id == accountId }) else { return }
        await perform {
            _ = try await session.provider.createFolder(named: trimmed, parentId: parent?.id)
            try await self.loadFolders(for: session)
        }
    }

    /// Deletes `folder` and all of its sub-folders, then refreshes the folder
    /// list and clears the folder (and any descendants) from favorites, the
    /// quick-move bar, and the current selection.
    func deleteFolder(_ folder: MailFolder) async {
        guard let session = sessions.first(where: { $0.account.id == folder.accountId }) else { return }

        // Composite ids of the folder plus its descendants, captured before the
        // reload so favorites/quick-move can be pruned.
        let prefix = folder.path + "/"
        let removedIds = Set(([folder] + (foldersByAccount[folder.accountId] ?? [])
            .filter { $0.path.hasPrefix(prefix) }).map { $0.compositeId })

        errorMessage = nil
        await perform {
            try await session.provider.deleteFolder(id: folder.id)
            try await self.loadFolders(for: session)
        }
        guard errorMessage == nil else { return }

        favoriteOrder.removeAll { removedIds.contains($0) }
        quickMoveOrder.removeAll { removedIds.contains($0) }
        UserDefaults.standard.set(quickMoveOrder, forKey: "quickMoveFolderIds")
        persistFavorites()
        recomputeFavorites()

        if let current = currentFolder, removedIds.contains(current.compositeId) {
            currentFolder = nil
            messages = []
            currentBody = nil
            if let inbox = foldersByAccount[session.account.id]?.first(where: { $0.kind == .inbox }) {
                sidebarSelection = "acct:\(inbox.compositeId)"
                await selectFolder(inbox)
            }
        }
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
        // Poll inboxes more often than the folder refresh so new-mail popups feel timely.
        inboxPollTimer?.invalidate()
        inboxPollTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { await self?.pollInboxes() }
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

    /// Quick-move targets for a specific account — used by a new-mail popup, whose
    /// message may belong to an account other than the one currently on screen.
    func quickMoveForAccount(_ accountId: String) -> [MailFolder] {
        quickMoveFolders.filter { $0.accountId == accountId }
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

    /// Whether `folder` can receive a drop of the current selection: not the folder
    /// already being viewed, and either in the same account or a supported
    /// cross-account target (Outlook → Gmail).
    func isDropTarget(_ folder: MailFolder) -> Bool {
        guard folder.compositeId != currentFolder?.compositeId else { return false }
        return folder.accountId == currentAccountId || canMoveAcross(toAccountId: folder.accountId)
    }

    /// Cross-account moves are supported only Outlook → Gmail: Gmail can import a
    /// real received message via `messages.insert`, whereas Graph would only create
    /// a draft. The source is always the current account.
    private func canMoveAcross(toAccountId destId: String) -> Bool {
        guard destId != currentAccountId,
              let src = sessions.first(where: { $0.account.id == currentAccountId }),
              let dest = sessions.first(where: { $0.account.id == destId }) else { return false }
        return src.account.providerKind == .graph && dest.account.providerKind == .gmail
    }

    /// Moves dropped/quick-moved messages, routing same-account moves through the
    /// label/folder change and supported cross-account moves through a real
    /// export → import → delete transfer.
    func moveDropped(_ ids: [String], to folder: MailFolder) async {
        guard !ids.isEmpty, folder.compositeId != currentFolder?.compositeId else { return }
        if folder.accountId == currentAccountId {
            await move(ids, to: folder)
        } else if canMoveAcross(toAccountId: folder.accountId) {
            await moveAcrossAccounts(ids, to: folder)
        } else {
            statusMessage = "Can’t move into this account."
        }
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
        searchTask?.cancel()
        searchTask = nil
        searchText = ""
        isSearching = false
        isSearchInProgress = false
        activeSearchQuery = nil
        searchResultSummary = nil
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
        if let i = foldersByAccount[folder.accountId]?.firstIndex(where: { $0.id == folder.id }),
           foldersByAccount[folder.accountId]?[i].unreadCount != count.unread
            || foldersByAccount[folder.accountId]?[i].totalCount != count.total {
            // Only write on an actual change: rewriting an identical count would
            // re-render the sidebar List and can leave a stale selection highlight.
            foldersByAccount[folder.accountId]?[i].unreadCount = count.unread
            foldersByAccount[folder.accountId]?[i].totalCount = count.total
        }
        updateDockBadge()
    }

    /// Refreshes the current account's Drafts folder count so its sidebar badge
    /// reflects a just-saved or just-sent draft (the periodic per-folder refresh
    /// only covers the folder currently on screen).
    private func refreshDraftsCount() async {
        guard let accountId = currentAccountId, let provider = currentProvider,
              let draftsId = foldersByAccount[accountId]?.first(where: { $0.kind == .drafts })?.id,
              let count = try? await provider.folderCount(id: draftsId) else { return }
        var changed = false
        if let i = foldersByAccount[accountId]?.firstIndex(where: { $0.id == draftsId }),
           foldersByAccount[accountId]?[i].unreadCount != count.unread
            || foldersByAccount[accountId]?[i].totalCount != count.total {
            foldersByAccount[accountId]?[i].unreadCount = count.unread
            foldersByAccount[accountId]?[i].totalCount = count.total
            changed = true
        }
        if currentFolder?.id == draftsId {
            currentFolder?.unreadCount = count.unread
            currentFolder?.totalCount = count.total
        }
        if changed { recomputeFavorites() }
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
            // Network fetches suspend at `await`, during which the user may switch
            // folders (which starts a fresh `loadMessages` for the new folder). Bail
            // before touching the shared `messages`/`nextPageToken` so this folder's
            // results never overwrite the one now on screen.
            guard currentFolder?.id == folder.id else { return }
            messages = result.headers
            nextPageToken = result.nextPageToken
            store.saveHeaders(result.headers)
            hydrateCalendarIds()
            recordContacts(from: result.headers, folder: folder)

            // Keep paging until we hit the target or run out of mail, re-checking the
            // folder after each fetch for the same reason as above.
            while messages.count < Self.initialLoadTarget, let token = result.nextPageToken {
                result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: token)
                guard currentFolder?.id == folder.id else { return }
                messages.append(contentsOf: result.headers)
                nextPageToken = result.nextPageToken
                store.saveHeaders(result.headers)
                recordContacts(from: result.headers, folder: folder)
            }
            statusMessage = nil
            // Paged to the end without navigating away: `messages` is now the complete
            // server-side contents of this folder, so reconcile the cache to evict rows
            // that have since left it (e.g. a sent draft keeping a stale DRAFT label).
            if result.nextPageToken == nil {
                store.reconcileFolder(folderId: folder.id, accountId: folder.accountId,
                                      keepIds: messages.map(\.id))
            }
        } catch {
            guard currentFolder?.id == folder.id else { return }
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
            let result: (headers: [MessageHeader], nextPageToken: String?)
            if isSearching, let query = activeSearchQuery {
                // Page the search results, not the folder listing — mirror the scope
                // routing in `performSearch`.
                switch searchScope {
                case .currentFolder:
                    result = try await provider.listMessages(folderId: folder.id, query: query, pageToken: token)
                case .allFolders:
                    result = try await provider.search(query: query, pageToken: token)
                }
            } else {
                result = try await provider.listMessages(folderId: folder.id, query: nil, pageToken: token)
            }
            // Don't append this folder's older page onto a list the user has since
            // switched away from.
            guard currentFolder?.id == folder.id else { return }
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

    /// Mark-as-read is deferred: standing on a message only marks it read once
    /// the user has stayed on it for 3 seconds (cancelled if they move away).
    private var markReadTask: Task<Void, Never>?

    /// Schedule the selected message to be marked read after a 3-second dwell.
    /// Replaces any previously scheduled mark-read so quickly skimming messages
    /// doesn't mark them all read.
    func scheduleMarkRead(_ id: String) {
        markReadTask?.cancel()
        guard let header = messages.first(where: { $0.id == id }), !header.isRead else { return }
        markReadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            // Only mark read if this is still the sole selected message.
            guard self.selection.count == 1, self.selection.first == id else { return }
            guard let header = self.messages.first(where: { $0.id == id }), !header.isRead else { return }
            await self.markRead([id], read: true)
        }
    }

    func openMessage(_ id: String) async {
        guard let provider = currentProvider else { return }
        scheduleMarkRead(id)
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
        } catch {
            if currentBody == nil, !Self.isCancellation(error) { errorMessage = error.localizedDescription }
        }
        prefetchAdjacentBodies(around: id)
    }

    /// Network/task cancellations are benign — a superseded body fetch (e.g. the
    /// selection jumped to the next message right after a delete) or a torn-down
    /// view — so they must never surface as a "Something went wrong" alert.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
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
        // A draft opens in the compose window so it can be edited and resent,
        // rather than in the read-only message window.
        if isDraft(header) {
            openDraftForEditing(header, provider: provider)
            return
        }
        modalHeader = header
        modalBody = store.cachedBody(id: id)
        messageWindows.open(vm: self)
        Task {
            do {
                let body = try await provider.fetchBody(id: id)
                modalBody = body
                store.saveBody(body)
                noteCalendar(body)
                await loadInviteContextIfNeeded(headerId: id, body: body)
            } catch {
                if modalBody == nil, !Self.isCancellation(error) { errorMessage = error.localizedDescription }
            }
            // Mark read only after the message has been open for 3 seconds.
            if !header.isRead {
                try? await Task.sleep(for: .seconds(3))
                if let header = messages.first(where: { $0.id == id }), !header.isRead {
                    try? await provider.setRead(ids: [id], read: true)
                    mutateLocal(ids: [id]) { $0.isRead = true }
                    store.updateRead(ids: [id], read: true)
                }
            }
        }
    }

    /// Whether the header is an editable draft (lives in its account's Drafts folder).
    private func isDraft(_ header: MessageHeader) -> Bool {
        guard let draftsId = foldersByAccount[header.accountId]?.first(where: { $0.kind == .drafts })?.id
        else { return false }
        return header.labelIds.contains(draftsId)
    }

    /// Opens a Drafts message in the compose window pre-filled with its recipients,
    /// subject, body, and attachments, reusing its server draft id so continuing the
    /// draft updates the same one (and sending removes it) instead of duplicating it.
    private func openDraftForEditing(_ header: MessageHeader, provider: MailProvider) {
        Task {
            let body = await ensureBody(for: header)
            let draftId = try? await provider.draftId(forMessageId: header.id)
            // Images embedded in the body are re-adopted inline by the editor, so
            // drop image-typed attachments here to avoid sending them twice; non-image
            // files (PDFs, etc.) are still carried as attachments.
            let files = (body?.attachments ?? []).filter { !$0.mimeType.lowercased().hasPrefix("image/") }
            // Seed recipients as bare addresses (like reply does): MIMEBuilder writes
            // the To/Cc headers verbatim, so an unquoted display name with a comma
            // would be misread as extra recipients.
            let request = ComposeRequest(
                kind: .draft,
                to: header.to.map(\.email).filter { !$0.isEmpty }.joined(separator: ", "),
                subject: header.subject,
                attachments: files
            )
            request.cc = (body?.cc ?? []).map(\.email).filter { !$0.isEmpty }.joined(separator: ", ")
            request.bodyHTML = body?.html ?? ""
            request.draftId = draftId
            composeWindows.open(request, vm: self)
        }
    }

    /// Opens a message for editing. Drafts get the true draft editor; any other
    /// message opens in an "Edit" compose window whose Save replaces it with an
    /// edited copy (see `saveEditedMessage`).
    func editMessage(_ id: String) {
        guard let header = messages.first(where: { $0.id == id }), let provider = currentProvider else { return }
        if isDraft(header) {
            openDraftForEditing(header, provider: provider)
            return
        }
        // Replacing a message requires inserting a raw copy into its folder, which
        // only Gmail supports (Graph's MIME POST can only create drafts). Block edit
        // on Outlook up front so the user doesn't lose their changes on a doomed save.
        if sessions.first(where: { $0.account.id == header.accountId })?.account.providerKind == .graph {
            statusMessage = "Editing messages isn’t supported for Outlook accounts."
            return
        }
        Task {
            let body = await ensureBody(for: header)
            let files = (body?.attachments ?? []).filter { !$0.mimeType.lowercased().hasPrefix("image/") }
            let request = ComposeRequest(
                kind: .edit,
                to: header.to.map(\.email).filter { !$0.isEmpty }.joined(separator: ", "),
                subject: header.subject,
                attachments: files
            )
            request.cc = (body?.cc ?? []).map(\.email).filter { !$0.isEmpty }.joined(separator: ", ")
            request.bodyHTML = body?.html ?? ""
            request.originalMessageId = header.id
            request.originalFrom = header.from.nameAndEmail
            request.originalDate = header.date
            request.originalFolderId = currentFolder?.id
            request.originalIsRead = header.isRead
            request.originalIsFlagged = header.isFlagged
            composeWindows.open(request, vm: self)
        }
    }

    /// Saves an edit by inserting a new copy of the message with the user's changes
    /// (preserving the original sender and date) into its folder, then deleting the
    /// original. Messages are immutable on the server, so this replace is the only
    /// way to "edit"; the original is removed only after the insert succeeds.
    func saveEditedMessage(_ request: ComposeRequest, html: String, attachments: [URL],
                           inlineImages: [ComposeInlineImage]) async {
        guard let provider = currentProvider, let originalId = request.originalMessageId else { return }
        let scoped = attachments.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let mime = MIMEBuilder.buildHTML(
            from: request.originalFrom, to: request.to, cc: request.cc, subject: request.subject,
            html: html, attachments: attachments, inlineImages: inlineImages, date: request.originalDate
        )
        let folderId = request.originalFolderId ?? currentFolder?.id ?? "INBOX"
        do {
            let newId = try await provider.importRawMessage(mime, toFolderId: folderId, markUnread: !request.originalIsRead)
            // Re-apply the flag (insert only carries the folder + unread labels).
            if request.originalIsFlagged {
                try? await provider.setFlagged(ids: [newId], flagged: true)
            }
            // Trash (not permanent delete) so it works with Gmail's modify scope and
            // the pre-edit original stays recoverable in Trash.
            try await provider.trash(ids: [originalId])
            removeLocal(ids: [originalId])
            await reloadCurrentFolder()
        } catch {
            errorMessage = "Couldn’t save edits: \(error.localizedDescription)"
        }
    }

    func requestCustomSnooze(_ ids: [String]) {
        activeSheet = .customSnooze(ids)
    }

    /// Reloads the Drafts list after a compose window closes so its rows stay current.
    /// A draft save changes the underlying message (Gmail re-versions it on update,
    /// Graph deletes and recreates it), and the in-place merge can't drop the now-dead
    /// row — leaving a stale/duplicate entry that reopens to a deleted message. A full
    /// reload reconciles the list to the drafts that actually exist.
    func reloadDraftsAfterCompose() async {
        guard currentFolder?.kind == .drafts else { return }
        await loadMessages()
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

    /// Called when the user clears the search field (the X button or Escape):
    /// empties the field, drops search mode, and reloads the folder's full
    /// message list. Restores the cached folder list synchronously so it reappears
    /// instantly, then refreshes from the server in the background.
    func clearSearch() async {
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
        isSearchInProgress = false
        searchText = ""
        activeSearchQuery = nil
        searchResultSummary = nil
        if let folder = currentFolder {
            messages = store.cachedHeaders(folderId: folder.id, accountId: folder.accountId)
        }
        await loadMessages()
    }

    func runSearch() async {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            await clearSearch()
            return
        }
        // A newer query supersedes any search still in flight, so its late response
        // can't overwrite these results.
        searchTask?.cancel()
        let task = Task { await performSearch(text) }
        searchTask = task
        await task.value
    }

    private func performSearch(_ text: String) async {
        guard let provider = currentProvider else { return }
        isSearching = true
        isSearchInProgress = true
        searchResultSummary = nil
        let scope = searchScope
        defer { isSearchInProgress = false }
        do {
            let result: (headers: [MessageHeader], nextPageToken: String?)
            switch scope {
            case .currentFolder:
                let folderId = currentFolder?.id ?? "INBOX"
                result = try await provider.listMessages(folderId: folderId, query: text, pageToken: nil)
            case .allFolders:
                result = try await provider.search(query: text, pageToken: nil)
            }
            // A newer search (or a clear) started while this one was suspended at the
            // network await — discard this stale response rather than flash it on screen.
            guard !Task.isCancelled else { return }
            messages = result.headers
            nextPageToken = result.nextPageToken
            activeSearchQuery = text
            store.saveHeaders(result.headers)
            if result.headers.isEmpty {
                searchResultSummary = "No results"
            } else {
                let more = result.nextPageToken != nil ? "+" : ""
                searchResultSummary = "Found \(result.headers.count)\(more) result(s)"
            }
        } catch {
            // A superseded search cancels the in-flight request, which surfaces as
            // either Task cancellation or a URLError(.cancelled); neither is a real
            // failure, so don't flash a "Something went wrong" alert.
            guard !Task.isCancelled, !Self.isCancellation(error) else { return }
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
        guard let provider = currentProvider else {
            errorMessage = "No account is selected."
            return
        }
        // Remove from the list right away so deletion feels instant, then trash on
        // the server in the background. `removeLocal` runs synchronously before the
        // first `await`, so the UI updates immediately; if the trash fails we put
        // the messages back and report the error.
        let removed = messages.filter { ids.contains($0.id) }
        let sourceFolderId = currentFolder?.id
        let sourceAccountId = currentAccountId
        removeLocal(ids: ids)
        do {
            try await provider.trash(ids: ids)
            // Remember this delete so ⌘Z can put it back where it came from.
            if let sourceFolderId, let sourceAccountId {
                lastDeleted = (removed, sourceFolderId, sourceAccountId)
            }
        } catch {
            restoreLocal(removed)
            errorMessage = "Couldn’t delete: \(error.localizedDescription)"
        }
    }

    /// The most recent delete, retained so ⌘Z can restore it to its source folder.
    private var lastDeleted: (headers: [MessageHeader], folderId: String, accountId: String)?

    /// ⌘Z: restores the most recently deleted messages to the folder they were
    /// deleted from, then forgets them (single-level undo).
    func undoLastDelete() async {
        guard let batch = lastDeleted,
              let session = sessions.first(where: { $0.account.id == batch.accountId }) else { return }
        lastDeleted = nil
        do {
            try await session.provider.untrash(ids: batch.headers.map(\.id), toFolderId: batch.folderId)
            // Reappear instantly if that folder is still on screen. (For Graph the
            // restored copy has a fresh id, so these rows are cosmetic until the
            // next folder refresh reconciles them; Gmail keeps the same id.)
            if currentAccountId == batch.accountId, currentFolder?.id == batch.folderId {
                restoreLocal(batch.headers)
            }
            await refreshCurrentFolderCount()
        } catch {
            errorMessage = "Couldn’t undo delete: \(error.localizedDescription)"
        }
    }

    /// Removes redundant messages in the selected message's conversation: any earlier
    /// message whose content is quoted in full by the selected message (e.g. an
    /// intermediate reply still sitting in the folder) is trashed. Reports the count
    /// in the status bar and shows progress while it runs. Single-selection only.
    func cleanupConversation() async {
        guard selection.count == 1, let selectedId = selection.first,
              let selected = messages.first(where: { $0.id == selectedId }) else { return }
        isCleaningUp = true
        cleanupResult = nil
        cleanupProgress = "Cleanup started…"
        defer { isCleaningUp = false; cleanupProgress = nil }

        guard let selectedBody = await ensureBody(for: selected) else {
            setCleanupResult("Cleanup: couldn’t load the selected message.")
            return
        }
        let target = canonicalContent(selectedBody)
        guard target.count >= 8 else { setCleanupResult("Cleanup: nothing to compare."); return }

        // Only messages in the same conversation can be quoted by this one; an older
        // message that's a substring of the selected one is redundant.
        let candidates = messages.filter {
            $0.id != selectedId && $0.threadId == selected.threadId && $0.date <= selected.date
        }
        var toDelete: [String] = []
        for (index, cand) in candidates.enumerated() {
            cleanupProgress = "Cleaning up… comparing \(index + 1) of \(candidates.count)"
            guard let body = await ensureBody(for: cand) else { continue }
            let content = canonicalContent(body)
            guard content.count >= 8, content.count <= target.count else { continue }
            if target.contains(content) { toDelete.append(cand.id) }
        }

        if toDelete.isEmpty {
            setCleanupResult("Cleanup: no redundant messages found.")
        } else {
            await deleteMessages(toDelete)
            let n = toDelete.count
            setCleanupResult("Cleanup: deleted \(n) message\(n == 1 ? "" : "s").")
        }
    }

    /// Shows a cleanup result in the status bar, auto-clearing after a few seconds.
    private func setCleanupResult(_ message: String) {
        cleanupResult = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            if self?.cleanupResult == message { self?.cleanupResult = nil }
        }
    }

    /// Normalizes a body to a comparable token stream: strips quote markers, collapses
    /// whitespace, and lowercases — so a quoted copy matches the original regardless of
    /// re-wrapping. Prefers the plain-text part, falling back to crudely stripped HTML.
    private func canonicalContent(_ body: MessageBody) -> String {
        let text = body.plainText.isEmpty ? Self.stripHTML(body.html) : body.plainText
        return text
            .replacingOccurrences(of: ">", with: " ")
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Crude tag strip for bodies with no plain-text part (drops style/script blocks
    /// first so their contents don't leak into the comparison).
    private static func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<style[^>]*>[\\s\\S]*?</style>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
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
        guard let provider = currentProvider else {
            errorMessage = "No account is selected."
            return
        }
        // Remove from the list right away so the move feels instant, then move on
        // the server in the background. `removeLocal` runs synchronously before the
        // first `await`, so the UI updates immediately; if the move fails we put the
        // messages back and report the error.
        let removed = messages.filter { ids.contains($0.id) }
        let fromFolderId = currentFolder?.id
        removeLocal(ids: ids)
        do {
            try await provider.move(ids: ids, toFolderId: folder.id, fromFolderId: fromFolderId)
        } catch {
            restoreLocal(removed)
            errorMessage = "Couldn’t move: \(error.localizedDescription)"
        }
    }

    /// Moves messages from the current (Outlook) account into a folder of another
    /// (Gmail) account: exports each message's original MIME, re-creates it as a real
    /// message in the destination, then permanently deletes the source copy. The
    /// delete only runs after the import succeeds, so a failure never loses mail; on
    /// the first failure we stop and leave already-moved messages moved.
    func moveAcrossAccounts(_ ids: [String], to folder: MailFolder) async {
        guard let source = sessions.first(where: { $0.account.id == currentAccountId }),
              let dest = sessions.first(where: { $0.account.id == folder.accountId }) else { return }
        // Importing into Gmail needs write scope; prompt for it rather than 403-ing.
        if dest.account.providerKind == .gmail, !gmailWriteScope {
            statusMessage = "Grant Gmail write access to move messages into Gmail."
            await signInForWriteAccess()
            guard gmailWriteScope else { return }
        }
        let batch = messages.filter { ids.contains($0.id) }
        // Remove from the list right away so the move feels instant, then export,
        // import, and delete each message on the server in the background. The source
        // copy is only deleted after its import succeeds, so a failure never loses
        // mail; any message that didn't make it over is put back in the list.
        removeLocal(ids: batch.map(\.id))
        var moved = 0
        for (index, header) in batch.enumerated() {
            do {
                let raw = try await source.provider.exportRawMessage(id: header.id)
                _ = try await dest.provider.importRawMessage(raw, toFolderId: folder.id, markUnread: !header.isRead)
                try await source.provider.permanentlyDelete(ids: [header.id])
                moved += 1
            } catch {
                // Put back this message and any not yet processed, then stop.
                restoreLocal(Array(batch[index...]))
                errorMessage = "Couldn’t move “\(header.subject)”: \(error.localizedDescription)"
                break
            }
        }
        if moved > 0 {
            let name = dest.account.displayName.isEmpty ? dest.account.email : dest.account.displayName
            statusMessage = "Moved \(moved) message\(moved == 1 ? "" : "s") to \(name)."
        }
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
        composeWindows.open(ComposeRequest(kind: .new), vm: self)
    }

    /// Opens a fresh compose window addressed to a single recipient (used by the
    /// reading pane's recipient chips).
    func startNewMail(to address: String) {
        composeWindows.open(ComposeRequest(kind: .new, to: address), vm: self)
    }

    /// Handles a `mailto:` URL (e.g. the app is the default mail client and the
    /// user clicked a mail link) by opening a compose window pre-filled from the
    /// URL's recipient and `subject`/`cc`/`body` query parameters.
    func handleMailto(_ url: URL) {
        guard url.scheme?.lowercased() == "mailto" else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // The recipient list is the URL's opaque body (everything before `?`);
        // `.path` and query-item values are already percent-decoded.
        let to = components?.path ?? ""
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String {
            items.first { $0.name.lowercased() == name }?.value ?? ""
        }
        let request = ComposeRequest(kind: .new, to: to, subject: value("subject"))
        request.cc = value("cc")
        request.body = value("body")
        composeWindows.open(request, vm: self)
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
            composeWindows.open(ComposeRequest(
                kind: all ? .replyAll : .reply,
                to: to,
                subject: subject,
                quotedHTML: quoted
            ), vm: self)
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
            composeWindows.open(ComposeRequest(
                kind: .forward,
                subject: subject,
                quotedHTML: forwardHeader + quotedBody(body, fallbackSnippet: header.snippet),
                attachments: body?.attachments ?? []
            ), vm: self)
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

    func sendComposed(to: String, cc: String, subject: String, html: String, attachments: [URL], inlineImages: [ComposeInlineImage] = [], draftId: String? = nil) async {
        // Remember who we send to so they autocomplete next time.
        contactStore.record(MailAddress.parseList(to) + MailAddress.parseList(cc))
        guard let provider = currentProvider else {
            errorMessage = "No account is selected."
            return
        }
        let scoped = attachments.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let mime = MIMEBuilder.buildHTML(
            from: accountEmail, to: to, cc: cc, subject: subject, html: html,
            attachments: attachments, inlineImages: inlineImages
        )
        do {
            try await provider.send(rawMIME: mime)
            // Only drop the saved draft once the send actually succeeds.
            if let draftId {
                try? await provider.deleteDraft(id: draftId)
                await refreshDraftsCount()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Saves (or replaces) the autosaved draft for an in-progress compose, returning
    /// the draft's id so the caller can keep updating and later delete it. Returns the
    /// prior id unchanged on failure so a transient error doesn't orphan the draft.
    func saveDraft(to: String, cc: String, subject: String, html: String,
                   attachments: [URL], inlineImages: [ComposeInlineImage] = [], draftId: String?) async -> String? {
        guard let provider = currentProvider else { return draftId }
        let scoped = attachments.filter { $0.startAccessingSecurityScopedResource() }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        let mime = MIMEBuilder.buildHTML(
            from: accountEmail, to: to, cc: cc, subject: subject, html: html,
            attachments: attachments, inlineImages: inlineImages
        )
        let newId = (try? await provider.saveDraft(id: draftId, rawMIME: mime)) ?? draftId
        // A brand-new draft (no prior id) changes the Drafts folder count; an
        // in-place update of an existing draft leaves the count unchanged.
        if draftId == nil, newId != nil { await refreshDraftsCount() }
        return newId
    }

    // MARK: - New-mail notifications

    /// Polls every account's inbox for newly-arrived unread mail and raises a
    /// top-right popup for each. The first poll per account only records a
    /// baseline (so the existing inbox doesn't pop on launch).
    private func pollInboxes() async {
        for session in sessions {
            guard let inbox = foldersByAccount[session.account.id]?.first(where: { $0.kind == .inbox }) else { continue }
            guard let result = try? await session.provider.listMessages(folderId: inbox.id, query: nil, pageToken: nil) else { continue }
            let headers = result.headers
            let currentIds = Set(headers.map(\.id))
            guard let seen = seenInboxIds[session.account.id] else {
                seenInboxIds[session.account.id] = currentIds
                continue
            }
            let fresh = headers.filter { !seen.contains($0.id) && !$0.isRead }
            seenInboxIds[session.account.id] = seen.union(currentIds)
            // Present oldest-first so the newest message ends up on top of the stack.
            for header in fresh.reversed() {
                presentNotification(header, accountId: session.account.id)
            }
        }
    }

    private func presentNotification(_ header: MessageHeader, accountId: String) {
        guard !notifications.contains(where: { $0.id == header.id }) else { return }
        notifications.insert(MailNotification(header: header, accountId: accountId), at: 0)
        if notifications.count > Self.maxNotifications {
            notifications.removeLast(notifications.count - Self.maxNotifications)
        }
        syncNotificationPanel()
        // Auto-dismiss the card after a few seconds (unless the user starts a reply).
        dismissTasks[header.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
            guard !Task.isCancelled else { return }
            self?.dismissNotification(header.id)
        }
    }

    /// Trashes a popup's message via the account that received it (not necessarily
    /// the currently-selected one) and closes the card.
    func deleteNotification(_ note: MailNotification) async {
        guard let session = sessions.first(where: { $0.account.id == note.accountId }) else { return }
        do {
            try await session.provider.trash(ids: [note.id])
            // Reflect the removal in the list if that account's folder is on screen.
            if currentAccountId == note.accountId { removeLocal(ids: [note.id]) }
            dismissNotification(note.id)
        } catch {
            errorMessage = "Couldn’t delete message: \(error.localizedDescription)"
        }
    }

    /// Moves a popup's message into a quick-move folder via the account that received
    /// it (not necessarily the current one), then dismisses the card. The target is
    /// always within that same account, so no cross-account import is needed.
    func moveNotification(_ note: MailNotification, to folder: MailFolder) async {
        guard let session = sessions.first(where: { $0.account.id == note.accountId }) else { return }
        let inboxId = foldersByAccount[note.accountId]?.first(where: { $0.kind == .inbox })?.id
        do {
            try await session.provider.move(ids: [note.id], toFolderId: folder.id, fromFolderId: inboxId)
            // Reflect the removal in the list if that account's folder is on screen.
            if currentAccountId == note.accountId { removeLocal(ids: [note.id]) }
            dismissNotification(note.id)
        } catch {
            errorMessage = "Couldn’t move message: \(error.localizedDescription)"
        }
    }

    func dismissNotification(_ id: String) {
        cancelAutoDismiss(id)
        notifications.removeAll { $0.id == id }
        syncNotificationPanel()
    }

    /// Stops a card's auto-dismiss timer — called when the user opens its reply
    /// editor so it doesn't disappear while they're typing.
    func cancelAutoDismiss(_ id: String) {
        dismissTasks[id]?.cancel()
        dismissTasks[id] = nil
    }

    /// Clicking a popup brings the app forward and selects the message in its
    /// account's inbox (loading it into the preview), then closes the card.
    func focusMessage(_ note: MailNotification) async {
        NSApp.activate(ignoringOtherApps: true)
        // Bring the main window (not our floating panel) to the front.
        for window in NSApp.windows where !(window is FloatingPanel) && window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            break
        }
        if let inbox = foldersByAccount[note.accountId]?.first(where: { $0.kind == .inbox }) {
            sidebarSelection = "acct:\(inbox.compositeId)"
            await selectFolder(inbox)
            // The message may have arrived after the inbox last listed (or selectFolder
            // was a no-op because we were already there), so its row can be absent from
            // the list. Seed it from the notification's header so the row exists and is
            // selectable — the open below then fetches the body.
            if !messages.contains(where: { $0.id == note.id }) {
                messages.append(note.header)
                store.saveHeaders([note.header])
            }
        }
        selection = [note.id]
        await openMessage(note.id)
        dismissNotification(note.id)
    }

    /// Sends a quick plain-text reply to a popup's message via the account that
    /// received it (not necessarily the currently-selected one).
    func sendQuickReply(_ note: MailNotification, text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let session = sessions.first(where: { $0.account.id == note.accountId }) else { return }
        let header = note.header
        let subject = header.subject.hasPrefix("Re:") ? header.subject : "Re: \(header.subject)"
        let mime = MIMEBuilder.buildHTML(
            from: session.account.email, to: header.from.email, cc: "",
            subject: subject, html: quickReplyHTML(text: trimmed, replyingTo: header), attachments: []
        )
        do {
            try await session.provider.send(rawMIME: mime)
            contactStore.record([header.from])
            dismissNotification(note.id)
        } catch {
            errorMessage = "Couldn’t send reply: \(error.localizedDescription)"
        }
    }

    /// The typed reply followed by a simple attribution + snippet quote of the
    /// original (the popup quotes the list snippet rather than fetching the full body).
    private func quickReplyHTML(text: String, replyingTo header: MessageHeader) -> String {
        let typed = escape(text).replacingOccurrences(of: "\n", with: "<br>")
        let quoted = """
        <p>On \(header.date.mailFullString), \(escape(header.from.display)) &lt;\(escape(header.from.email))&gt; wrote:</p>
        <blockquote style="margin:0 0 0 8px;padding-left:10px;border-left:2px solid #ccc">
        <p>\(escape(header.snippet))</p>
        </blockquote>
        """
        return "<html><head><meta charset=\"utf-8\"></head><body><p>\(typed)</p><br>\(quoted)</body></html>"
    }

    private func syncNotificationPanel() {
        if notifications.isEmpty && eventReminders.isEmpty { notificationPanel?.hide() }
        else { notificationPanel?.show() }
    }

    // MARK: - Calendar reminders

    /// Raises a popup card for each fired reminder. Unlike mail popups, reminder
    /// cards have no auto-dismiss timer — they persist until the user acts.
    private func presentReminders(_ reminders: [EventReminder]) {
        var didAdd = false
        for reminder in reminders where !eventReminders.contains(where: { $0.id == reminder.id }) {
            eventReminders.insert(reminder, at: 0)
            didAdd = true
        }
        syncNotificationPanel()
        if didAdd { playReminderSound() }
    }

    /// Plays a single alert sound when reminder cards appear. Debounced so a batch
    /// of reminders firing together (or back-to-back ticks) makes one sound, not one
    /// per card.
    private func playReminderSound() {
        let now = Date()
        if let last = lastReminderSound, now.timeIntervalSince(last) < 2 { return }
        lastReminderSound = now
        (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
    }

    func snoozeReminder(_ reminder: EventReminder, preset: CalendarReminderService.SnoozePreset) {
        // Close the popup first; defer the bookkeeping to the next runloop tick so
        // the card disappears immediately instead of after the service work.
        eventReminders.removeAll { $0.id == reminder.id }
        syncNotificationPanel()
        DispatchQueue.main.async { [weak self] in
            self?.reminderService?.snooze(reminder, preset: preset)
        }
    }

    func dismissReminder(_ id: String) {
        // Close the popup first; defer the bookkeeping to the next runloop tick so
        // the card disappears immediately instead of after the service work.
        eventReminders.removeAll { $0.id == id }
        syncNotificationPanel()
        DispatchQueue.main.async { [weak self] in
            self?.reminderService?.dismiss(id)
        }
    }

    func dismissAllReminders() {
        for reminder in eventReminders { reminderService?.dismiss(reminder.id) }
        eventReminders.removeAll()
        syncNotificationPanel()
    }

    /// Pulls cards for reminders the service found are backed by a now-deleted
    /// calendar event (verified once a minute while a popup is showing).
    private func cancelReminders(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let gone = Set(ids)
        eventReminders.removeAll { gone.contains($0.id) }
        syncNotificationPanel()
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

    /// Copies the attachment to the clipboard as a file (like Finder's Copy), so
    /// it can be pasted into Finder, a chat, a new mail, etc.
    func copyAttachment(_ att: MailAttachment) async {
        guard let url = await downloadToTemp(att) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
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

    /// Re-inserts headers that were optimistically removed (e.g. a delete whose
    /// server trash failed). The list's sort restores their display position; the
    /// selection is left wherever it landed after the optimistic removal.
    private func restoreLocal(_ headers: [MessageHeader]) {
        let existing = Set(messages.map(\.id))
        let toAdd = headers.filter { !existing.contains($0.id) }
        guard !toAdd.isEmpty else { return }
        messages.append(contentsOf: toAdd)
        store.saveHeaders(toAdd)
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

/// A newly-arrived message shown as a top-right popup card.
struct MailNotification: Identifiable, Hashable {
    let header: MessageHeader
    let accountId: String
    var id: String { header.id }
}

enum ActiveSheet: Identifiable {
    case customSnooze([String])

    var id: String {
        switch self {
        case .customSnooze: return "snooze"
        }
    }
}

enum ComposeKind {
    case new, reply, replyAll, forward, draft, edit
    var title: String {
        switch self {
        case .new: return "New Message"
        case .reply: return "Reply"
        case .replyAll: return "Reply All"
        case .forward: return "Forward"
        case .draft: return "Draft"
        case .edit: return "Edit Message"
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
    /// Existing HTML body to load into the editor when continuing a saved draft.
    var bodyHTML: String = ""
    var quotedHTML: String
    /// Remote attachments to carry over (used when forwarding); fetched and
    /// attached by the compose view on appear.
    var attachments: [MailAttachment]
    /// Server-side id of the autosaved draft for this compose, once one exists.
    var draftId: String?

    // MARK: - Edit (kind == .edit): the original message being replaced on Save.
    /// The message this edit replaces; Save inserts an edited copy and deletes it.
    var originalMessageId: String?
    /// The original sender ("Name <email>"), preserved so the edited copy looks the same.
    var originalFrom: String = ""
    /// The original date, preserved on the edited copy.
    var originalDate: Date?
    /// The folder the original lives in; the edited copy is inserted there.
    var originalFolderId: String?
    /// The original read state, so the edited copy keeps it.
    var originalIsRead: Bool = true
    /// The original flagged state, re-applied to the edited copy.
    var originalIsFlagged: Bool = false

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
