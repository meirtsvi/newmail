import SwiftUI
import AppKit

/// The Settings (⌘,) window, split into tabs by area:
///   Account — re-run Google sign-in (fixes 401s from an expired or revoked token)
///   Feeds   — manage RSS/Atom feed URLs and, with more than one Gmail account,
///             choose which one receives feed items
///   Digest  — clear the digest coverage history
///   AI      — the Gemini API key used for translation and digest summaries
///   Notifications — popup and sound toggles for new mail and calendar reminders
struct FeedSettingsView: View {
    var body: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
            NotificationSettingsTab()
                .tabItem { Label("Notifications", systemImage: "bell.badge") }
            FeedsSettingsTab()
                .tabItem { Label("Feeds", systemImage: "dot.radiowaves.up.forward") }
            DigestSettingsTab()
                .tabItem { Label("Digest", systemImage: "newspaper") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 760, height: 440)
        // Escape closes the Settings window (not the default for a Settings scene).
        .onExitCommand { NSApp.keyWindow?.close() }
    }
}

private struct AccountSettingsTab: View {
    @Environment(MailboxViewModel.self) private var vm

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
        }
        .formStyle(.grouped)
    }
}

/// UserDefaults-backed switches for the popup cards and their alert sound.
/// MailboxViewModel checks the same keys before presenting cards or playing
/// the sound; absent keys read as enabled so existing installs keep behaving.
enum NotificationPrefs {
    static let soundKey = "notificationSoundEnabled"
    static let mailPopupsKey = "mailPopupsEnabled"
    static let reminderPopupsKey = "reminderPopupsEnabled"

    static var soundEnabled: Bool { isEnabled(soundKey) }
    static var mailPopupsEnabled: Bool { isEnabled(mailPopupsKey) }
    static var reminderPopupsEnabled: Bool { isEnabled(reminderPopupsKey) }

    private static func isEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(NotificationPrefs.mailPopupsKey) private var mailPopups = true
    @AppStorage(NotificationPrefs.reminderPopupsKey) private var reminderPopups = true
    @AppStorage(NotificationPrefs.soundKey) private var sound = true

    var body: some View {
        Form {
            Section {
                Toggle("New mail popups", isOn: $mailPopups)
                    .help("Show a card in the top-right corner when new mail arrives")
                Toggle("Calendar reminder popups", isOn: $reminderPopups)
                    .help("Show a card when a calendar event reminder fires")
                Toggle("Play sound", isOn: $sound)
                    .help("Play an alert sound when a reminder card appears")
            } header: {
                Text("Notifications")
            } footer: {
                Text("Popups appear in the top-right corner of the screen. Turning one off only stops new cards; anything already on screen stays until dismissed.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct FeedsSettingsTab: View {
    @Environment(MailboxViewModel.self) private var vm
    @AppStorage("feedAccountId") private var feedAccountId = ""
    @State private var newFeedURL = ""

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
        .onAppear {
            if feedAccountId.isEmpty { feedAccountId = vm.gmailSessions.first?.account.id ?? "" }
            vm.reloadFeedSubscriptions()
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

private struct DigestSettingsTab: View {
    @Environment(MailboxViewModel.self) private var vm
    /// Flips after a clear so the row confirms it (the count itself is not
    /// observable state — it's fetched from the store on each render).
    @State private var ledgerCleared = false

    var body: some View {
        Form {
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
        .onAppear { ledgerCleared = false }
    }
}

private struct AISettingsTab: View {
    @State private var storedKey = GeminiConfig.apiKey ?? ""
    @State private var draftKey = ""
    @State private var isReplacing = false

    var body: some View {
        Form {
            Section {
                if storedKey.isEmpty || isReplacing {
                    HStack {
                        TextField("API key", text: $draftKey, prompt: Text("Paste your Gemini API key"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                            .onSubmit(save)
                        Button("Save", action: save)
                            .disabled(trimmedDraft.isEmpty)
                        if isReplacing {
                            Button("Cancel") {
                                isReplacing = false
                                draftKey = ""
                            }
                        }
                    }
                } else {
                    HStack {
                        Text(maskedKey)
                            .font(.body.monospaced())
                            .textSelection(.disabled)
                        Spacer()
                        Button("Replace…") { isReplacing = true }
                            .help("Enter a different Gemini API key")
                    }
                }
            } header: {
                Text("Gemini API key")
            } footer: {
                Text("Used for Hebrew translation and digest summaries. Only the first 10 characters of the stored key are shown.")
            }
        }
        .formStyle(.grouped)
    }

    /// First 10 characters followed by a fixed run of bullets — enough to tell
    /// keys apart without exposing the full key (or its length).
    private var maskedKey: String {
        String(storedKey.prefix(10)) + String(repeating: "•", count: 6)
    }

    private var trimmedDraft: String {
        draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        guard !trimmedDraft.isEmpty else { return }
        GeminiConfig.setAPIKey(trimmedDraft)
        storedKey = trimmedDraft
        draftKey = ""
        isReplacing = false
    }
}
