import SwiftUI
import AppKit

/// Initial-setup sheet: asks for the Google OAuth credentials JSON, which is
/// then kept in the Keychain (the app bundle no longer carries credentials).
/// Shown on every launch until a file has been imported on this Mac.
struct GoogleSetupView: View {
    @Environment(MailboxViewModel.self) private var vm
    @State private var isImporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Set up Google access", systemImage: "key.horizontal")
                .font(.title2.bold())
            Text("""
            To connect Gmail, newmail needs the OAuth credentials of a Google Cloud \
            project. Choose either the credentials.json downloaded from Google Cloud \
            Console (APIs & Services → Credentials → a "Desktop app" OAuth client) or \
            an existing token.json. The file is stored in your Keychain — you won't \
            be asked again on this Mac.
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
                Spacer()
                if isImporting {
                    ProgressView().controlSize(.small)
                }
                Button("Choose credentials JSON…") { chooseFile() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isImporting)
            }
        }
        .padding(24)
        .frame(width: 480)
        // Setup is required — no swipe/escape dismissal; only the two buttons.
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
