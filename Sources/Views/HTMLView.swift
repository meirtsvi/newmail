import SwiftUI
import WebKit
import AppKit

/// In-page find for a message body, backed by WKWebView's native find API.
@MainActor
final class WebFindController: ObservableObject {
    weak var webView: WKWebView?
    @Published var status: String = ""

    func find(_ text: String, forward: Bool = true) {
        guard let webView, !text.isEmpty else { return }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true
        webView.find(text, configuration: config) { [weak self] result in
            self?.status = result.matchFound ? "" : "No matches"
        }
    }
}

/// A message-body web view whose right-click menu gains "Send to <Shortcut>"
/// items when the pointer is over a link.
///
/// WebKit builds the native menu synchronously in `willOpenMenu`, but finding the
/// link under the pointer needs an async round trip into the page. So the mouse-down
/// that opens the menu is held back: the link is resolved first, then the same event
/// is replayed to WebKit, which now opens a menu we can extend.
final class MessageWebView: WKWebView {
    private var linkUnderPointer: URL?
    /// The event currently being replayed, so the second pass falls straight through
    /// to WebKit instead of resolving the link again and recursing forever.
    private var replayedEvent: NSEvent?

    override func rightMouseDown(with event: NSEvent) {
        if replayedEvent === event {
            replayedEvent = nil
            super.rightMouseDown(with: event)
            return
        }
        resolveLink(at: event) { [weak self] in
            guard let self else { return }
            self.replayedEvent = event
            self.rightMouseDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        // A control-click opens the context menu through the left-button path, so it
        // needs the same resolution. A plain click only has to drop the stale link,
        // or a later control-click over ordinary text would still offer to send it.
        guard event.modifierFlags.contains(.control) else {
            linkUnderPointer = nil
            super.mouseDown(with: event)
            return
        }
        if replayedEvent === event {
            replayedEvent = nil
            super.mouseDown(with: event)
            return
        }
        resolveLink(at: event) { [weak self] in
            guard let self else { return }
            self.replayedEvent = event
            self.mouseDown(with: event)
        }
    }

    /// Looks up the link under `event` into `linkUnderPointer`, then calls `replay`.
    private func resolveLink(at event: NSEvent, replay: @escaping () -> Void) {
        // View points are bottom-left origin and scaled by `pageZoom`;
        // `elementFromPoint` wants unscaled CSS pixels from the viewport's top-left.
        let point = convert(event.locationInWindow, from: nil)
        let x = point.x / pageZoom
        let y = (isFlipped ? point.y : bounds.height - point.y) / pageZoom
        let script = """
        (function() {
          var el = document.elementFromPoint(\(x), \(y));
          var link = el && el.closest ? el.closest('a') : null;
          return link && link.href ? link.href : '';
        })()
        """
        // `.defaultClient` runs in the app's own content world, which is exempt from
        // the `allowsContentJavaScript = false` that keeps the message's own scripts
        // from running.
        evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            if case .success(let value) = result, let href = value as? String {
                self.linkUnderPointer = URL(string: href)
            } else {
                self.linkUnderPointer = nil
            }
            replay()
        }
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        // Pick up shortcuts added since the last menu; this lands for the next one.
        ShortcutsService.refresh()

        guard let url = linkUnderPointer else { return }
        let names = ShortcutsService.menuShortcuts
        guard !names.isEmpty else { return }

        menu.addItem(.separator())
        if names.count == 1 {
            menu.addItem(item(for: names[0], url: url, title: "Send to \(names[0])"))
        } else {
            let parent = NSMenuItem(title: "Send to Shortcut", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for name in names {
                submenu.addItem(item(for: name, url: url, title: name))
            }
            parent.submenu = submenu
            menu.addItem(parent)
        }
    }

    private func item(for shortcut: String, url: URL, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runShortcut(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ShortcutTarget(shortcut: shortcut, url: url)
        return item
    }

    @objc private func runShortcut(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? ShortcutTarget else { return }
        ShortcutsService.run(target.shortcut, on: target.url)
    }

    private final class ShortcutTarget {
        let shortcut: String
        let url: URL
        init(shortcut: String, url: URL) {
            self.shortcut = shortcut
            self.url = url
        }
    }
}

/// Renders sanitized message HTML in a WKWebView. Link clicks open in the
/// default macOS browser rather than navigating inside the preview pane.
struct HTMLView: NSViewRepresentable {
    let html: String
    var finder: WebFindController? = nil
    var zoom: Double = 1.0
    /// Horizontal page margin in CSS px. Kept inside the page (rather than
    /// SwiftUI padding around the web view) so the scrollbar hugs the pane edge.
    /// Applied as inline padding on a wrapper div, not on `body`: many emails
    /// ship a `body { margin: 0 }` reset that would override a body margin.
    var horizontalMargin: Int = 16

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = MessageWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        finder?.webView = webView
        // Warm the shortcut list so the first right-click already has items.
        ShortcutsService.refresh()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Only reload when the content actually changes; a zoom change alone must
        // not reload (that would reset scroll position).
        if context.coordinator.loadedHTML != html {
            context.coordinator.loadedHTML = html
            webView.loadHTMLString(wrap(html), baseURL: nil)
        }
        webView.pageZoom = zoom
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedHTML: String?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Open only links the user actually clicks in the default browser.
            // Everything else — the initial in-memory load, and subframe loads such
            // as embedded YouTube/video iframes — must render inline; opening those
            // would launch the browser the moment a message with an embed is viewed.
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow); return
            }
            if navigationAction.navigationType == .linkActivated {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        // Handle target="_blank" links.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
            }
            return nil
        }
    }

    private func wrap(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          :root { color-scheme: light dark; }
          body {
            font: -apple-system-body;
            font-family: -apple-system, "SF Pro Text", Helvetica, Arial, sans-serif;
            margin: 0; line-height: 1.5; word-wrap: break-word;
          }
          img { max-width: 100%; height: auto; }
          table { max-width: 100%; }
          a { color: #0a66c2; }
          pre { white-space: pre-wrap; }
        </style></head><body><div style="padding: 16px \(horizontalMargin)px;">\(body)</div></body></html>
        """
    }
}
