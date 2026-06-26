import SwiftUI
import SwiftData
import AppKit

@main
struct NewmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm = MailboxViewModel()

    var body: some Scene {
        // A single `Window` (not a `WindowGroup`): the app has one main window,
        // and the message/compose UIs open as sheets / separate panels. Using
        // `Window` means an incoming mailto: (a share from Chrome, a mail link)
        // can't spawn a duplicate main window the way a `WindowGroup` does.
        Window("newmail", id: "main") {
            ContentView()
                .environment(vm)
                .frame(minWidth: 1100, minHeight: 660)
                .task { await vm.bootstrap() }
                // Hand the view model to the app delegate so it can route incoming
                // mailto: URLs (see AppDelegate) to this running instance.
                .onAppear { appDelegate.vm = vm }
        }
        .modelContainer(Persistence.container)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
    }
}

/// Handles incoming `mailto:` URLs (default-mail-client clicks, Chrome's "share
/// → email", etc.) at the AppKit level, routing them to the running instance so
/// it just opens a compose window. Also buffers URLs that arrive during a cold
/// launch (before the window's view model is wired up) and replays them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the main window appears. Weak: the `App` owns the view model.
    weak var vm: MailboxViewModel? { didSet { flushPending() } }
    /// URLs that arrived before the view model was available, replayed on assignment.
    private var pending: [URL] = []

    func application(_ application: NSApplication, open urls: [URL]) {
        pending.append(contentsOf: urls)
        flushPending()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func flushPending() {
        guard let vm, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        // AppKit delegate callbacks run on the main thread.
        MainActor.assumeIsolated {
            for url in urls {
                // The Share extension wakes the app with newmail://share to have it
                // collect the files it staged; everything else is a mailto: compose.
                if url.scheme?.lowercased() == "newmail" { vm.openSharedAttachments() }
                else { vm.handleMailto(url) }
            }
        }
    }

    /// Catch files the Share extension staged even if its wake-up URL didn't reach us
    /// (e.g. the app was already frontmost, or the extension couldn't open the URL).
    func applicationDidBecomeActive(_ notification: Notification) {
        MainActor.assumeIsolated { vm?.openSharedAttachments() }
    }
}
