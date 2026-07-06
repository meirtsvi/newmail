import Foundation

/// Gemini (Google Generative Language) configuration for the Hebrew
/// translate/summarize features.
///
/// The API key lives in UserDefaults and is managed from Settings → AI.
/// A legacy gitignored `Resources/gemini.json` (`{ "apiKey": "…" }`) is read
/// once to migrate keys from older builds.
enum GeminiConfig {

    /// Model used for both translation and summarization. Single place to change
    /// if the model name is updated. (Matches the Python reference.)
    static let model = "gemini-3.1-flash-lite-preview"

    private static let defaultsKey = "geminiApiKey"

    /// The Gemini API key, or nil when none has been set (feature stays
    /// disabled rather than crashing).
    static var apiKey: String? {
        if let stored = UserDefaults.standard.string(forKey: defaultsKey) {
            let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        // One-time migration from the legacy bundled gemini.json. After this,
        // UserDefaults always answers (even an empty string blocks re-migration,
        // so clearing the key in Settings sticks).
        let migrated = legacyFileKey ?? ""
        UserDefaults.standard.set(migrated, forKey: defaultsKey)
        return migrated.isEmpty ? nil : migrated
    }

    /// Replace the stored key (Settings → AI). Pass an empty string to clear.
    static func setAPIKey(_ key: String) {
        UserDefaults.standard.set(key.trimmingCharacters(in: .whitespacesAndNewlines),
                                  forKey: defaultsKey)
    }

    /// True once a real key has been provided.
    static var isConfigured: Bool { apiKey != nil }

    private static var legacyFileKey: String? {
        guard let url = Bundle.main.url(forResource: "gemini", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return nil
        }
        let key = stored.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    private struct Stored: Decodable { let apiKey: String }
}
