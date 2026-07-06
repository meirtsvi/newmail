import Foundation
import Network
import CryptoKit
import AppKit

/// Interactive Google OAuth 2.0 with PKCE over a loopback redirect — the desktop
/// "installed app" flow. Uses the built-in shared client by default, or the
/// client_id/secret imported via the setup sheet's advanced path (kept in the
/// Keychain, see `GoogleCredentialStore`).
actor OAuthService {
    static let shared = OAuthService()

    /// Read + modify (move/label/read-state/trash), send, and calendar events
    /// read/write (to show your schedule alongside meeting invitations and to
    /// record RSVPs on the event so Google itself notifies the organizer).
    let scopes = [
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/calendar.events",
    ]
    private let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private let tokenEndpoint = "https://oauth2.googleapis.com/token"

    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?

    // MARK: - Flow

    func signIn() async throws {
        let client = GoogleCredentialStore.loadClient()
        let (clientId, clientSecret) = (client.clientId, client.clientSecret)
        let verifier = Self.randomString(64)
        let challenge = Self.codeChallenge(verifier)

        let port = try await startListener()
        defer { stopListener() }
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "include_granted_scopes", value: "true"),
            .init(name: "prompt", value: "consent"),
        ]
        guard let url = comps.url else { throw MailError.auth("could not build authorization URL") }
        await MainActor.run { NSWorkspace.shared.open(url) }

        let code = try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            self.codeContinuation = c
            // Fail gracefully if the user never completes consent.
            Task {
                try? await Task.sleep(nanoseconds: 180_000_000_000)
                await self.timeoutIfPending()
            }
        }
        try await exchange(code: code, verifier: verifier, redirect: redirect,
                           clientId: clientId, clientSecret: clientSecret)
    }

    private func timeoutIfPending() {
        guard codeContinuation != nil else { return }
        finish(.failure(MailError.auth("Sign-in timed out — no response from the browser.")))
    }

    // MARK: - Loopback listener

    private func startListener() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            self?.handle(conn)
        }
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed, let p = listener.port?.rawValue {
                        resumed = true
                        cont.resume(returning: p)
                    }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: .global())
        }
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    /// Parses the redirect request, replies with a closeable page, and resumes
    /// the flow with the authorization code (or an error).
    nonisolated private func handle(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
            guard let data, let request = String(data: data, encoding: .utf8) else {
                conn.cancel(); return
            }
            guard let result = Self.parseRedirect(request) else {
                // Ignore unrelated requests (e.g. favicon); keep waiting.
                conn.cancel(); return
            }
            let body = """
            <html><body style="font-family:-apple-system;text-align:center;padding-top:80px">
            <h2>Authorization complete</h2><p>You can close this window and return to newmail.</p>
            </body></html>
            """
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })
            Task { await self.finish(result) }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let cont = codeContinuation else { return }
        codeContinuation = nil
        switch result {
        case .success(let code): cont.resume(returning: code)
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    nonisolated private static func parseRedirect(_ request: String) -> Result<String, Error>? {
        guard let firstLine = request.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = String(parts[1])
        guard let comps = URLComponents(string: "http://127.0.0.1\(path)") else { return nil }
        let items = comps.queryItems ?? []
        if let code = items.first(where: { $0.name == "code" })?.value {
            return .success(code)
        }
        if let error = items.first(where: { $0.name == "error" })?.value {
            let desc = items.first(where: { $0.name == "error_description" })?.value ?? ""
            return .failure(MailError.auth("Authorization denied: \(error). \(desc)"))
        }
        return nil
    }

    // MARK: - Token exchange

    private func exchange(code: String, verifier: String, redirect: String,
                          clientId: String, clientSecret: String) async throws {
        var req = URLRequest(url: URL(string: tokenEndpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = [
            "code": code,
            "client_id": clientId,
            "client_secret": clientSecret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        req.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .formValueAllowed) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw MailError.auth("Token exchange failed: \(String(data: data, encoding: .utf8) ?? "")")
        }
        struct TokenResponse: Codable {
            var access_token: String
            var refresh_token: String?
            var expires_in: Double
            var scope: String?
        }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        let grantedScopes = token.scope?.split(separator: " ").map(String.init) ?? scopes
        await GoogleAuth.shared.persistOAuthToken(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,
            expiresIn: token.expires_in,
            scopes: grantedScopes,
            tokenURI: tokenEndpoint,
            clientId: clientId,
            clientSecret: clientSecret
        )
    }

    // MARK: - Helpers

    private static func randomString(_ count: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return String(bytes.map { chars[Int($0) % chars.count] })
    }

    private static func codeChallenge(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
