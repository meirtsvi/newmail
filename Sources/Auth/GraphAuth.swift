import Foundation
import MSAL
import AppKit

/// Microsoft identity (MSAL) wrapper. One instance backs all Microsoft accounts
/// (MSAL keeps a per-`homeAccountId` token cache in the keychain). Interactive
/// sign-in presents Microsoft's web UI; subsequent tokens are acquired silently.
///
/// `@MainActor` because the interactive flow presents UI and MSAL's
/// `MSALPublicClientApplication` is not `Sendable`.
@MainActor
final class GraphAuth {
    let clientId: String
    private let application: MSALPublicClientApplication
    private let scopes: [String]

    init(clientId: String,
         authority authorityURL: String = AppConfig.microsoftAuthority,
         redirectUri: String = AppConfig.microsoftRedirectURI,
         scopes: [String] = AppConfig.microsoftScopes) throws {
        guard let authURL = URL(string: authorityURL) else {
            throw MailError.auth("Invalid Microsoft authority URL: \(authorityURL)")
        }
        let authority = try MSALAADAuthority(url: authURL)
        let config = MSALPublicClientApplicationConfig(
            clientId: clientId,
            redirectUri: redirectUri,
            authority: authority
        )
        self.clientId = clientId
        self.scopes = scopes
        self.application = try MSALPublicClientApplication(configuration: config)
    }

    struct SignInResult {
        let email: String
        let homeAccountId: String
    }

    /// Presents Microsoft's interactive sign-in and returns the account identity.
    func signIn() async throws -> SignInResult {
        let webParameters = MSALWebviewParameters(authPresentationViewController: try presentationController())
        let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webParameters)
        params.promptType = .selectAccount

        let result = try await acquire { completion in
            self.application.acquireToken(with: params, completionBlock: completion)
        }
        let email = result.account.username ?? "Microsoft account"
        guard let homeId = result.account.identifier else {
            throw MailError.auth("Microsoft sign-in returned no account identifier")
        }
        return SignInResult(email: email, homeAccountId: homeId)
    }

    /// Returns a valid access token for the given account, refreshing silently
    /// and falling back to an interactive prompt only when MSAL says interaction
    /// is required.
    func accessToken(homeAccountId: String) async throws -> String {
        let account = try cachedAccount(homeAccountId)
        let silent = MSALSilentTokenParameters(scopes: scopes, account: account)
        do {
            let result = try await acquire { completion in
                self.application.acquireTokenSilent(with: silent, completionBlock: completion)
            }
            return result.accessToken
        } catch {
            let nsError = error as NSError
            let interactionRequired = nsError.domain == MSALErrorDomain
                && nsError.code == MSALError.interactionRequired.rawValue
            guard interactionRequired else { throw error }

            let webParameters = MSALWebviewParameters(authPresentationViewController: try presentationController())
            let params = MSALInteractiveTokenParameters(scopes: scopes, webviewParameters: webParameters)
            params.account = account
            let result = try await acquire { completion in
                self.application.acquireToken(with: params, completionBlock: completion)
            }
            return result.accessToken
        }
    }

    /// Removes the account's cached tokens (sign-out).
    func signOut(homeAccountId: String) {
        if let account = try? cachedAccount(homeAccountId) {
            try? application.remove(account)
        }
    }

    // MARK: - Helpers

    private func cachedAccount(_ homeAccountId: String) throws -> MSALAccount {
        do {
            return try application.account(forIdentifier: homeAccountId)
        } catch {
            throw MailError.auth("Microsoft account not found in cache — please add it again.")
        }
    }

    /// MSAL on macOS requires a view controller (attached to a window) to present
    /// the sign-in UI from.
    private func presentationController() throws -> NSViewController {
        let controller = NSApplication.shared.keyWindow?.contentViewController
            ?? NSApplication.shared.mainWindow?.contentViewController
            ?? NSApplication.shared.windows.first(where: { $0.isVisible })?.contentViewController
        guard let controller else {
            throw MailError.auth("No app window is available to present Microsoft sign-in.")
        }
        return controller
    }

    /// Bridges MSAL's completion-handler API to async/await.
    private func acquire(
        _ body: @escaping (@escaping (MSALResult?, Error?) -> Void) -> Void
    ) async throws -> MSALResult {
        try await withCheckedThrowingContinuation { continuation in
            body { result, error in
                if let result {
                    continuation.resume(returning: result)
                } else {
                    continuation.resume(throwing: error ?? MailError.auth("Microsoft authentication failed"))
                }
            }
        }
    }
}
