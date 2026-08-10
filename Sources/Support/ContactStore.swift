import Foundation
import SwiftData

/// SwiftData-backed address book for compose autocomplete. Populated from the
/// senders of messages you read and the recipients of mail you send; ranked by
/// how often each address has been seen (then recency).
@MainActor
final class ContactStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? Persistence.container.mainContext
    }

    /// Records one or more addresses, bumping the use count for ones already known.
    /// The known contacts are fetched once and merged in memory, so recording a
    /// whole mailbox's worth of addresses (see `MailStore.allCachedAddresses`) costs
    /// one fetch and one save rather than a round trip per address.
    func record(_ addresses: [MailAddress]) {
        guard !addresses.isEmpty else { return }
        var known: [String: CachedContact] = [:]
        for row in (try? context.fetch(FetchDescriptor<CachedContact>())) ?? [] {
            known[row.email] = row
        }
        let now = Date()
        var changed = false
        for addr in addresses {
            let email = addr.email.lowercased().trimmingCharacters(in: .whitespaces)
            guard email.contains("@") else { continue }
            if let row = known[email] {
                row.useCount += 1
                row.lastSeen = now
                if row.name.isEmpty, !addr.name.isEmpty { row.name = addr.name }
            } else {
                let row = CachedContact(email: email, name: addr.name, useCount: 1, lastSeen: now)
                context.insert(row)
                known[email] = row
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Suggestions whose email or name contains the query. The match runs in the
    /// fetch (the address book is seeded from the whole message cache, so it's far
    /// too big to filter in memory on every keystroke) and the most-used candidates
    /// are then re-ranked so what the query *starts* wins over a mid-word hit.
    func suggestions(matching query: String, limit: Int = 6) -> [MailAddress] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        // Emails are stored lowercased, so a plain `contains` is already
        // case-insensitive; names keep their original case and need the localized form.
        var descriptor = FetchDescriptor<CachedContact>(
            predicate: #Predicate { $0.email.contains(q) || $0.name.localizedStandardContains(q) },
            sortBy: [SortDescriptor(\.useCount, order: .reverse), SortDescriptor(\.lastSeen, order: .reverse)]
        )
        // A candidate pool big enough for the re-rank to have something to promote,
        // small enough to stay cheap per keystroke.
        descriptor.fetchLimit = 50
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows
            // A stable sort by rank alone, so use count and recency still order
            // everything within a rank.
            .enumerated()
            .sorted { ($0.element.rank(for: q), $0.offset) < ($1.element.rank(for: q), $1.offset) }
            .prefix(limit)
            .map { MailAddress(name: $0.element.name, email: $0.element.email) }
    }
}

private extension CachedContact {
    /// How well this contact matches `query` (lower is better): the address itself
    /// starting with it beats a name that starts with it, which beats a match buried
    /// somewhere inside either.
    func rank(for query: String) -> Int {
        if email.hasPrefix(query) { return 0 }
        let name = name.lowercased()
        if name.hasPrefix(query) { return 1 }
        // Any word of the name — so "shapiro" finds "Sasha Shapiro".
        if name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" })
            .contains(where: { $0.hasPrefix(query) }) { return 1 }
        return 2
    }
}
