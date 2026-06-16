import AppKit
import SwiftUI

/// A borderless, always-on-top panel pinned to the top-right corner of the
/// screen that hosts the new-mail notification stack. It's a *nonactivating*
/// panel, so it stays visible — and its inline reply field stays editable —
/// even when newmail isn't the active app.
@MainActor
final class NotificationPanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel

    init(rootView: some View) {
        let hosting = NSHostingController(rootView: rootView)
        // The window tracks the SwiftUI content's size, so it grows/shrinks as the
        // stack changes and the inline reply expands.
        hosting.sizingOptions = [.preferredContentSize]

        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar           // stays above other apps' windows
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        super.init()
        panel.delegate = self
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Keep the panel glued to the top-right corner as its height changes (the
    /// stack grows/shrinks, or the inline reply expands).
    func windowDidResize(_ notification: Notification) {
        reposition()
    }

    private func reposition() {
        // The macOS "main" display (menu bar / origin at zero), not the
        // focus-following NSScreen.main.
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 14
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - margin,
            y: visible.maxY - size.height - margin
        ))
    }
}

/// NSPanel subclass that can become key so the inline reply field accepts input
/// without activating the whole app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
