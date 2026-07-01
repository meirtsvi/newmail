import SwiftUI
import WebKit

/// Holds the live `WKWebView` for an `HTMLEditorView` so the surrounding view can
/// pull the edited HTML back out on demand.
@MainActor
final class HTMLEditorController: ObservableObject {
    fileprivate weak var webView: WKWebView?
    /// Invoked when the user presses Shift-Tab in the body, to move focus back to
    /// the Subject field (mirrors `RichTextController.onShiftTab`).
    var onShiftTab: (() -> Void)?

    /// Moves keyboard focus into the body editor (used to jump straight from the
    /// Subject field to the body). Makes the WebView first responder, then focuses
    /// the editable document body.
    func focus() {
        guard let webView else { return }
        webView.window?.makeFirstResponder(webView)
        webView.evaluateJavaScript("if (document.body) { document.body.focus(); }")
    }

    /// The current document HTML, faithful to what was loaded: the original DOM
    /// edited in place, so styles, fonts, image sizes, and spacing survive intact.
    /// Strips the editor-only affordances (designMode, helper stylesheet) first.
    func exportHTML() async -> String {
        guard let webView else { return "" }
        let js = """
        (function () {
          var s = document.getElementById('nm-editor-only');
          if (s) s.remove();
          document.designMode = 'off';
          return '<!DOCTYPE html>\\n' + document.documentElement.outerHTML;
        })()
        """
        let result = try? await webView.evaluateJavaScript(js)
        return (result as? String) ?? ""
    }
}

/// A WKWebView that loads a message's original HTML and makes it editable in place
/// via `document.designMode`. Unlike the NSAttributedString-based `RichTextEditor`,
/// this preserves the source HTML/CSS exactly (used only for "Edit message", where
/// faithfully keeping a richly-formatted message's layout matters).
struct HTMLEditorView: NSViewRepresentable {
    let html: String
    let controller: HTMLEditorController

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // The page itself runs no scripts; we only drive editing via designMode and
        // native evaluateJavaScript. JS stays enabled so those calls take effect.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // Shift-Tab in the body posts back here so compose can move focus to Subject.
        config.userContentController.add(context.coordinator, name: "shiftTab")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        controller.webView = webView
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    // The HTML is loaded once in makeNSView; reloading on every SwiftUI update would
    // wipe the user's edits, so updates are intentionally a no-op.
    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let controller: HTMLEditorController
        init(controller: HTMLEditorController) { self.controller = controller }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Turn on whole-document editing and add an editor-only stylesheet (kept
            // out of the saved HTML by exportHTML) so images don't overflow the pane.
            // The capturing keydown listener routes Shift-Tab back to native (via the
            // shiftTab message handler) instead of letting designMode swallow it, so
            // focus returns to the Subject field.
            let js = """
            document.designMode = 'on';
            if (!document.getElementById('nm-editor-only')) {
              var s = document.createElement('style');
              s.id = 'nm-editor-only';
              s.textContent = 'img{max-width:100%;height:auto;} body{margin:8px;}';
              (document.head || document.documentElement).appendChild(s);
            }
            document.addEventListener('keydown', function (e) {
              if (e.key === 'Tab' && e.shiftKey) {
                e.preventDefault();
                window.webkit.messageHandlers.shiftTab.postMessage('');
              }
            }, true);
            if (document.body) { document.body.focus(); }
            """
            webView.evaluateJavaScript(js)
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            if message.name == "shiftTab" { controller.onShiftTab?() }
        }
    }
}
