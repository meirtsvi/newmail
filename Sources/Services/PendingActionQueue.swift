import Foundation
import SwiftData

/// Mail actions waiting to reach the server. An action taken while offline (or
/// whose request failed for lack of a connection) is saved here and replayed,
/// oldest first, once the connection is back — across relaunches too. The UI
/// and the cache already show the result; the queue only owes the server.
@MainActor
final class PendingActionQueue {
    enum Kind: String {
        case markRead, flag, trash, untrash, archive, move, notSpam, saveDraft
    }

    private let context: ModelContext

    /// Local drafts that reached the server this session: local key → the
    /// server draft. A compose window still holding the local key continues
    /// that draft instead of creating a second one.
    private(set) var syncedDrafts: [String: SavedDraft] = [:]

    init(context: ModelContext? = nil) {
        self.context = context ?? Persistence.container.mainContext
    }

    var count: Int { (try? context.fetchCount(FetchDescriptor<PendingAction>())) ?? 0 }

    func all() -> [PendingAction] {
        (try? context.fetch(FetchDescriptor<PendingAction>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func hasPending(accountId: String) -> Bool {
        let descriptor = FetchDescriptor<PendingAction>(predicate: #Predicate { $0.accountId == accountId })
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Message ids with a change still owed to the server. Sync leaves these
    /// alone so a stale server copy doesn't overwrite the newer local state.
    func pendingMessageIds(accountId: String) -> Set<String> {
        let descriptor = FetchDescriptor<PendingAction>(predicate: #Predicate { $0.accountId == accountId })
        let rows = (try? context.fetch(descriptor)) ?? []
        return Set(rows.flatMap { Self.ids($0) })
    }

    func add(_ action: PendingAction) {
        context.insert(action)
        try? context.save()
    }

    func remove(_ action: PendingAction) {
        context.delete(action)
        try? context.save()
    }

    /// Drops a queued trash of exactly these messages (⌘Z before it was sent).
    /// Returns false when there was none, i.e. the trash already happened.
    func cancelTrash(ids: [String], accountId: String) -> Bool {
        let joined = ids.joined(separator: "\u{1}")
        let trash = Kind.trash.rawValue
        let descriptor = FetchDescriptor<PendingAction>(predicate: #Predicate {
            $0.accountId == accountId && $0.kindRaw == trash && $0.idsRaw == joined
        })
        guard let row = try? context.fetch(descriptor).first else { return false }
        remove(row)
        return true
    }

    /// The queued local draft with this key, if it hasn't been sent yet.
    func localDraft(key: String) -> PendingAction? {
        let descriptor = FetchDescriptor<PendingAction>(predicate: #Predicate { $0.localKey == key })
        return try? context.fetch(descriptor).first
    }

    func noteSyncedDraft(key: String, saved: SavedDraft) {
        syncedDrafts[key] = saved
    }

    static func ids(_ action: PendingAction) -> [String] {
        action.idsRaw.isEmpty ? [] : action.idsRaw.split(separator: "\u{1}").map(String.init)
    }

    static func make(_ kind: Kind, accountId: String, ids: [String] = [], folderId: String = "",
                     fromFolderId: String = "", flag: Bool = false) -> PendingAction {
        PendingAction(accountId: accountId, kindRaw: kind.rawValue,
                      idsRaw: ids.joined(separator: "\u{1}"), folderId: folderId,
                      fromFolderId: fromFolderId, flag: flag)
    }

    /// Performs one action against the server.
    static func run(_ action: PendingAction, on provider: MailProvider) async throws {
        let ids = ids(action)
        switch Kind(rawValue: action.kindRaw) {
        case .markRead: try await provider.setRead(ids: ids, read: action.flag)
        case .flag: try await provider.setFlagged(ids: ids, flagged: action.flag)
        case .trash: try await provider.trash(ids: ids)
        case .untrash: try await provider.untrash(ids: ids, toFolderId: action.folderId)
        case .archive: try await provider.archive(ids: ids)
        case .move:
            try await provider.move(ids: ids, toFolderId: action.folderId,
                                    fromFolderId: action.fromFolderId.isEmpty ? nil : action.fromFolderId)
        case .notSpam: try await provider.markNotSpam(ids: ids)
        case .saveDraft:
            // Handled by `flush`, which needs the saved draft back.
            break
        case nil: break
        }
    }

    /// Replays every queued action in order. Stops at the first connectivity
    /// failure (the rest wait for the next attempt). An action the server
    /// refuses is dropped and handed to `onRefused`, so the caller can re-read
    /// the affected messages and say what didn't go through.
    /// Returns the number of actions that reached the server.
    @discardableResult
    func flush(provider: (String) -> MailProvider?,
               onRefused: (PendingAction, Error) -> Void,
               onDraftSynced: (_ localKey: String, _ accountId: String) -> Void) async -> Int {
        var done = 0
        for action in all() {
            guard let provider = provider(action.accountId) else {
                // The account was removed; its pending work goes with it.
                remove(action)
                continue
            }
            do {
                if Kind(rawValue: action.kindRaw) == .saveDraft {
                    let saved = try await provider.saveDraft(
                        id: action.replacesDraftId.isEmpty ? nil : action.replacesDraftId,
                        rawMIME: action.raw ?? Data())
                    noteSyncedDraft(key: action.localKey, saved: saved)
                    onDraftSynced(action.localKey, action.accountId)
                } else {
                    try await Self.run(action, on: provider)
                }
                remove(action)
                done += 1
            } catch {
                // Only a definite "no" from the server drops the action; lost
                // connections, expired sign-ins and server hiccups keep it (and
                // everything after it, to preserve order) for the next attempt.
                guard Self.isRefusal(error) else { break }
                remove(action)
                onRefused(action, error)
            }
        }
        return done
    }

    /// Whether the server rejected the request itself (a 4xx other than auth,
    /// timeout and throttling), so retrying it can never succeed.
    static func isRefusal(_ error: Error) -> Bool {
        guard case MailError.api(let code, _) = error else { return false }
        return (400..<500).contains(code) && ![401, 408, 429].contains(code)
    }
}
