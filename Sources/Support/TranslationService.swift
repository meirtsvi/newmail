import Foundation
import WebKit

/// Translates a message's HTML to Hebrew in place (keeping images/links/tables)
/// and produces a short Hebrew summary, using the Gemini API.
///
/// HTML manipulation is done inside an offscreen `WKWebView` with JavaScript:
/// walk the DOM text nodes, translate only those (batched, JSON-array in/out —
/// a port of the Python `hebrew_digests.py`), write them back, and read out the
/// resulting `innerHTML`. WebKit is used because real-world email HTML has
/// inconsistent entity encoding and malformed markup that a standalone parser
/// can't round-trip reliably — the browser engine that renders the mail does.
@MainActor
final class TranslationService {
    static let shared = TranslationService()

    private static let maxBatchChars = 8000
    private static let maxBatchItems = 80

    // MARK: - Public API

    /// Returns the message HTML with every visible text node translated to Hebrew,
    /// wrapped in an RTL container.
    func translateHTMLToHebrew(_ html: String) async throws -> String {
        let session = WebSession()
        try await session.load(html)

        let texts = try await session.extractTextNodes()
        guard !texts.isEmpty else { return Self.wrapRTL(html) }

        var translated = texts
        for group in Self.packBatches(texts) {
            let chunk = group.map { texts[$0] }
            let results = try await translateBatch(chunk)
            for (i, r) in zip(group, results) { translated[i] = r }
        }

        let inner = try await session.applyTextNodes(translated)
        return Self.wrapRTL(inner)
    }

    /// Returns a 5-paragraph Hebrew summary of the message, as RTL HTML. Falls
    /// back to text extracted from the HTML when the message has no plain-text part.
    func summarizeInHebrew(plainText: String, html: String) async throws -> String {
        var text = plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            let session = WebSession()
            try await session.load(html)
            text = try await session.innerText().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !text.isEmpty else { throw TranslationError.emptyInput }
        let out = try await geminiGenerate(system: Self.summarySystem, userText: text)
        return Self.wrapSummary(out)
    }

    // MARK: - Batching

    /// Groups indices into batches bounded by char count and item count
    /// (port of `_pack_batches`).
    private static func packBatches(_ texts: [String]) -> [[Int]] {
        var batches: [[Int]] = []
        var current: [Int] = []
        var currentChars = 0
        for (i, t) in texts.enumerated() {
            let tlen = t.count
            if !current.isEmpty && (currentChars + tlen > maxBatchChars || current.count >= maxBatchItems) {
                batches.append(current)
                current = [i]
                currentChars = tlen
            } else {
                current.append(i)
                currentChars += tlen
            }
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    // MARK: - Gemini translation (batched with retry + split fallback)

    /// Port of `_gemini_translate_batch`: on failure, splits the batch in half;
    /// a single failed item keeps its original text.
    private func translateBatch(_ texts: [String]) async throws -> [String] {
        if texts.isEmpty { return [] }
        if let result = try await translateCall(texts) { return result }
        if texts.count == 1 { return texts }
        let mid = texts.count / 2
        let first = try await translateBatch(Array(texts[0..<mid]))
        let second = try await translateBatch(Array(texts[mid...]))
        return first + second
    }

    /// Port of `_gemini_call`: 3 attempts, expects a JSON array of the same length.
    /// Returns nil when all attempts fail (caller then splits or keeps originals).
    private func translateCall(_ texts: [String]) async throws -> [String]? {
        let inputData = try JSONSerialization.data(withJSONObject: texts)
        let input = String(data: inputData, encoding: .utf8) ?? "[]"

        for attempt in 0..<3 {
            do {
                let text = try await geminiGenerate(system: Self.translationSystem, userText: input,
                                                    responseSchema: ["type": "ARRAY", "items": ["type": "STRING"]])
                if let data = text.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode([String].self, from: data),
                   parsed.count == texts.count {
                    // Keep original when the model returns an empty string.
                    return zip(parsed, texts).map { $0.isEmpty ? $1 : $0 }
                }
            } catch {
                // fall through to retry / return nil
            }
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: UInt64(1.5 * Double(attempt + 1) * 1_000_000_000))
            }
        }
        return nil
    }

    // MARK: - Gemini REST

    /// One Gemini `generateContent` call. Pass a `responseSchema` to force JSON
    /// output of that shape (translation uses a string array; the digest an object).
    /// Internal so other Gemini-backed features (e.g. the digest) reuse one client.
    func geminiGenerate(system: String, userText: String, responseSchema: [String: Any]? = nil) async throws -> String {
        guard let apiKey = GeminiConfig.apiKey else { throw TranslationError.notConfigured }

        var components = URLComponents(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(GeminiConfig.model):generateContent")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var generationConfig: [String: Any] = ["temperature": 0.2]
        if let responseSchema {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = responseSchema
        }
        let payload: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["parts": [["text": userText]]]],
            "generationConfig": generationConfig,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.http(-1, "") }
        guard (200..<300).contains(http.statusCode) else {
            throw TranslationError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        let text = decoded.candidates?.first?.content.parts.compactMap { $0.text }.joined() ?? ""
        guard !text.isEmpty else { throw TranslationError.emptyResponse }
        return text
    }

