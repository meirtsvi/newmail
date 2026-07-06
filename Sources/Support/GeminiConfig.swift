import Foundation
import Security

/// Gemini (Google Generative Language) configuration for the Hebrew
/// translate/summarize features.
///
/// The API key lives in the Keychain and is managed from Settings → AI.
/// The legacy `geminiApiKey` UserDefaults entry is read once to migrate keys
/// from previous builds. (The bundled `Resources/gemini.json` migration source
/// was removed along with the file — the bundle carries no secrets.)
enum GeminiConfig {

    /// Model used for both translation and summarization. Single place to change
    /// if the model name is updated. (Matches the Python reference.)
    static let model = "gemini-3.1-flash-lite-preview"

    private static let keychainService = "newmail.gemini-api-key"
    private static let legacyDefaultsKey = "geminiApiKey"

    /// Cached Keychain read: apiKey is consulted on every feed poll and
    /// translate call, and the value only changes through setAPIKey below.
    /// Double optional — nil means "not loaded yet", .some(nil) "no key".
    private static var cached: String??

    /// The Gemini API key, or nil when none has been set (feature stays
    /// disabled rather than crashing).
    static var apiKey: String? {
        if let cached { return cached }
        let key = load()
        cached = .some(key)
        return key
    }

    /// Replace the stored key (Settings → AI). Pass an empty string to clear.
    static func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        keychainWrite(trimmed)
        cached = .some(trimmed.isEmpty ? nil : trimmed)
    }

    /// True once a real key has been provided.
    static var isConfigured: Bool { apiKey != nil }

    private static func load() -> String? {
        if let stored = keychainRead() {
            let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        }
        // One-time migration from older storage. An empty item is written even
        // when there's nothing to migrate so the Keychain always answers from
        // here on (clearing the key in Settings sticks).
        let migrated = legacyDefaultsValue ?? ""
        keychainWrite(migrated)
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        return migrated.isEmpty ? nil : migrated
    }

    // MARK: - Keychain

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: "gemini"]
    }

    private static func keychainRead() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(_ key: String) {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = Data(key.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Legacy storage (migration source)

    private static var legacyDefaultsValue: String? {
        guard let stored = UserDefaults.standard.string(forKey: legacyDefaultsKey) else { return nil }
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
