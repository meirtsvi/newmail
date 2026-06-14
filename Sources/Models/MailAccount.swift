import Foundation

/// Which backend a `MailAccount` talks to.
enum ProviderKind: String, Codable, Hashable {
    case gmail
    case graph

    var providerName: String {
        switch self {
        case .gmail: return "Google"
        case .graph: return "Microsoft"
        }
    }
}

/// A configured mail account. Stable across launches; persisted via `AccountStore`.
struct MailAccount: Identifiable, Hashable, Codable {
    /// Stable app-side identifier (e.g. "gmail" or "graph:<homeAccountId>").
    let id: String
    var providerKind: ProviderKind
    var email: String
    var displayName: String
    /// Provider-specific external id. For Graph this is the MSAL `homeAccountId`
    /// used for silent token acquisition; unused for Gmail.
    var externalId: String

    init(id: String,
         providerKind: ProviderKind,
         email: String,
         displayName: String = "",
         externalId: String = "") {
        self.id = id
        self.providerKind = providerKind
        self.email = email
        self.displayName = displayName.isEmpty ? email : displayName
        self.externalId = externalId
    }
}
