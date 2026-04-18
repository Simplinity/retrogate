import Foundation
import SwiftSoup

/// Produces a plain-text representation of an HTML document for FTS5 indexing.
///
/// The output is deliberately lossy: we don't care about structure, only
/// about words a human might search for. Scripts, styles, and markup are
/// dropped; entities are decoded; whitespace is collapsed.
public enum HTMLPlainifier {
    /// Hard upper bound on indexed size per document. FTS5 with the `porter`
    /// tokenizer doesn't enforce a limit, but very long documents bloat the
    /// index and slow searches. 256 KB of text (~50k words) is plenty.
    public static let maxCharacters = 256 * 1024

    /// Decode HTML bytes → plain text. Tries iso-8859-1 first (matches the
    /// byte format our cache stores), then utf-8, then mac-roman.
    /// Returns an empty string on unrecoverable failure.
    public static func plainify(data: Data) -> String {
        let html = decode(data)
        guard !html.isEmpty else { return "" }
        return plainify(html: html)
    }

    /// Decode an HTML string → plain text.
    public static func plainify(html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        // Remove noisy elements before asking for .text() — otherwise we'd
        // index JavaScript bodies and CSS rules as "content".
        _ = try? doc.select("script, style, noscript, template").remove()
        let text = (try? doc.text()) ?? ""
        let normalized = collapseWhitespace(text)
        if normalized.count <= maxCharacters { return normalized }
        return String(normalized.prefix(maxCharacters))
    }

    // MARK: - Helpers

    private static func decode(_ data: Data) -> String {
        if let s = String(data: data, encoding: .isoLatin1), !s.isEmpty { return s }
        if let s = String(data: data, encoding: .utf8), !s.isEmpty { return s }
        if let s = String(data: data, encoding: .macOSRoman), !s.isEmpty { return s }
        return ""
    }

    /// Collapse runs of whitespace (including newlines and tabs) to single spaces.
    /// Keeps word boundaries intact but throws away layout noise that would
    /// otherwise make snippets unreadable.
    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        var lastWasSpace = false
        for ch in s.unicodeScalars {
            if ch == " " || ch == "\n" || ch == "\r" || ch == "\t" {
                if !lastWasSpace && !out.isEmpty {
                    out.append(" ")
                    lastWasSpace = true
                }
            } else {
                out.append(Character(ch))
                lastWasSpace = false
            }
        }
        if out.hasSuffix(" ") { out.removeLast() }
        return out
    }
}
