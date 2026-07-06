import SwiftUI
import AppKit

/// Initial-setup sheet: connects the user's Gmail account with the built-in
/// OAuth client — one click, browser consent, done. An advanced escape hatch
/// still accepts a self-supplied credentials.json / token.json.
/// Shown on every launch until the app holds a Google token.
struct GoogleSetupView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Connect Gmail", systemImage: "envelope.badge.person.crop")
                .font(.title2.bold())
            Text("""
            Sign in with your Google account in the browser and grant newmail \
            access to Gmail and Calendar. Your sign-in stays in your Keychain — \
            you won't be asked again on this Mac.
            """)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if let error = vm.googleSetupError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Continue without Gmail") { vm.needsGoogleSetup = false }
                Button("Use your own OAuth client…") { chooseFile() }
                    .buttonStyle(.link)
                    .disabled(isImporting || vm.isSigningIn)
                Spacer()
                if isImporting || vm.isSigningIn {
                    ProgressView().controlSize(.small)
                }
                Button("Sign in with Google") {
                    Task { await vm.signInForWriteAccess() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isImporting || vm.isSigningIn)
            }
        }
        .padding(24)
        .frame(width: 480)
        // Setup is required — no swipe/escape dismissal; only the buttons.
        .interactiveDismissDisabled()
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose your Google OAuth credentials JSON"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isImporting = true
        Task {
            await vm.importGoogleCredentials(from: url)
            isImporting = false
        }
    }
}
