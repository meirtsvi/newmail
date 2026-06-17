import AppKit
import SwiftUI

/// Opens each compose / reply / forward in its own free-floating, non-modal
/// window — movable, resizable, and miniaturizable — instead of a modal sheet,
/// so the main window stays usable while composing.
@MainActor
final class ComposeWindowController: NSObject, NSWindowDelegate {
    /// Live windows keyed by their compose request id, retained until closed.
    private var controllers: [String: NSWindowController] = [:]

    func open(_ request: ComposeRequest, vm: MailboxViewModel) {
        let key = request.id.uuidString
        // Already open for this request? Just bring it forward.
        if let existing = controllers[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = request.kind.title
        // The in-content title bar already shows the kind ("Forward"/"Reply"/…),
        // so hide the native title text to avoid showing it twice (traffic lights
        // and the Window menu entry stay intact).
        window.titleVisibility = .hidden
        // We hold the only strong reference (via the window controller); let ARC
        // free it once we drop that reference on close.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(key)

        let root = ComposeView(request: request, onClose: { [weak self] in
            self?.close(key)
        }).environment(vm)
        let hosting = NSHostingController(rootView: root)
        window.contentViewController = hosting
        // SwiftUI insets its content below the window's title bar, so the usable
        // height is the content area minus the title bar. Forwards/replies (with a
        // quoted-original preview) are taller than a blank compose; size the
        // window's content area to the view's fitting height plus the title-bar
        // height so the To field and title bar aren't clipped off the top.
        hosting.view.layoutSubtreeIfNeeded()
        let fitHeight = hosting.view.fittingSize.height
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        let contentHeight = max(fitHeight + titleBarHeight, 380)
        window.setContentSize(NSSize(width: 640, height: contentHeight))
        window.center()

        let controller = NSWindowController(window: window)
        controllers[key] = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func close(_ key: String) {
        controllers[key]?.close()
        controllers[key] = nil
    }

    /// Clean up when the user closes the window via its red close button.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = window.identifier?.rawValue else { return }
        controllers[key] = nil
    }
}
