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
        
        switch level {
        case .minimal:
            try stripScripts(doc)
        case .moderate:
            try stripScripts(doc)
            try simplifyCSS(doc)
            try downgradeSemanticTags(doc)
        case .aggressive:
            try stripScripts(doc)
            try simplifyCSS(doc)
            try downgradeSemanticTags(doc)
            try convertToTableLayout(doc)
            try inlineStyles(doc)
            try rewriteImageSources(doc, baseURL: baseURL)
            try setCharsetMeta(doc)
        }
        
        return try doc.outerHtml()
    }
    
    // MARK: - Transformation Steps
    
    /// Remove all <script>, <noscript>, <canvas>, <video>, <audio>, <svg> tags
    private func stripScripts(_ doc: Document) throws {
        let tagsToRemove = ["script", "noscript", "canvas", "video", "audio",
                            "svg", "template", "slot", "dialog", "details",
                            "summary", "picture", "source"]
        for tag in tagsToRemove {
            try doc.select(tag).remove()
        }
        // Remove all event handler attributes
        for element in try doc.select("[onclick], [onload], [onerror], [onmouseover]") {
            try element.removeAttr("onclick")
            try element.removeAttr("onload")
            try element.removeAttr("onerror")
            try element.removeAttr("onmouseover")
        }
        logger.debug("Stripped scripts and modern elements")
    }
    
    /// Remove <style> blocks and style attributes, keep basic formatting
    private func simplifyCSS(_ doc: Document) throws {
        try doc.select("style").remove()
        try doc.select("link[rel=stylesheet]").remove()
        logger.debug("Removed CSS stylesheets")
    }
    
    /// Convert HTML5 semantic tags to divs/tables
    private func downgradeSemanticTags(_ doc: Document) throws {
        let semanticTags = ["nav", "section", "article", "aside", "header",
                            "footer", "main", "figure", "figcaption", "mark",
                            "time", "output", "progress", "meter"]
        for tag in semanticTags {
            for element in try doc.select(tag) {
                try element.tagName("div")
            }
        }
        logger.debug("Downgraded semantic HTML5 tags to divs")
    }
    
    /// Convert common layout patterns to table-based layouts.
    /// Conservative approach: only converts clear nav patterns and wraps
    /// top-level div sequences into single-column tables for structure.
    private func convertToTableLayout(_ doc: Document) throws {
        // Convert nav-like unordered lists to horizontal table rows.
        // Detects <ul> where every <li> contains a link.
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

        // Wrap body's direct div children in a single-column table for structure.
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

        // Already hex
        if trimmed.hasPrefix("#") {
            if trimmed.count == 4 {
                // #RGB → #RRGGBB
                let chars = Array(trimmed.dropFirst())
                return "#\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
            }
            return trimmed
        }

        // rgb(r, g, b)
        if trimmed.hasPrefix("rgb("), trimmed.hasSuffix(")") {
            let inner = trimmed.dropFirst(4).dropLast()
            let components = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if components.count == 3 {
                return String(format: "#%02x%02x%02x", components[0], components[1], components[2])
            }
        }

        // Named colors
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

        // Keywords
        let keywords: [String: String] = [
            "xx-small": "1", "x-small": "1", "small": "2", "medium": "3",
            "large": "4", "x-large": "5", "xx-large": "6",
        ]
        if let mapped = keywords[trimmed] { return mapped }

        // Extract numeric value (strip px, em, rem, pt)
        let numericString = trimmed
            .replacingOccurrences(of: "px", with: "")
            .replacingOccurrences(of: "pt", with: "")
            .replacingOccurrences(of: "em", with: "")
            .replacingOccurrences(of: "rem", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let value = Double(numericString) else { return "3" }

        // For px/pt-like values, map to font sizes
        if trimmed.contains("em") || trimmed.contains("rem") {
            // em/rem: 1.0 = medium (3)
            if value < 0.7 { return "1" }
            if value < 0.85 { return "2" }
            if value < 1.1 { return "3" }
            if value < 1.3 { return "4" }
            if value < 1.6 { return "5" }
            if value < 2.0 { return "6" }
            return "7"
        }

        // px/pt values
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
                // Resolve relative URLs
                let resolved = URL(string: src, relativeTo: baseURL)?.absoluteString ?? src
                // Rewrite to proxy's image endpoint with size constraint
                try img.attr("src", resolved)
                try img.attr("width", "\(maxImageWidth)")
                // Remove srcset (vintage browsers don't support it)
                try img.removeAttr("srcset")
                try img.removeAttr("loading")
            }
        }
        logger.debug("Rewrote image sources")
    }
    
    /// Set charset meta for iso-8859-1 (most vintage Mac browsers prefer this)
    private func setCharsetMeta(_ doc: Document) throws {
        // Remove existing charset/content-type metas
        try doc.select("meta[charset]").remove()
        try doc.select("meta[http-equiv=Content-Type]").remove()
        
        // Add HTML 3.2 compatible charset meta
        if let head = doc.head() {
            try head.prepend("""
                <meta http-equiv="Content-Type" content="text/html; charset=iso-8859-1">
            """)
        }
    }
}
