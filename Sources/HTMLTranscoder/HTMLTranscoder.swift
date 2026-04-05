import SwiftSoup
import Logging
import Foundation

/// Transcodes modern HTML5/CSS3 pages into HTML 3.2 compatible markup
/// that vintage browsers (Netscape 2-4, IE 3-5 Mac, MacWeb) can render.
public struct HTMLTranscoder {
    
    public enum Level: Sendable {
        /// Just fix encoding, pass through mostly unchanged
        case minimal
        /// Remove scripts, simplify CSS, keep structure
        case moderate
        /// Full downgrade to HTML 3.2 with table layouts and inline attributes
        case aggressive
    }
    
    private let level: Level
    private let maxImageWidth: Int
    private let logger: Logger
    
    public init(level: Level = .aggressive, maxImageWidth: Int = 640) {
        self.level = level
        self.maxImageWidth = maxImageWidth
        var logger = Logger(label: "app.retrogate.transcoder")
        logger.logLevel = .info
        self.logger = logger
    }
    
    /// Transcode an HTML string to vintage-compatible HTML.
    public func transcode(_ html: String, baseURL: URL) throws -> String {
        let doc = try SwiftSoup.parse(html, baseURL.absoluteString)
        
        // These run for ALL levels — charset and image URLs must always be fixed
        // for vintage browsers to work at all
        try extractJSRedirects(doc)
        try stripScripts(doc)
        try setCharsetMeta(doc)
        try rewriteImageSources(doc, baseURL: baseURL)

        switch level {
        case .minimal:
            // Inject vendor prefixes into <style> blocks for medium-vintage browsers
            try injectVendorPrefixes(doc)
        case .moderate:
            try simplifyCSS(doc)
            try downgradeSemanticTags(doc)
        case .aggressive:
            try simplifyCSS(doc)
            try downgradeSemanticTags(doc)
            try convertToTableLayout(doc)
            try inlineStyles(doc)
        }
        
        return try doc.outerHtml()
    }
    
    // MARK: - Transformation Steps

