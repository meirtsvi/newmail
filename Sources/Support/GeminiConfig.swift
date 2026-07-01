import Foundation

/// Gemini (Google Generative Language) configuration for the Hebrew
/// translate/summarize features.
///
/// The API key is read from a gitignored `gemini.json` bundled as a resource —
/// the same pattern the app uses for `token.json` (see `OAuthService.loadClient`).
/// Create `Resources/gemini.json` with:  `{ "apiKey": "…" }`
enum GeminiConfig {

    /// Model used for both translation and summarization. Single place to change
    /// if the model name is updated. (Matches the Python reference.)
    static let model = "gemini-3.1-flash-lite-preview"

    /// The Gemini API key loaded from the bundled `gemini.json`, or nil when the
    /// file is missing (feature stays disabled rather than crashing).
    static var apiKey: String? {
        guard let url = Bundle.main.url(forResource: "gemini", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        let key = stored.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    /// True once a real key has been provided.
    static var isConfigured: Bool { apiKey != nil }

    private struct Stored: Decodable { let apiKey: String }
}
