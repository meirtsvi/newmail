import Foundation
import SwiftData

/// Keeps the local cache in step with the server using each provider's change
/// feed, as Penguin Mail does: Gmail's history (one feed for the whole
/// mailbox) and Graph's per-folder delta query. The first sync of an account
/// (or folder) downloads every message from the last `windowDays` days; after
/// that each pass asks only for what changed since the stored cursor.
///
/// Cadence (driven by the caller's timer): Gmail's single feed every pass;
/// on Graph the Inbox and the open folder every pass, every other folder at
/// most every `otherFoldersInterval`.
@MainActor
final class SyncEngine {
    static let windowDays = 90
    static var windowStart: Date {
        Calendar.current.date(byAdding: .day, value: -windowDays, to: Date()) ?? Date()
    }
    private static let otherFoldersInterval: TimeInterval = 300

    struct Account {
        let id: String
        let provider: MailProvider
        let folders: [MailFolder]
    }

    /// What one sync step changed in the cache, for the UI to reflect.
    struct Update {
        let accountId: String
        /// New or changed headers now in the cache.
        let upserted: [MessageHeader]
        /// Of `upserted`, the ids that weren't cached before.
        let newIds: Set<String>
        let removedIds: [String]
        /// The folder the removals apply to (Graph); nil = deleted outright.
        let folderId: String?
        /// True while an account or folder is being downloaded for the first time.
        let isInitial: Bool
    }

    var onUpdate: ((Update) -> Void)?
    /// Progress text while a first download runs; nil when idle.
    var onProgress: ((String?) -> Void)?
    /// Message ids with local changes not yet on the server, per account.
    var pendingIds: (String) -> Set<String> = { _ in [] }

    private let store: MailStore
    private let context: ModelContext
    private(set) var running = false
    private var lastOtherFolders: [String: Date] = [:]
    private var downloaded = 0

    init(store: MailStore, context: ModelContext? = nil) {
        self.store = store
        self.context = context ?? Persistence.container.mainContext
    }

    /// Whether `folder` has been fully downloaded once, so the cache can stand
    /// in for a server listing of its recent mail.
    func isSynced(_ folder: MailFolder, provider: MailProvider) -> Bool {
        guard let cursor = cursor(Self.key(folder.accountId, provider.syncsPerFolder ? folder.id : nil)) else { return false }
        return !cursor.hasPrefix(SyncChanges.resumePrefix)
    }

    /// Forgets an account's sync state (it was removed).
    func forget(accountId: String) {
        let prefix = accountId
        let rows = (try? context.fetch(FetchDescriptor<SyncCursor>())) ?? []
        for row in rows where row.key == prefix || row.key.hasPrefix(prefix + "\u{1}") {
            context.delete(row)
        }
        try? context.save()
        lastOtherFolders[accountId] = nil
    }

    /// One sync pass over `accounts`. `priorityFolderIds` (the open folder) are
    /// synced every pass on per-folder providers. Returns the first error that
    /// wasn't a lost connection, for the status bar.
    @discardableResult
    func sync(_ accounts: [Account], priorityFolderIds: Set<String>) async -> Error? {
        guard !running else { return nil }
        running = true
        downloaded = 0
        defer {
            running = false
            onProgress?(nil)
        }
        var firstError: Error?
        for account in accounts {
            if account.provider.syncsPerFolder {
                let now = Date()
                let allDue = lastOtherFolders[account.id].map { now.timeIntervalSince($0) >= Self.otherFoldersInterval } ?? true
                let folders = account.folders.filter {
                    allDue || $0.kind == .inbox || priorityFolderIds.contains($0.id)
                }
                for folder in folders {
                    do {
                        try await syncFeed(account, folderId: folder.id)
                    } catch {
                        if NetworkMonitor.isConnectivityError(error) { return nil }
                        firstError = firstError ?? error
                    }
                }
                if allDue { lastOtherFolders[account.id] = now }
            } else {
                do {
                    try await syncFeed(account, folderId: nil)
                } catch {
                    if NetworkMonitor.isConnectivityError(error) { return nil }
                    firstError = firstError ?? error
                }
            }
        }
        return firstError
    }

    private func syncFeed(_ account: Account, folderId: String?) async throws {
        let key = Self.key(account.id, folderId)
        let cursor = cursor(key)
        var listed = Set<String>()
        do {
            let changes = try await account.provider.changes(
                folderId: folderId, cursor: cursor, since: Self.windowStart
            ) { page, resumeCursor in
                listed.formUnion(page.map(\.id))
                apply(account.id, upserted: page, removed: [], folderId: folderId, isInitial: true)
                // Saved per page, so an interrupted download continues from here.
                setCursor(key, resumeCursor)
                downloaded += page.count
                onProgress?("Downloading mail for offline use… \(downloaded.formatted()) messages")
            }
            apply(account.id, upserted: changes.upserted, removed: changes.removedIds,
                  folderId: folderId, isInitial: false)
            if cursor == nil, folderId == nil {
                // A full mailbox listing (Gmail) done in one go: cached recent mail
                // it didn't include was deleted on the server while we weren't
                // syncing. (A resumed download saw only part of the list.)
                store.dropUnlisted(accountId: account.id, since: Self.windowStart, keep: listed)
            }
            setCursor(key, changes.cursor)
        } catch SyncError.cursorExpired {
            // Too far behind to resume; the next pass downloads it afresh.
            clearCursor(key)
        }
    }

    private func apply(_ accountId: String, upserted: [MessageHeader], removed: [String],
                       folderId: String?, isInitial: Bool) {
        guard !upserted.isEmpty || !removed.isEmpty else { return }
        // A message with a local change still owed to the server keeps its local
        // state; the server's copy is older until the change lands.
        let pending = pendingIds(accountId)
        let fresh = upserted.filter { !pending.contains($0.id) }
        let known = store.existingIds(fresh.map(\.id))
        store.saveHeaders(fresh)
        if let folderId {
            store.removeFromFolder(ids: removed, folderId: folderId)
        } else {
            store.deleteMessages(ids: removed)
        }
        onUpdate?(Update(accountId: accountId, upserted: fresh,
                         newIds: Set(fresh.map(\.id)).subtracting(known),
                         removedIds: removed, folderId: folderId, isInitial: isInitial))
    }

    // MARK: Cursors

    private static func key(_ accountId: String, _ folderId: String?) -> String {
        folderId.map { "\(accountId)\u{1}\($0)" } ?? accountId
    }

    private func cursor(_ key: String) -> String? {
        let descriptor = FetchDescriptor<SyncCursor>(predicate: #Predicate { $0.key == key })
        return try? context.fetch(descriptor).first?.cursor
    }

    private func setCursor(_ key: String, _ value: String) {
        guard !value.isEmpty else { return }
        let descriptor = FetchDescriptor<SyncCursor>(predicate: #Predicate { $0.key == key })
        if let row = try? context.fetch(descriptor).first {
            row.cursor = value
            row.updatedAt = Date()
        } else {
            context.insert(SyncCursor(key: key, cursor: value))
        }
        try? context.save()
    }

    private func clearCursor(_ key: String) {
        let descriptor = FetchDescriptor<SyncCursor>(predicate: #Predicate { $0.key == key })
        for row in (try? context.fetch(descriptor)) ?? [] { context.delete(row) }
        try? context.save()
    }
}