    /// Detect JavaScript redirects (window.location = "url") BEFORE stripping scripts,
    /// and convert them to <meta http-equiv="refresh"> which vintage browsers support.
    /// Without this, pages that redirect via JS show up blank after script stripping.
    private func extractJSRedirects(_ doc: Document) throws {
        let patterns = [
            #"window\.location\s*=\s*['"](https?://[^'"]+)['"]"#,
            #"window\.location\.href\s*=\s*['"](https?://[^'"]+)['"]"#,
            #"window\.location\.replace\(\s*['"](https?://[^'"]+)['"]\s*\)"#,
            #"document\.location\s*=\s*['"](https?://[^'"]+)['"]"#,
            #"document\.location\.href\s*=\s*['"](https?://[^'"]+)['"]"#,
        ]
        for script in try doc.select("script") {
            let text = try script.html()
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let urlRange = Range(match.range(at: 1), in: text) else { continue }
                let redirectURL = String(text[urlRange])
                // Inject a meta refresh that vintage browsers will follow
                if let head = doc.head() {
                    try head.append("<meta http-equiv=\"refresh\" content=\"0;url=\(redirectURL)\">")
                }
                logger.debug("Extracted JS redirect to \(redirectURL)")
                return // Only use the first redirect found
            }
        }
    }

    /// Remove dangerous/unsupported elements.
    /// We keep <embed> and <object> because they were used for QuickTime movies
    /// in the 90s — Mac OS 9 can actually play those through the proxy.
    /// <applet> (Java) is stripped because it crashes SheepShaver's MRJ.
    private func stripScripts(_ doc: Document) throws {
        // Unwrap <noscript> tags BEFORE removing scripts — modern sites hide
        // real <img> tags inside <noscript> as lazy-loading fallbacks.
        // Since we strip all <script>, the noscript content is what we need.
        for noscript in try doc.select("noscript") {
            if let parent = noscript.parent() {
                try noscript.unwrap()
                _ = parent
            }
        }

        let tagsToRemove = ["script", "canvas", "video", "audio",
                            "svg", "template", "slot", "dialog", "details",
                            "summary", "picture", "source",
                            "applet"]
        for tag in tagsToRemove {
            try doc.select(tag).remove()
        }
        for element in try doc.select("[onclick], [onload], [onerror], [onmouseover]") {
            try element.removeAttr("onclick")
            try element.removeAttr("onload")
            try element.removeAttr("onerror")
            try element.removeAttr("onmouseover")
        }

        // Strip CSP meta tags, SRI integrity attributes, and CORS attributes
        try doc.select("meta[http-equiv=Content-Security-Policy]").remove()
        for el in try doc.select("[integrity]") { try el.removeAttr("integrity") }
        for el in try doc.select("[crossorigin]") { try el.removeAttr("crossorigin") }

        logger.debug("Stripped scripts and modern elements")
    }
    
    /// Remove <style> blocks and style attributes, keep basic formatting
    private func simplifyCSS(_ doc: Document) throws {
        try doc.select("style").remove()
        try doc.select("link[rel=stylesheet]").remove()
        logger.debug("Removed CSS stylesheets")
    }
    
    /// Convert HTML5 semantic tags to divs/tables and HTML4 tags to HTML 3.2
    private func downgradeSemanticTags(_ doc: Document) throws {
        let semanticTags = ["nav", "section", "article", "aside", "header",
                            "footer", "main", "figure", "figcaption", "mark",
                            "time", "output", "progress", "meter"]
        for tag in semanticTags {
            for element in try doc.select(tag) {
                try element.tagName("div")
            }
        }
        for el in try doc.select("strong") { try el.tagName("b") }
        for el in try doc.select("em") { try el.tagName("i") }
        logger.debug("Downgraded semantic HTML5 tags to divs")
    }
    
    /// Convert common layout patterns to table-based layouts.
    private func convertToTableLayout(_ doc: Document) throws {
        for ul in try doc.select("ul") {
            let items = ul.children().filter { $0.tagName() == "li" }
            guard items.count > 1, items.count <= 12 else { continue }
            let allLinks = items.allSatisfy { (try? $0.select("> a").first()) != nil }
            guard allLinks else { continue }

            let cellsHTML = try items.map { try $0.html() }.joined(separator: "</td><td>")
            try ul.tagName("table")
            try ul.html("<tr><td>\(cellsHTML)</td></tr>")
            try ul.attr("cellpadding", "4")
            try ul.attr("cellspacing", "0")
            try ul.attr("border", "0")
        }

        if let body = doc.body() {
            let divChildren = body.children().filter { $0.tagName() == "div" }
            guard divChildren.count >= 3 else { return }

            let rowsHTML = try divChildren.map { div -> String in
                let html = try div.outerHtml()
                return "<tr><td>\(html)</td></tr>"
            }
            let table = """
            <table width="100%" border="0" cellpadding="4" cellspacing="0">\(rowsHTML.joined())</table>
            """
            for div in divChildren { try div.remove() }
            try body.prepend(table)
        }

        logger.debug("Converted layout patterns to tables")
    }
    
    /// Convert CSS properties to HTML 3.2 attributes (bgcolor, align, width, etc.)
    private func inlineStyles(_ doc: Document) throws {
        for element in try doc.select("[style]") {
            let style = try element.attr("style")
            let props = Self.parseInlineStyle(style)

            if let align = props["text-align"] {
                try element.attr("align", align)
            }
            if let bg = props["background-color"] {
                try element.attr("bgcolor", Self.normalizeColor(bg))
            }
            if let color = props["color"] {
                let inner = try element.html()
                try element.html("<font color=\"\(Self.normalizeColor(color))\">\(inner)</font>")
            }
            if let width = props["width"] {
                try element.attr("width", width.replacingOccurrences(of: "px", with: ""))
            }
            if let height = props["height"] {
                try element.attr("height", height.replacingOccurrences(of: "px", with: ""))
            }
            if let fontSize = props["font-size"] {
                let size = Self.mapFontSize(fontSize)
                let inner = try element.html()
                try element.html("<font size=\"\(size)\">\(inner)</font>")
            }
            if let weight = props["font-weight"], weight == "bold" || weight == "700" {
                let inner = try element.html()
                try element.html("<b>\(inner)</b>")
            }
            try element.removeAttr("style")
        }
        logger.debug("Converted inline styles to HTML 3.2 attributes")
    }

    /// Inject vendor prefixes into <style> blocks (minimal mode only).
    private func injectVendorPrefixes(_ doc: Document) throws {
        for style in try doc.select("style") {
            let css = try style.html()
            let prefixed = Self.prefixCSS(css)
            try style.html(prefixed)
        }
    }

    // MARK: - Style Parsing Helpers

    /// Parse a CSS inline style string into a property dictionary.
    static func parseInlineStyle(_ style: String) -> [String: String] {
        var props: [String: String] = [:]
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            props[key] = value
        }
        return props
    }

    /// Normalize a CSS color value to a hex string for HTML attributes.
    static func normalizeColor(_ css: String) -> String {
        let trimmed = css.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("#") {
            if trimmed.count == 4 {
                let chars = Array(trimmed.dropFirst())
                return "#\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
            }
            return trimmed
        }
        if trimmed.hasPrefix("rgb("), trimmed.hasSuffix(")") {
            let inner = trimmed.dropFirst(4).dropLast()
            let components = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if components.count == 3 {
                return String(format: "#%02x%02x%02x", components[0], components[1], components[2])
            }
        }
        let named: [String: String] = [
            "black": "#000000", "white": "#ffffff", "red": "#ff0000",
            "green": "#008000", "blue": "#0000ff", "yellow": "#ffff00",
            "cyan": "#00ffff", "magenta": "#ff00ff", "gray": "#808080",
            "grey": "#808080", "silver": "#c0c0c0", "navy": "#000080",
            "teal": "#008080", "maroon": "#800000", "olive": "#808000",
            "purple": "#800080", "orange": "#ffa500",
        ]
        return named[trimmed] ?? trimmed
    }

    /// Map a CSS font-size value to an HTML 3.2 font size (1–7).
    static func mapFontSize(_ css: String) -> String {
        let trimmed = css.trimmingCharacters(in: .whitespaces).lowercased()
        let keywords: [String: String] = [
            "xx-small": "1", "x-small": "1", "small": "2", "medium": "3",
            "large": "4", "x-large": "5", "xx-large": "6",
        ]
        if let mapped = keywords[trimmed] { return mapped }
        let numericString = trimmed
            .replacingOccurrences(of: "px", with: "")
            .replacingOccurrences(of: "pt", with: "")
            .replacingOccurrences(of: "em", with: "")
            .replacingOccurrences(of: "rem", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(numericString) else { return "3" }
        if trimmed.contains("em") || trimmed.contains("rem") {
            if value < 0.7 { return "1" }
            if value < 0.85 { return "2" }
            if value < 1.1 { return "3" }
            if value < 1.3 { return "4" }
            if value < 1.6 { return "5" }
            if value < 2.0 { return "6" }
            return "7"
        }
        if value < 10 { return "1" }
        if value < 13 { return "2" }
        if value < 16 { return "3" }
        if value < 19 { return "4" }
        if value < 24 { return "5" }
        if value < 32 { return "6" }
        return "7"
    }
    
    /// Rewrite image src URLs to go through the proxy's image transcoder
    private func rewriteImageSources(_ doc: Document, baseURL: URL) throws {
        for img in try doc.select("img") {
            if let src = try? img.attr("src"), !src.isEmpty {
                let resolved = URL(string: src, relativeTo: baseURL)?.absoluteString ?? src
                try img.attr("src", resolved)
                if let w = try? Int(img.attr("width")), w > maxImageWidth {
                    let ratio = Double(maxImageWidth) / Double(w)
                    if let h = try? Int(img.attr("height")) {
                        try img.attr("height", "\(Int(Double(h) * ratio))")
                    }
                    try img.attr("width", "\(maxImageWidth)")
                }
                try img.removeAttr("srcset")
                try img.removeAttr("loading")
            }
        }
        logger.debug("Rewrote image sources")
    }
    
    /// Set charset meta for iso-8859-1 (most vintage Mac browsers prefer this)
    private func setCharsetMeta(_ doc: Document) throws {
        try doc.select("meta[charset]").remove()
        try doc.select("meta[http-equiv=Content-Type]").remove()
        if let head = doc.head() {
            try head.prepend("""
                <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">
            """)
        }
    }

    // MARK: - CSS Vendor Prefix Injection

    /// Properties that need vendor prefixes, with their prefix mappings.
    /// Ordered longest-first so `transform-origin` is processed before `transform`.
    private static let prefixRules: [(property: String, prefixes: [String])] = [
        ("border-radius",    ["-webkit-border-radius", "-moz-border-radius"]),
        ("box-shadow",       ["-webkit-box-shadow", "-moz-box-shadow"]),
        ("transform-origin", ["-webkit-transform-origin", "-moz-transform-origin", "-ms-transform-origin"]),
        ("transition",       ["-webkit-transition", "-moz-transition", "-o-transition"]),
        ("transform",        ["-webkit-transform", "-moz-transform", "-ms-transform"]),
        ("animation",        ["-webkit-animation", "-moz-animation"]),
        ("user-select",      ["-webkit-user-select", "-moz-user-select", "-ms-user-select"]),
        ("opacity",          ["-moz-opacity"]),
    ]

    /// Add vendor prefixes (-webkit-, -moz-, -ms-) for older browsers.
    /// Works at the CSS declaration level: finds unprefixed property declarations
    /// and inserts vendor-prefixed copies before them.
    ///
    /// Rules:
    /// - Only prefixes UNPREFIXED properties (skips `-webkit-transform` etc.)
    /// - Handles `transform` vs `transform-origin` independently
    /// - Preserves the original unprefixed declaration
    public static func prefixCSS(_ css: String) -> String {
        var result = css

        for rule in prefixRules {
            // Build regex: match the property name NOT preceded by - or word char.
            // For "transform", also add negative lookahead to avoid "transform-origin".
            let escaped = NSRegularExpression.escapedPattern(for: rule.property)
            let pattern: String
            if rule.property == "transform" {
                // Match "transform" but NOT "transform-origin", "transform-style" etc.
                pattern = "(?<![-\\w])\(escaped)(?![-\\w])\\s*:"
            } else {
                pattern = "(?<![-\\w])\(escaped)\\s*:"
            }

            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }

            // Process matches in reverse order to preserve string indices
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: result) else { continue }
                // Find the semicolon that ends this declaration
                let afterMatch = result[matchRange.lowerBound...]
                guard let semiIndex = afterMatch.firstIndex(of: ";") else { continue }
                // Extract the value (everything between ":" and ";")
                let value = String(result[matchRange.upperBound...semiIndex])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
                    .trimmingCharacters(in: .whitespaces)

                // Build prefixed declarations to insert before the original
                var prefixed = ""
                for prefix in rule.prefixes {
                    prefixed += " \(prefix): \(value);"
                }

                // Insert prefixed declarations before the original declaration
                result.replaceSubrange(matchRange.lowerBound..<matchRange.lowerBound, with: prefixed)
            }
        }

        return result
    }
}

