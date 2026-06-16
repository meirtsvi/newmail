import AppKit
import SwiftUI

/// A borderless, always-on-top panel pinned to the top-right corner of the
/// screen that hosts the new-mail notification stack. It's a *nonactivating*
/// panel, so it stays visible — and its inline reply field stays editable —
/// even when newmail isn't the active app.
@MainActor
final class NotificationPanelController: NSObject, NSWindowDelegate {
    private let panel: FloatingPanel
    private let hosting: NSHostingController<AnyView>
    /// Coalesces reposition requests onto the next runloop tick (see `scheduleReposition`).
    private var repositionScheduled = false
    /// Last content size we applied — used to ignore no-op size reports.
    private var lastContentSize: CGSize = .zero

    init(rootView: some View) {
        // The window's size is driven *manually* from the content's measured ideal
        // size (see below), not by the hosting controller's auto-sizing. Letting
        // `.preferredContentSize` resize the window from inside the layout pass set
        // up a layout↔resize feedback loop with AutoLayout that never converged and
        // overflowed the stack. Measuring with a GeometryReader and resizing on the
        // next runloop tick keeps the two decoupled.
        hosting = NSHostingController(rootView: AnyView(EmptyView()))
        hosting.sizingOptions = []

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

        // `.fixedSize()` makes the content adopt its own ideal size regardless of the
        // window's current size; the GeometryReader behind it reports that size so we
        // can fit the window to it.
        hosting.rootView = AnyView(
            rootView
                .fixedSize()
                .background(SizeReporter { [weak self] in self?.contentSizeChanged($0) })
        )
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
        scheduleReposition()
    }

    /// Fits the window to the content's measured ideal size, on the next runloop tick
    /// so it can't re-enter SwiftUI's layout pass. Ignores no-op reports so a stable
    /// size doesn't keep rescheduling work.
    private func contentSizeChanged(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        guard abs(size.width - lastContentSize.width) > 0.5
                || abs(size.height - lastContentSize.height) > 0.5 else { return }
        lastContentSize = size
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.setContentSize(size)
            self.reposition()
        }
    }

    /// Queues a reposition for the next runloop tick (at most one in flight), so a
    /// frame change made *inside* `reposition` can't re-enter it synchronously.
    private func scheduleReposition() {
        guard !repositionScheduled else { return }
        repositionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.repositionScheduled = false
            self.reposition()
        }
    }

    private func reposition() {
        // The macOS "main" display (menu bar / origin at zero), not the
        // focus-following NSScreen.main.
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 14
        let size = panel.frame.size
        let origin = NSPoint(
            x: (visible.maxX - size.width - margin).rounded(),
            y: (visible.maxY - size.height - margin).rounded()
        )
        // Skip redundant frame sets — moving to the same spot would needlessly
        // re-fire the resize notification.
        guard panel.frame.origin != origin else { return }
        panel.setFrameOrigin(origin)
    }
}

/// Reports the size of the view it backs through a closure, on appear and whenever
/// it changes. Used to fit the notification panel to its SwiftUI content.
private struct SizeReporter: View {
    let onChange: (CGSize) -> Void
    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.size) }
                .onChange(of: geo.size) { _, size in onChange(size) }
        }
    }
}

/// NSPanel subclass that can become key so the inline reply field accepts input
/// without activating the whole app.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
