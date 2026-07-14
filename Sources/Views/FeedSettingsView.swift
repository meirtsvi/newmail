import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The Settings (⌘,) window, split into tabs by area:
///   Account — re-run the Google / Microsoft sign-in (fixes 401s from an
///             expired or revoked token)
///   Feeds   — manage RSS/Atom feed URLs and, with more than one Gmail account,
///             choose which one receives feed items
///   Digest  — clear the digest coverage history
///   AI      — the Gemini API key used for translation and digest summaries
///   Translation — words the Hebrew translation/summary keeps in English
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
            TranslationSettingsTab()
                .tabItem { Label("Translation", systemImage: "character.bubble") }
        }
        .frame(width: 760, height: 440)
        // Escape closes the Settings window (not the default for a Settings scene).
        // A hidden cancel-action button catches Escape no matter which tab or
        // control has focus; .onExitCommand on the TabView only fired when the
        // tab content itself didn't swallow the key.
        .background(
            Button("") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        )
    }
}

private struct AccountSettingsTab: View {
    @Environment(MailboxViewModel.self) private var vm

    var body: some View {
        Form {
            Section("Google account") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(vm.hasConnectedGoogleAccount
                             ? vm.gmailSessions.first.map { $0.account.email.isEmpty ? $0.account.displayName : $0.account.email } ?? "Google"
                             : "Not connected")
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
                            Text(vm.hasConnectedGoogleAccount ? "Sign in again…" : "Sign in…")
                        }
                    }
                    .disabled(vm.isSigningIn)
                    .help(vm.hasConnectedGoogleAccount
                          ? "Re-run the Google sign-in in your browser to fix authorization errors"
                          : "Sign in with Google in your browser to connect your Gmail account")
                }
            }

            Section("Microsoft account") {
                HStack {
                    Text(vm.hasConnectedMicrosoftAccount
                         ? vm.graphSessions.first.map { $0.account.email.isEmpty ? $0.account.displayName : $0.account.email } ?? "Microsoft"
                         : "Not connected")
                    Spacer()
                    Button {
                        Task { await vm.addMicrosoftAccount() }
                    } label: {
                        if vm.isSigningIn {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Signing in…")
                            }
                        } else {
                            Text(vm.hasConnectedMicrosoftAccount ? "Sign in again…" : "Sign in…")
                        }
                    }
                    .disabled(vm.isSigningIn)
                    .help(vm.hasConnectedMicrosoftAccount
                          ? "Re-run the Microsoft sign-in to fix authorization errors"
                          : "Sign in with Microsoft to connect your Outlook account")
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
    static let mailSoundKey = "mailSoundEnabled"
    static let reminderSoundKey = "reminderSoundEnabled"
    static let mailPopupsKey = "mailPopupsEnabled"
    static let reminderPopupsKey = "reminderPopupsEnabled"

    /// Paths of user-chosen sound files (copied into Application Support);
    /// empty/absent means the built-in alert sound.
    static let mailSoundFileKey = "mailSoundFile"
    static let reminderSoundFileKey = "reminderSoundFile"

    static var mailSoundEnabled: Bool { isEnabled(mailSoundKey) }
    static var reminderSoundEnabled: Bool { isEnabled(reminderSoundKey) }
    static var mailPopupsEnabled: Bool { isEnabled(mailPopupsKey) }
    static var reminderPopupsEnabled: Bool { isEnabled(reminderPopupsKey) }

    /// The custom sound stored under `key`, if one was chosen and its file
    /// still exists; nil falls back to the built-in sound.
    static func customSoundURL(forKey key: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: key), !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    private static func isEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

private struct NotificationSettingsTab: View {
    @AppStorage(NotificationPrefs.mailPopupsKey) private var mailPopups = true
    @AppStorage(NotificationPrefs.reminderPopupsKey) private var reminderPopups = true
    @AppStorage(NotificationPrefs.mailSoundKey) private var mailSound = true
    @AppStorage(NotificationPrefs.reminderSoundKey) private var reminderSound = true

    var body: some View {
        Form {
            Section("New mail") {
                Toggle("Show popups", isOn: $mailPopups)
                    .help("Show a card in the bottom-right corner when new mail arrives")
                Toggle("Play sound", isOn: $mailSound)
                    .help("Play an alert sound when a new mail card appears")
                CustomSoundRow(storageKey: NotificationPrefs.mailSoundFileKey, folder: "mail")
            }
            Section {
                Toggle("Show popups", isOn: $reminderPopups)
                    .help("Show a card when a calendar event reminder fires")
                Toggle("Play sound", isOn: $reminderSound)
                    .help("Play an alert sound when a reminder card appears")
                CustomSoundRow(storageKey: NotificationPrefs.reminderSoundFileKey, folder: "reminder")
            } header: {
                Text("Calendar reminders")
            } footer: {
                Text("Popups appear in the bottom-right corner of the screen. Turning one off only stops new cards; anything already on screen stays until dismissed.")
            }
        }
        .formStyle(.grouped)
    }
}

/// The "Sound file" row of a notification section: shows the current choice
/// (built-in or a picked file), a Choose… button that copies the picked audio
/// file into Application Support (so it keeps working if the original moves),
/// and Use Default to revert. The picked sound plays once as confirmation.
private struct CustomSoundRow: View {
    let storageKey: String
    /// Subfolder under Application Support/Sounds; one per source so mail and
    /// reminder picks don't overwrite each other.
    let folder: String

    @AppStorage private var soundPath: String
    /// Keeps the confirmation sound alive while it plays.
    @State private var preview: NSSound?

    init(storageKey: String, folder: String) {
        self.storageKey = storageKey
        self.folder = folder
        _soundPath = AppStorage(wrappedValue: "", storageKey)
    }

    var body: some View {
        HStack {
            Text("Sound file")
            Spacer()
            Text(soundPath.isEmpty ? "Built-in (Glass)"
                                   : URL(fileURLWithPath: soundPath).lastPathComponent)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !soundPath.isEmpty {
                Button("Use Default") { revert() }
                    .help("Go back to the built-in alert sound")
            }
            Button("Choose…", action: choose)
                .help("Pick an audio file to play instead of the built-in sound")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let dir = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask,
                     appropriateFor: nil, create: true)
                .appendingPathComponent("Sounds/\(folder)", isDirectory: true)
            // One custom sound per source: drop the previous copy first.
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: dest)
            guard let sound = NSSound(contentsOf: dest, byReference: true) else {
                // Copied fine but NSSound can't decode it — reject rather than
                // storing a file that would silently fall back at alert time.
                try? FileManager.default.removeItem(at: dir)
                NSSound.beep()
                return
            }
            soundPath = dest.path
            preview = sound
            sound.play()
        } catch {
            NSSound.beep()
        }
    }

    private func revert() {
        if !soundPath.isEmpty {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: soundPath).deletingLastPathComponent())
        }
        soundPath = ""
    }
}

