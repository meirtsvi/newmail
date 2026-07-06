import Foundation

/// Rewrites a natural-language search request ("attachments from Dana last
/// month about the release" — Hebrew works too) into the current provider's
/// search-operator syntax using Gemini: Gmail `q` operators or Microsoft Graph
/// `$search` (KQL). The result is shown in the toolbar as an editable proposal
/// and only runs through the existing search path once the user confirms.
@MainActor
enum NaturalSearchService {

    /// The operator dialect to emit, per account provider.
    enum Dialect {
        case gmail
        case graph

        init(_ kind: ProviderKind) {
            self = (kind == .graph) ? .graph : .gmail
        }
    }

    /// Asks Gemini to rewrite `text` into a single operator query string.
    static func rewrite(_ text: String, dialect: Dialect) async throws -> String {
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": ["query": ["type": "STRING"]],
            "required": ["query"],
        ]
        let out = try await TranslationService.shared.geminiGenerate(
            system: system(for: dialect), userText: text, responseSchema: schema)
        guard let data = out.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranslationError.emptyResponse
        }
        let query = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw TranslationError.emptyResponse }
        return query
    }

    private struct Response: Decodable { let query: String }

    /// Today's date, spelled out so the model can resolve "last month" /
    /// "yesterday" into absolute bounds.
    private static var today: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE, yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// Rules shared by both dialects.
    private static let commonRules = """
    Rules:
    - The request may be in English or Hebrew (or mixed); interpret either.
    - Keep free-text keywords (words to match in the subject or body) in their \
    original language; quote multi-word phrases.
    - People may be given by first name only — use it as-is in the sender/recipient \
    operator (providers match display names).
    - Resolve relative dates ("last month", "yesterday") into absolute date bounds \
    using today's date.
    - Only add operators the request actually implies — never invent filters.
    - Put only the query string in the "query" field, nothing else.
    """

    private static func system(for dialect: Dialect) -> String {
        switch dialect {
        case .gmail:
            return """
            You convert a user's natural-language email search request into a Gmail \
            search query using Gmail search operators. Today is \(today).
            Available operators: from:, to:, cc:, bcc:, subject:, label:, \
            has:attachment, filename:, is:unread, is:read, is:starred, \
            after:YYYY/MM/DD, before:YYYY/MM/DD, older_than:Nd/Nm/Ny, \
            newer_than:Nd/Nm/Ny, OR, - (negation), ( ) grouping, and "quoted phrases".
            \(commonRules)
            """
        case .graph:
            return """
            You convert a user's natural-language email search request into a \
            Microsoft Graph $search query (KQL) for messages. Today is \(today).
            Searchable properties: from:, to:, cc:, bcc:, participants:, subject:, \
            body:, attachment: (file name), hasAttachments:true, received:, sent:, \
            importance:. Date ranges use comparisons, e.g. \
            received>=2026-06-01 AND received<=2026-06-30.
            Combine terms with AND, OR, NOT; use "quoted phrases" for exact phrases.
            \(commonRules)
            """
        }
    }
}
