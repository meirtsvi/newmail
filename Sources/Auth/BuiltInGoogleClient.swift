import Foundation

/// The shared "Desktop app" OAuth client that ships with newmail, so users can
/// sign in with Google without creating their own Cloud project. For installed
/// apps Google treats the client secret as non-confidential — the loopback+PKCE
/// flow does not rely on it being secret. A client imported via the setup
/// sheet's advanced path takes precedence (see `GoogleCredentialStore`).
enum BuiltInGoogleClient {
    static let clientId = "256833879388-9pmd9dlqdhti6itpuh6ls5n84vrrfnna.apps.googleusercontent.com"
    static let clientSecret = "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"
}
