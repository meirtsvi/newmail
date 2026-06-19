import AppKit
import SwiftUI

/// Opens the read-only message view (double-click) in its own free-floating,
/// resizable window instead of a fixed-size modal sheet — so the user can size
/// it to taste and the main window stays usable. A single window is reused: a
/// second double-click retargets it, since the hosted `MessageDetailView` reads
/// the current message from `vm.modalHeader`.
@MainActor
final class MessageWindowController: NSObject, NSWindowDelegate {
    private var controller: NSWindowController?

    func open(vm: MailboxViewModel) {
        // Already open? The view tracks `vm.modalHeader`, so just surface it.
        if let controller {
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Default size matches the reference window: ~897×964 pt overall, so the
        // content area is that minus the title bar height.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 897, height: 950),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        // The in-content toolbar already shows the subject, so hide the native
        // title text (traffic lights and the Window menu entry stay intact).
        window.titleVisibility = .hidden
        // We hold the only strong reference (via the window controller); let ARC
        // free it once we drop that reference on close.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 480, height: 360)

        let root = MessageDetailView(onClose: { [weak self] in
            self?.controller?.close()
        }).environment(vm)
        let hosting = NSHostingController(rootView: root)
        // By default NSHostingController shrinks the window to the SwiftUI
        // content's fitting size (the view's min frame), overriding contentRect.
        // Clear sizingOptions so our 1794×1900 default size sticks.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 897, height: 950))
        window.center()

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Drop our reference when the user closes the window (red button, ⌘W, or the
    /// Done/Escape callback above) so a later double-click builds a fresh one.
    func windowWillClose(_ notification: Notification) {
        controller = nil
    }
}
