import Foundation

/// Loads the Google OAuth refresh token from the Keychain (imported during
/// initial setup — see `GoogleCredentialStore`) and exchanges it for fresh
/// access tokens. Refreshed tokens are written back to the Keychain; nothing
/// is kept on disk or in the app bundle.
actor GoogleAuth {
    static let shared = GoogleAuth()

    struct StoredToken: Codable {
        var token: String
        var refresh_token: String
        var token_uri: String
        var client_id: String
        var client_secret: String
        var scopes: [String]?
        var expiry: String?
    }

    private struct RefreshResponse: Codable {
        var access_token: String
        var expires_in: Double
        var scope: String?
        var token_type: String?
    }

    private var stored: StoredToken?
    private var expiryDate: Date = .distantPast
    /// Coalesces concurrent refreshes so many callers share one network call.
    private var refreshTask: Task<StoredToken, Error>?

    // MARK: Public

    func accessToken() async throws -> String {
        let tok = try loadIfNeeded()
        if Date() < expiryDate.addingTimeInterval(-60) {
            return tok.token
        }
        // Coalesce: if a refresh is already in flight, await it instead of
        // starting another (avoids a storm of concurrent token refreshes).
        if let refreshTask {
            return try await refreshTask.value.token
        }
        let task = Task { try await refresh(tok) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            return try await task.value.token
        } catch {
            throw error
        }
    }

    func scopes() throws -> [String] {
        try loadIfNeeded().scopes ?? []
    }

    /// Stores the result of an interactive OAuth sign-in, replacing whatever
    /// token was loaded before (e.g. upgrading a read-only token to read+write).
    func persistOAuthToken(
        accessToken: String,
        refreshToken: String?,
        expiresIn: Double,
        scopes: [String],
        tokenURI: String,
        clientId: String,
        clientSecret: String
    ) {
        // Keep the existing refresh token if Google didn't return a new one.
        let refresh = refreshToken ?? (try? loadIfNeeded().refresh_token) ?? ""
        let expiry = Date().addingTimeInterval(expiresIn)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let token = StoredToken(
            token: accessToken,
            refresh_token: refresh,
            token_uri: tokenURI,
            client_id: clientId,
            client_secret: clientSecret,
            scopes: scopes,
            expiry: formatter.string(from: expiry)
        )
        stored = token
        expiryDate = expiry
        refreshTask = nil
        if let data = try? JSONEncoder().encode(token) {
            GoogleCredentialStore.saveToken(data)
        }
    }

    /// Drops the in-memory token so the next call re-reads the Keychain —
    /// called after new credentials are imported in setup.
    func invalidateCache() {
        stored = nil
        expiryDate = .distantPast
        refreshTask = nil
    }

    var hasWriteScope: Bool {
        get throws {
            let s = try loadIfNeeded().scopes ?? []
            return s.contains { $0.contains("gmail.modify") || $0.contains("mail.google.com") }
        }
    }

    var hasCalendarScope: Bool {
        get throws {
            let s = try loadIfNeeded().scopes ?? []
            return s.contains { $0.contains("calendar") }
        }
    }

    /// Whether events can be written (RSVP via the Calendar API), i.e. the token
    /// carries `calendar.events` or the full `calendar` scope — not just the
    /// `calendar.readonly` grant older sign-ins have.
    var hasCalendarWriteScope: Bool {
        get throws {
            let s = try loadIfNeeded().scopes ?? []
            return s.contains { $0.hasSuffix("auth/calendar.events") || $0.hasSuffix("auth/calendar") }
        }
    }

    // MARK: Loading

    @discardableResult
    private func loadIfNeeded() throws -> StoredToken {
        if let stored { return stored }
        guard let data = GoogleCredentialStore.loadToken() else {
            throw MailError.auth("Google access isn't set up — import your credentials JSON and sign in.")
        }
        let tok = try JSONDecoder().decode(StoredToken.self, from: data)
        stored = tok
        expiryDate = Self.parseExpiry(tok.expiry)
        return tok
    }

    // MARK: Refresh

    @discardableResult
    private func refresh(_ tok: StoredToken) async throws -> StoredToken {
        guard let url = URL(string: tok.token_uri) else {
            throw MailError.auth("invalid token_uri")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "client_id": tok.client_id,
            "client_secret": tok.client_secret,
            "refresh_token": tok.refresh_token,
            "grant_type": "refresh_token",
        ]
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .formValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw MailError.auth("no response during token refresh")
        }
        guard http.statusCode == 200 else {
            throw MailError.auth("token refresh failed (\(http.statusCode)): \(String(data: data, encoding: .utf8) ?? "")")
        }
        let r = try JSONDecoder().decode(RefreshResponse.self, from: data)

        var updated = tok
        updated.token = r.access_token
        let newExpiry = Date().addingTimeInterval(r.expires_in)
        expiryDate = newExpiry

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        updated.expiry = f.string(from: newExpiry)
        stored = updated

        if let out = try? JSONEncoder().encode(updated) {
            GoogleCredentialStore.saveToken(out)
        }
        return updated
    }

    private static func parseExpiry(_ s: String?) -> Date {
        guard let s else { return .distantPast }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s) ?? .distantPast
    }
}