private struct FeedsSettingsTab: View {
    @Environment(MailboxViewModel.self) private var vm
    @AppStorage("feedAccountId") private var feedAccountId = ""
    @State private var newFeedURL = ""

    var body: some View {
        // The form (account picker + feed list) scrolls; the add-feed row sits
        // below it in a fixed bar so it stays visible however long the list gets.
        VStack(spacing: 0) {
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
            }
            .formStyle(.grouped)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    TextField("Feed URL", text: $newFeedURL, prompt: Text("https://example.com/feed.xml"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit(add)
                    Button("Add", action: add).disabled(!isValidURL)
                }
                Text("New items are added to your Gmail Inbox as unread messages, checked every 5 minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
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

private struct TranslationSettingsTab: View {
    @State private var words = TranslationPrefs.skipWords
    @State private var saved = false

    var body: some View {
        Form {
            Section {
                TextField("Words to keep in English", text: $words, axis: .vertical)
                    .labelsHidden()
                    .lineLimit(4...8)
                HStack {
                    if saved {
                        Text("Saved.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save", action: save)
                        .disabled(words == TranslationPrefs.skipWords)
                }
            } header: {
                Text("Words to keep in English")
            } footer: {
                Text("Comma-separated words or phrases (e.g. “pull request”) that translating a mail to Hebrew — and the Hebrew summary — will leave in English.")
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        UserDefaults.standard.set(words, forKey: TranslationPrefs.skipWordsKey)
        saved = true
    }
}
