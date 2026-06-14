import Foundation
import SwiftData

/// Persists the set of configured accounts so they survive relaunches.
@MainActor
final class AccountStore {
    private let context: ModelContext

    init(context: ModelContext? = nil) {
        self.context = context ?? Persistence.container.mainContext
    }

    func load() -> [MailAccount] {
        let rows = (try? context.fetch(
            FetchDescriptor<PersistedAccount>(sortBy: [SortDescriptor(\.sortIndex)])
        )) ?? []
        return rows.map {
            MailAccount(
                id: $0.id,
                providerKind: ProviderKind(rawValue: $0.providerKindRaw) ?? .gmail,
                email: $0.email,
                displayName: $0.displayName,
                externalId: $0.externalId
            )
        }
    }

    func upsert(_ account: MailAccount) {
        let id = account.id
        if let row = try? context.fetch(
            FetchDescriptor<PersistedAccount>(predicate: #Predicate { $0.id == id })
        ).first {
            row.providerKindRaw = account.providerKind.rawValue
            row.email = account.email
            row.displayName = account.displayName
            row.externalId = account.externalId
        } else {
            let count = (try? context.fetchCount(FetchDescriptor<PersistedAccount>())) ?? 0
            context.insert(PersistedAccount(
                id: account.id,
                providerKindRaw: account.providerKind.rawValue,
                email: account.email,
                displayName: account.displayName,
                externalId: account.externalId,
                sortIndex: count
            ))
        }
        try? context.save()
    }

    func remove(id: String) {
        let rows = (try? context.fetch(
            FetchDescriptor<PersistedAccount>(predicate: #Predicate { $0.id == id })
        )) ?? []
        for row in rows { context.delete(row) }
        try? context.save()
    }
}
