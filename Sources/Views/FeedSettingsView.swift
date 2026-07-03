import SwiftUI
import AppKit

/// The Settings (⌘,) window: re-run Google sign-in (fixes 401s from an expired or
/// revoked token), manage the list of RSS/Atom feed URLs and, when more than one
/// Gmail account is configured, choose which one receives feed items.
struct FeedSettingsView: View {
    @Environment(MailboxViewModel.self) private var vm
    @AppStorage("feedAccountId") private var feedAccountId = ""
    @State private var newFeedURL = ""
    /// Flips after a clear so the row confirms it (the count itself is not
    /// observable state — it's fetched from the store on each render).
    @State private var ledgerCleared = false

    var body: some View {
        Form {
            Section("Google account") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.gmailSessions.first.map { $0.account.email.isEmpty ? $0.account.displayName : $0.account.email } ?? "Google")
                        if let message = vm.authMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await vm.signInForWriteAccess() }
                    } label: {
                        if vm.isSigningIn {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Signing in…")
                            }
                        } else {
                            Text("Sign in again…")
                        }
                    }
                    .disabled(vm.isSigningIn)
                    .help("Re-run the Google sign-in in your browser to fix authorization errors")
                }
            }

            if vm.gmailSessions.count > 1 {
                Section("Deliver to") {
                    Picker("Gmail account", selection: $feedAccountId) {
                        ForEach(vm.gmailSessions) { session in
                            Text(session.account.email.isEmpty ? session.account.displayName : session.account.email)
                                .tag(session.account.id)
                        }
                    }
                    .onChange(of: feedAccountId) { _, _ in vm.startFeeds() }
                }
            }

            Section("Feeds") {
                if vm.feedSubscriptions.isEmpty {
                    Text("No feeds yet. Add an RSS or Atom feed URL below.")
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.feedSubscriptions) { sub in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.title.isEmpty ? sub.url : sub.title)
                            Text(sub.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button(role: .destructive) { vm.removeFeed(sub) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove feed")
                    }
                }
            }

            Section {
                HStack {
                    TextField("Feed URL", text: $newFeedURL, prompt: Text("https://example.com/feed.xml"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(!isValidURL)
                }
            } footer: {
                Text("New items are added to your Gmail Inbox as unread messages, checked every 5 minutes.")
            }

            Section {
                HStack {
                    Text(ledgerCleared
                         ? "Digest history cleared."
                         : "\(vm.digestLedgerCount) digest\(vm.digestLedgerCount == 1 ? "" : "s") remembered")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear Digest History") {
                        vm.clearDigestLedger()
                        ledgerCleared = true
                    }
                    .disabled(ledgerCleared || vm.digestLedgerCount == 0)
                    .help("Forget which items past digests covered")
                }
            } header: {
                Text("Digest")
            } footer: {
                Text("The digest only covers newsletter items it hasn't covered before. Clearing the history makes the next digest include everything again (old digest messages lose their “Delete source mails” button).")
            }
        }
        .formStyle(.grouped)
        .frame(width: 760, height: 440)
        // Escape closes the Settings window (not the default for a Settings scene).
        .onExitCommand { NSApp.keyWindow?.close() }
        .onAppear {
            if feedAccountId.isEmpty { feedAccountId = vm.gmailSessions.first?.account.id ?? "" }
            vm.reloadFeedSubscriptions()
            ledgerCleared = false
        }
    }

    private var isValidURL: Bool {
        guard let url = URL(string: newFeedURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func add() {
        guard isValidURL else { return }
        vm.addFeed(newFeedURL)
        newFeedURL = ""
    }
}
