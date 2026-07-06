import Foundation
import Security

/// Keychain-backed storage for the Google OAuth client credentials and token.
/// The credentials JSON is imported by the user during initial setup — either a
/// `credentials.json` downloaded from Google Cloud Console (a "Desktop app"
/// OAuth client) or a full `token.json` from the Python flow. Nothing ships in
/// the app bundle anymore; every install imports its own file once and the
/// Keychain answers from then on.
enum GoogleCredentialStore {

    struct Client {
        var clientId: String
        var clientSecret: String
        var tokenURI: String
    }

    private static let service = "newmail.google-oauth"
    private static let clientAccount = "client"
    private static let tokenAccount = "token"
    private static let defaultTokenURI = "https://oauth2.googleapis.com/token"

    /// Google Cloud Console download: `{"installed": {client_id, client_secret, …}}`.
    private struct InstalledWrapper: Decodable { let installed: StoredClient }
    /// What's kept under the `client` Keychain item.
    private struct StoredClient: Codable {
        var client_id: String
        var client_secret: String
        var token_uri: String?
    }

    /// True once setup has run (credentials were imported on this Mac).
    static var hasClient: Bool { loadClient() != nil }

    static func loadClient() -> Client? {
        guard let data = read(clientAccount),
              let client = try? JSONDecoder().decode(StoredClient.self, from: data),
              !client.client_id.isEmpty, !client.client_secret.isEmpty else { return nil }
        return Client(clientId: client.client_id,
                      clientSecret: client.client_secret,
                      tokenURI: client.token_uri ?? defaultTokenURI)
    }

    /// Imports a credentials JSON picked by the user. Accepts a Google Cloud
    /// `credentials.json` (client id/secret only) or a `token.json` (client
    /// plus refresh token). Returns true when the file carried a refresh token,
    /// i.e. no interactive sign-in is needed afterwards.
    @discardableResult
    static func importCredentials(_ data: Data) throws -> Bool {
        let decoder = JSONDecoder()
        let client: StoredClient
        var token: GoogleAuth.StoredToken?

        if let wrapped = try? decoder.decode(InstalledWrapper.self, from: data) {
            client = wrapped.installed
        } else if let tok = try? decoder.decode(GoogleAuth.StoredToken.self, from: data) {
            client = StoredClient(client_id: tok.client_id,
                                  client_secret: tok.client_secret,
                                  token_uri: tok.token_uri)
            if !tok.refresh_token.isEmpty { token = tok }
        } else {
            throw MailError.auth("This file doesn't look like Google OAuth credentials — expected a credentials.json from Google Cloud Console or a token.json.")
        }
        guard !client.client_id.isEmpty, !client.client_secret.isEmpty else {
            throw MailError.auth("The credentials file is missing client_id or client_secret.")
        }

        write(clientAccount, try JSONEncoder().encode(client))
        if let token, let encoded = try? JSONEncoder().encode(token) {
            write(tokenAccount, encoded)
        } else {
            // A new client invalidates any token minted by the previous one.
            delete(tokenAccount)
        }
        return token != nil
    }

    // MARK: - Token (managed by GoogleAuth)

    static func loadToken() -> Data? { read(tokenAccount) }
    static func saveToken(_ data: Data) { write(tokenAccount, data) }

    // MARK: - Keychain primitives

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func read(_ account: String) -> Data? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    private static func write(_ account: String, _ data: Data) {
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery(account)
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
