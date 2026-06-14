import Foundation

/// App-level configuration constants.
enum AppConfig {

    /// Azure AD **application (client) ID** for Microsoft Graph sign-in.
    ///
    /// ─────────────────────────────────────────────────────────────────────────
    ///  👉 PASTE YOUR AZURE CLIENT ID ON THE LINE BELOW (replace the placeholder).
    /// ─────────────────────────────────────────────────────────────────────────
    ///
    /// Find it in the Microsoft Entra admin center:
    ///   entra.microsoft.com → App registrations → <your app> → Overview →
    ///   "Application (client) ID"  (a GUID like 1a2b3c4d-5e6f-7890-abcd-ef1234567890)
    ///
    /// The Azure app registration must be configured with:
    ///   • Platform: "Mobile and desktop applications"
    ///   • Redirect URI:  msauth.com.meirt.newmail://auth
    ///   • Supported account types: include **personal Microsoft accounts**
    ///     (required for live.com / outlook.com)
    ///   • Delegated API permissions: Mail.ReadWrite, Mail.Send, User.Read, offline_access
    static let microsoftClientID = "570d0ffa-f3c5-4bb9-b1f7-c1e081f5d970"

    /// MSAL authority. "common" accepts both personal (live.com / outlook.com)
    /// and work/school Microsoft accounts. Use "consumers" to restrict to personal.
    static let microsoftAuthority = "https://login.microsoftonline.com/common"

    /// Redirect URI registered in the Azure app. Must match exactly.
    static var microsoftRedirectURI: String {
        "msauth.\(Bundle.main.bundleIdentifier ?? "com.meirt.newmail")://auth"
    }

    /// Delegated Graph scopes requested at sign-in. `offline_access`, `openid`
    /// and `profile` are added automatically by MSAL.
    static let microsoftScopes = ["Mail.ReadWrite", "Mail.Send", "User.Read"]

    /// True once a real client ID has been filled in.
    static var isMicrosoftConfigured: Bool {
        !microsoftClientID.isEmpty && !microsoftClientID.hasPrefix("PASTE-")
    }
}
