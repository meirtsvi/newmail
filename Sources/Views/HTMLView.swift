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

/// Renders sanitized message HTML in a WKWebView. Link clicks open in the
/// default macOS browser rather than navigating inside the preview pane.
struct HTMLView: NSViewRepresentable {
    let html: String
    var finder: WebFindController? = nil
    var zoom: Double = 1.0
    /// Horizontal page margin in CSS px. Kept inside the page (rather than
    /// SwiftUI padding around the web view) so the scrollbar hugs the pane edge.
    var horizontalMargin: Int = 16

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        finder?.webView = webView
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
            margin: 16px \(horizontalMargin)px; line-height: 1.5; word-wrap: break-word;
          }
          img { max-width: 100%; height: auto; }
          table { max-width: 100%; }
          a { color: #0a66c2; }
          pre { white-space: pre-wrap; }
        </style></head><body>\(body)</body></html>
        """
    }
}
