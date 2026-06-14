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
    func record(_ addresses: [MailAddress]) {
        var changed = false
        for addr in addresses {
            let email = addr.email.lowercased().trimmingCharacters(in: .whitespaces)
            guard email.contains("@") else { continue }
            let descriptor = FetchDescriptor<CachedContact>(predicate: #Predicate { $0.email == email })
            if let row = try? context.fetch(descriptor).first {
                row.useCount += 1
                row.lastSeen = Date()
                if row.name.isEmpty, !addr.name.isEmpty { row.name = addr.name }
            } else {
                context.insert(CachedContact(email: email, name: addr.name, useCount: 1, lastSeen: Date()))
            }
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Suggestions whose email or name contains the query, ranked by use count
    /// then recency. The contact set is small, so we filter in memory to allow a
    /// case-insensitive match on both fields.
    func suggestions(matching query: String, limit: Int = 6) -> [MailAddress] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let descriptor = FetchDescriptor<CachedContact>(
            sortBy: [SortDescriptor(\.useCount, order: .reverse), SortDescriptor(\.lastSeen, order: .reverse)]
        )
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows
            .filter { $0.email.contains(q) || $0.name.lowercased().contains(q) }
            .prefix(limit)
            .map { MailAddress(name: $0.name, email: $0.email) }
    }
}
