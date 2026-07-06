import Foundation
import CryptoKit

/// The shared "Desktop app" OAuth client that ships with newmail, so users can
/// sign in with Google without creating their own Cloud project. For installed
/// apps Google treats the client secret as non-confidential — the loopback+PKCE
/// flow does not rely on it being secret. A client imported via the setup
/// sheet's advanced path takes precedence (see `GoogleCredentialStore`).
enum BuiltInGoogleClient {
    static let clientId = "784052556209-bb7t9oj7ubmau3a5n7fkcu5k7e3s6ede.apps.googleusercontent.com"
    static let clientSecret = "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"

    // The legacy org-internal client, selected by the setup sheet's password
    // box. Only accounts inside that project's Workspace org can use it.
    private static let legacyClientId = "256833879388-9pmd9dlqdhti6itpuh6ls5n84vrrfnna.apps.googleusercontent.com"
    private static let legacyClientSecret = "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"
    private static let legacyPasswordSHA256 = "7b178b1938250afe946f5cdfab2d4fd92b3f1154c4307c337170aacf7bd5d38e"

    /// The legacy client when `password` hashes to the expected value,
    /// nil (meaning: use the default client) otherwise.
    static func legacyClient(forSetupPassword password: String) -> GoogleCredentialStore.Client? {
        guard !password.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(password.utf8))
            .map { String(format: "%02x", $0) }.joined()
        guard digest == legacyPasswordSHA256 else { return nil }
        return GoogleCredentialStore.Client(clientId: legacyClientId,
                                            clientSecret: legacyClientSecret,
                                            tokenURI: "https://oauth2.googleapis.com/token")
    }
}