    // MARK: - HTML wrapping

    private static func wrapRTL(_ inner: String) -> String {
        "<div dir=\"rtl\" style=\"text-align:right\">\(inner)</div>"
    }

    private static func wrapSummary(_ text: String) -> String {
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let body = paragraphs
            .map { "<p>\(htmlEscape($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" }
            .joined()
        return "<div dir=\"rtl\" style=\"text-align:right; line-height:1.6\">\(body)</div>"
    }

    static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: - Prompts

    /// Verbatim from the Python reference (`TRANSLATION_SYSTEM_INSTRUCTION`).
    private static let translationSystem = """
    You translate short English strings from an email into natural, fluent Hebrew. Rules:
    1. Keep these in English, untranslated: product names, model names, company names, library/framework/tool names, code snippets, CLI commands, URLs, file paths, API identifiers, technical acronyms (e.g., Claude Code, NVIDIA, NIM, GPT-5, API, SDK, LLM, RAG, MCP, ChatGPT, Gemini, Anthropic, OpenAI, Cursor, npm, pip, Python). ALWAYS keep these exact words in English, never translate them: sandbox, sandboxes, alignment, self verification, spec, routine, dashboard, orchestrate, frontier.
    2. Translate the surrounding prose into idiomatic Hebrew — do not transliterate.
    3. Preserve emoji, punctuation, leading/trailing whitespace, and line breaks exactly.
    4. If a string is only punctuation, whitespace, a URL, a number, or a bare technical identifier, return it unchanged.
    5. Return a JSON array of strings with the SAME LENGTH and ORDER as the input.
    """

    private static let summarySystem = """
    You summarize an email into exactly 5 well-structured paragraphs of natural, fluent Hebrew.
    Rules:
    - Separate the paragraphs with a single blank line.
    - Keep product names, company names, model names, code, CLI commands, and URLs in English.
    - Write idiomatic Hebrew prose — do not transliterate.
    - Output only the Hebrew summary, with no preamble, headings, or numbering.
    """
}

// MARK: - Offscreen WebKit session

/// A short-lived offscreen `WKWebView` used to walk and rewrite a single
/// message's DOM. One instance per translate/summarize call so its captured node
/// references can't be clobbered by a concurrent call.
@MainActor
private final class WebSession: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var loadContinuation: CheckedContinuation<Void, Error>?

    override init() {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 600), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func load(_ html: String) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    /// Collects visible text-node values (skipping script/style/etc.) and keeps
    /// the matching node references on `window.__xnodes` for `applyTextNodes`.
    func extractTextNodes() async throws -> [String] {
        let js = """
        (function(){
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
          var skip = {SCRIPT:1, STYLE:1, HEAD:1, META:1, TITLE:1, LINK:1, NOSCRIPT:1};
          var nodes = [], texts = [], n;
          while ((n = walker.nextNode())) {
            var pn = n.parentNode ? n.parentNode.nodeName : '';
            if (skip[pn]) continue;
            if (!n.nodeValue || !n.nodeValue.trim()) continue;
            nodes.push(n); texts.push(n.nodeValue);
          }
          window.__xnodes = nodes;
          return JSON.stringify(texts);
        })()
        """
        guard let s = try await webView.evaluateJavaScript(js) as? String,
              let data = s.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return arr
    }

    /// Writes translated values back onto the captured text nodes and returns the
    /// resulting body HTML (with any `<style>` blocks preserved).
    func applyTextNodes(_ translated: [String]) async throws -> String {
        let literal = Self.jsArrayLiteral(translated)
        let js = """
        (function(){
          var t = \(literal);
          var nodes = window.__xnodes || [];
          for (var i = 0; i < nodes.length && i < t.length; i++) { nodes[i].nodeValue = t[i]; }
          var styles = Array.prototype.map.call(document.querySelectorAll('style'), function(s){ return s.outerHTML; }).join('');
          return styles + document.body.innerHTML;
        })()
        """
        guard let s = try await webView.evaluateJavaScript(js) as? String else {
            throw TranslationError.emptyResponse
        }
        return s
    }

    func innerText() async throws -> String {
        (try await webView.evaluateJavaScript("document.body.innerText") as? String) ?? ""
    }

    /// A JS array literal, safely escaped (JSON is valid JS, plus the two line/
    /// paragraph separators that are legal in JSON but not in JS source).
    private static func jsArrayLiteral(_ arr: [String]) -> String {
        let data = (try? JSONEncoder().encode(arr)) ?? Data("[]".utf8)
        return (String(data: data, encoding: .utf8) ?? "[]")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loadContinuation?.resume()
        loadContinuation = nil
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
    }
}

// MARK: - Response model & errors

private struct GeminiResponse: Decodable {
    struct Candidate: Decodable { let content: Content }
    struct Content: Decodable { let parts: [Part] }
    struct Part: Decodable { let text: String? }
    let candidates: [Candidate]?
}

enum TranslationError: LocalizedError {
    case notConfigured
    case emptyInput
    case emptyResponse
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Gemini API key missing (add Resources/gemini.json)."
        case .emptyInput: return "Nothing to translate."
        case .emptyResponse: return "Gemini returned an empty response."
        case .http(let code, _): return "Gemini request failed (HTTP \(code))."
        }
    }
}
