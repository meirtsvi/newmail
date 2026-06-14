import Foundation

/// Converts a plain-text message body into safe HTML for display: escapes markup
/// and turns bare URLs into clickable links. Used by providers when a message has
/// no HTML part. Links open in the default browser via `HTMLView`'s navigation
/// handling.
enum PlainTextHTML {
    /// Wraps linkified, escaped text in a wrapping `<pre>` block (preserves the
    /// original line breaks/spacing of a plain-text email).
    static func render(_ text: String) -> String {
        "<pre style=\"white-space:pre-wrap;font-family:-apple-system,sans-serif\">\(linkify(text))</pre>"
    }

    /// Escapes HTML and wraps any detected URLs in anchor tags. Uses
    /// `NSDataDetector` so it handles bare `www.` hosts, trailing punctuation, and
    /// query strings correctly.
    static func linkify(_ text: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return escape(text)
        }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            let range = match.range
            if range.location > cursor {
                out += escape(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)))
            }
            let shown = ns.substring(with: range)
            let href = match.url?.absoluteString ?? shown
            out += "<a href=\"\(escapeAttribute(href))\">\(escape(shown))</a>"
            cursor = range.location + range.length
        }
        if cursor < ns.length { out += escape(ns.substring(from: cursor)) }
        return out
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func escapeAttribute(_ s: String) -> String {
        escape(s).replacingOccurrences(of: "\"", with: "&quot;")
    }
}
