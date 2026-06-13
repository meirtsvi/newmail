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
        }
        .modelContainer(Persistence.container)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
    }
}
