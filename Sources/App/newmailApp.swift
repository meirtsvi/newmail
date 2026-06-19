import SwiftUI
import SwiftData

@main
struct NewmailApp: App {
    @State private var vm = MailboxViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(vm)
                .frame(minWidth: 1100, minHeight: 660)
                .task { await vm.bootstrap() }
                // Opens a pre-filled compose window when the app is the default
                // mail client and a mailto: link is clicked (also handles launch).
                .onOpenURL { vm.handleMailto($0) }
        }
        .modelContainer(Persistence.container)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
    }
}
