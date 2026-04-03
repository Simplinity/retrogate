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
    
    /// Convert flexbox/grid layouts to table-based layouts
    private func convertToTableLayout(_ doc: Document) throws {
        // TODO: Detect flex/grid containers and convert to <table> structures
        // This is the most complex transformation and will need heuristics
        logger.debug("Table layout conversion (TODO)")
    }
    
    /// Convert CSS properties to HTML 3.2 attributes (bgcolor, align, width, etc.)
    private func inlineStyles(_ doc: Document) throws {
        // TODO: Parse inline style="" and convert to attributes
        // e.g., style="text-align: center" → align="center"
        // e.g., style="background-color: #fff" → bgcolor="#FFFFFF"
        // e.g., style="width: 100%" → width="100%"
        logger.debug("Inline style conversion (TODO)")
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
