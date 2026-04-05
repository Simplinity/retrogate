import XCTest
#if canImport(HTMLTranscoder)
@testable import HTMLTranscoder
#endif
#if canImport(ImageTranscoder)
@testable import ImageTranscoder
#endif
#if canImport(WaybackBridge)
@testable import WaybackBridge
#endif

final class HTMLTranscoderTests: XCTestCase {
    
    func testStripScripts() throws {
        let html = """
        <html><body>
        <h1>Hello</h1>
        <script>alert('evil')</script>
        <p>World</p>
        <canvas></canvas>
        </body></html>
        """
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)
        
        XCTAssertFalse(result.contains("<script"))
        XCTAssertFalse(result.contains("<canvas"))
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
    }
    
    func testDowngradeSemanticTags() throws {
        let html = """
        <html><body>
        <nav>Navigation</nav>
        <article><section>Content</section></article>
        <footer>Footer</footer>
        </body></html>
        """
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)
        
        XCTAssertFalse(result.contains("<nav"))
        XCTAssertFalse(result.contains("<article"))
        XCTAssertFalse(result.contains("<section"))
        XCTAssertFalse(result.contains("<footer"))
        XCTAssertTrue(result.contains("Navigation"))
    }
    
    func testCharsetMeta() throws {
        let html = "<html><head><meta charset=\"utf-8\"></head><body>Test</body></html>"
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)

        XCTAssertTrue(result.contains("iso-8859-1"))
        XCTAssertFalse(result.contains("charset=\"utf-8\""))
    }

    func testInlineStyleTextAlign() throws {
        let html = """
        <html><body><div style="text-align: center">Centered</div></body></html>
        """
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)

        XCTAssertTrue(result.contains("align=\"center\""))
        XCTAssertFalse(result.contains("style="))
    }

    func testInlineStyleBgColor() throws {
        let html = """
        <html><body><div style="background-color: #ff0000">Red</div></body></html>
        """
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)

        XCTAssertTrue(result.contains("bgcolor=\"#ff0000\""))
    }

    func testInlineStyleFontColor() throws {
        let html = """
        <html><body><p style="color: blue">Blue text</p></body></html>
        """
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)

        XCTAssertTrue(result.contains("<font color=\"#0000ff\">"))
    }

    func testNormalizeColorRGB() {
        XCTAssertEqual(HTMLTranscoder.normalizeColor("rgb(255, 0, 128)"), "#ff0080")
    }

    func testNormalizeColorShortHex() {
        XCTAssertEqual(HTMLTranscoder.normalizeColor("#abc"), "#aabbcc")
    }

    func testNormalizeColorNamed() {
        XCTAssertEqual(HTMLTranscoder.normalizeColor("red"), "#ff0000")
        XCTAssertEqual(HTMLTranscoder.normalizeColor("navy"), "#000080")
    }

    func testMapFontSizeKeywords() {
        XCTAssertEqual(HTMLTranscoder.mapFontSize("small"), "2")
        XCTAssertEqual(HTMLTranscoder.mapFontSize("medium"), "3")
        XCTAssertEqual(HTMLTranscoder.mapFontSize("x-large"), "5")
    }

    func testMapFontSizePixels() {
        XCTAssertEqual(HTMLTranscoder.mapFontSize("12px"), "2")
        XCTAssertEqual(HTMLTranscoder.mapFontSize("15px"), "3")
        XCTAssertEqual(HTMLTranscoder.mapFontSize("20px"), "5")
        XCTAssertEqual(HTMLTranscoder.mapFontSize("48px"), "7")
    }

    func testConvertNavToTable() throws {
        let html = """
        <html><body>
        <ul><li><a href="/">Home</a></li><li><a href="/about">About</a></li><li><a href="/contact">Contact</a></li></ul>
        </body></html>
        """
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)

        XCTAssertTrue(result.contains("<table"))
        XCTAssertTrue(result.contains("<tr>"))
        XCTAssertTrue(result.contains("<td>"))
        XCTAssertFalse(result.contains("<ul"))
        XCTAssertTrue(result.contains("Home"))
        XCTAssertTrue(result.contains("About"))
    }

    func testParseInlineStyle() {
        let props = HTMLTranscoder.parseInlineStyle("text-align: center; color: red; width: 100px")
        XCTAssertEqual(props["text-align"], "center")
        XCTAssertEqual(props["color"], "red")
        XCTAssertEqual(props["width"], "100px")
    }

    func testVendorPrefixInjection() {
        let css = "div { border-radius: 10px; box-shadow: 0 2px 4px #000; }"
        let result = HTMLTranscoder.prefixCSS(css)

        XCTAssertTrue(result.contains("-webkit-border-radius: 10px;"))
        XCTAssertTrue(result.contains("-moz-border-radius: 10px;"))
        XCTAssertTrue(result.contains("-webkit-box-shadow: 0 2px 4px #000;"))
        XCTAssertTrue(result.contains("-moz-box-shadow: 0 2px 4px #000;"))
        // Original unprefixed properties preserved
        XCTAssertTrue(result.contains("border-radius: 10px;"))
        XCTAssertTrue(result.contains("box-shadow: 0 2px 4px #000;"))
    }

    func testVendorPrefixSkipsAlreadyPrefixed() {
        let css = "-webkit-transform: rotate(45deg); transform: rotate(45deg);"
        let result = HTMLTranscoder.prefixCSS(css)

        // Should not double-prefix: -webkit-transform should appear only from the original
        let webkitCount = result.components(separatedBy: "-webkit-transform").count - 1
        // Original -webkit- (1) + injected -webkit- before unprefixed transform (1) = 2
        XCTAssertEqual(webkitCount, 2)
        // -moz- and -ms- should be injected for the unprefixed transform
        XCTAssertTrue(result.contains("-moz-transform: rotate(45deg);"))
        XCTAssertTrue(result.contains("-ms-transform: rotate(45deg);"))
    }

    func testVendorPrefixMinimalLevelOnly() throws {
        let html = """
        <html><head><style>div { border-radius: 5px; }</style></head><body><div>Test</div></body></html>
        """
        // Minimal level: vendor prefixes injected
        let minimal = HTMLTranscoder(level: .minimal)
        let minResult = try minimal.transcode(html, baseURL: URL(string: "http://example.com")!)
        XCTAssertTrue(minResult.contains("-webkit-border-radius"))

        // Moderate level: CSS stripped entirely, no prefixes
        let moderate = HTMLTranscoder(level: .moderate)
        let modResult = try moderate.transcode(html, baseURL: URL(string: "http://example.com")!)
        XCTAssertFalse(modResult.contains("-webkit-border-radius"))
        XCTAssertFalse(modResult.contains("border-radius"))
    }

    func testVendorPrefixTransformVsTransformOrigin() {
        let css = "transform-origin: center; transform: rotate(45deg);"
        let result = HTMLTranscoder.prefixCSS(css)

        XCTAssertTrue(result.contains("-webkit-transform-origin: center;"))
        XCTAssertTrue(result.contains("-webkit-transform: rotate(45deg);"))
        // Verify transform-origin prefix didn't corrupt transform
        XCTAssertFalse(result.contains("-webkit-transform-origin: rotate"))
    }

    func testISO8859Encoding() throws {
        // Characters outside iso-8859-1 should be lossy-converted (not crash)
        let html = "<html><body><p>Hello \u{1F600} World \u{2603}</p></body></html>"
        let transcoder = HTMLTranscoder(level: .aggressive)
        let result = try transcoder.transcode(html, baseURL: URL(string: "http://example.com")!)

        // The transcoder produces a String; encoding to iso-8859-1 happens in ProxyHandler.
        // Verify the transcoder doesn't crash on emoji/unicode input.
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))

        // Verify lossy encoding works
        let data = result.data(using: .isoLatin1, allowLossyConversion: true)
        XCTAssertNotNil(data)
    }
}

final class ImageTranscoderTests: XCTestCase {

    func testDetectFormatJPEG() {
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        XCTAssertEqual(ImageTranscoder.detectFormat(jpegData), .jpeg)
        XCTAssertEqual(ImageTranscoder.mimeType(for: jpegData), "image/jpeg")
    }

    func testDetectFormatGIF() {
        let gifData = Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])
        XCTAssertEqual(ImageTranscoder.detectFormat(gifData), .gif)
        XCTAssertEqual(ImageTranscoder.mimeType(for: gifData), "image/gif")
    }

    func testDetectFormatPNG() {
        let pngData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        XCTAssertEqual(ImageTranscoder.detectFormat(pngData), .png)
        XCTAssertEqual(ImageTranscoder.mimeType(for: pngData), "image/png")
    }

    func testNeedsTranscodingPassThrough() {
        let transcoder = ImageTranscoder(outputFormat: .jpeg(quality: 0.6))
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let gifData = Data([0x47, 0x49, 0x46, 0x38])

        // JPEG and GIF should pass through without forced format
        XCTAssertFalse(transcoder.needsTranscoding(jpegData))
        XCTAssertFalse(transcoder.needsTranscoding(gifData))

        // PNG should be transcoded
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])
        XCTAssertTrue(transcoder.needsTranscoding(pngData))
    }

    func testNeedsTranscodingForceFormat() {
        // GIF transcoder should force-transcode a JPEG
        let gifTranscoder = ImageTranscoder(outputFormat: .gif)
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertTrue(gifTranscoder.needsTranscoding(jpegData, forceFormat: true))

        // But not a GIF
        let gifData = Data([0x47, 0x49, 0x46, 0x38])
        XCTAssertFalse(gifTranscoder.needsTranscoding(gifData, forceFormat: true))
    }

    func testNeedsTranscodingColorDepthModes() {
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let gifData = Data([0x47, 0x49, 0x46, 0x38])

        // Monochrome, 16-color, and Thousands always need transcoding
        let monoTranscoder = ImageTranscoder(colorDepth: .monochrome)
        XCTAssertTrue(monoTranscoder.needsTranscoding(jpegData))
        XCTAssertTrue(monoTranscoder.needsTranscoding(gifData))

        let sixteenTranscoder = ImageTranscoder(colorDepth: .sixteenColor)
        XCTAssertTrue(sixteenTranscoder.needsTranscoding(jpegData))

        let thousandsTranscoder = ImageTranscoder(colorDepth: .thousands)
        XCTAssertTrue(thousandsTranscoder.needsTranscoding(jpegData))
        XCTAssertTrue(thousandsTranscoder.needsTranscoding(gifData))

        // 256-color only needs transcoding if not already GIF
        let twoFiftySixTranscoder = ImageTranscoder(colorDepth: .twoFiftySix)
        XCTAssertTrue(twoFiftySixTranscoder.needsTranscoding(jpegData))
        XCTAssertFalse(twoFiftySixTranscoder.needsTranscoding(gifData))

        // Millions passes through JPEG and GIF (same as old default behavior)
        let millionsTranscoder = ImageTranscoder(colorDepth: .millions)
        XCTAssertFalse(millionsTranscoder.needsTranscoding(jpegData))
        XCTAssertFalse(millionsTranscoder.needsTranscoding(gifData))
    }

    func testColorDepthRawValues() {
        // Verify raw values match what config.json stores
        XCTAssertEqual(ColorDepth.monochrome.rawValue, "monochrome")
        XCTAssertEqual(ColorDepth.sixteenColor.rawValue, "16color")
        XCTAssertEqual(ColorDepth.twoFiftySix.rawValue, "256color")
        XCTAssertEqual(ColorDepth.thousands.rawValue, "16bit")
        XCTAssertEqual(ColorDepth.millions.rawValue, "millions")

        // Verify display names match classic Mac OS terminology
        XCTAssertEqual(ColorDepth.thousands.displayName, "Thousands")
        XCTAssertEqual(ColorDepth.millions.displayName, "Millions")
    }
}

final class WaybackBridgeTests: XCTestCase {
    
    func testURLRewriting() {
        var bridge = WaybackBridge()
        // Set to a known date
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        bridge.targetDate = formatter.date(from: "1997-06-15")!
        
        let original = URL(string: "http://apple.com")!
        let rewritten = bridge.rewriteURL(original)
        
        // id_ suffix = identity mode (raw archived content, no URL rewriting)
        XCTAssertEqual(rewritten.absoluteString, "https://web.archive.org/web/19970615id_/http://apple.com")
    }
    
    func testIsWaybackURL() {
        let bridge = WaybackBridge()
        XCTAssertTrue(bridge.isWaybackURL(URL(string: "https://web.archive.org/web/2001/http://example.com")!))
        XCTAssertFalse(bridge.isWaybackURL(URL(string: "http://example.com")!))
    }

    func testCommentMarkerToolbarRemoval() throws {
        let html = """
        <html><body>
        <h1>Hello</h1>
        <!-- BEGIN WAYBACK TOOLBAR INSERT -->
        <div id="wm-ipp-base">Toolbar stuff here</div>
        <script>wayback_toolbar();</script>
        <!-- END WAYBACK TOOLBAR INSERT -->
        <p>Content</p>
        </body></html>
        """
        let bridge = WaybackBridge()
        let cleaned = try bridge.cleanWaybackResponse(html)
        XCTAssertFalse(cleaned.contains("Toolbar stuff"))
        XCTAssertFalse(cleaned.contains("wayback_toolbar"))
        XCTAssertTrue(cleaned.contains("Hello"))
        XCTAssertTrue(cleaned.contains("Content"))
    }
}

// MARK: - ProxyHandler Tests

#if canImport(ProxyServer)
@testable import ProxyServer
#endif

final class ProxyHandlerTests: XCTestCase {

    func testDeadEndpointRedirectDefaults() {
        // Built-in defaults should contain known dead endpoints
        XCTAssertNotNil(ProxyHTTPHandler.defaultDeadEndpoints["home.netscape.com"])
        XCTAssertNotNil(ProxyHTTPHandler.defaultDeadEndpoints["home.microsoft.com"])
        XCTAssertNotNil(ProxyHTTPHandler.defaultDeadEndpoints["www.geocities.com"])
        XCTAssertNotNil(ProxyHTTPHandler.defaultDeadEndpoints["itools.mac.com"])
        // All redirect URLs should point to archive.org
        for (_, url) in ProxyHTTPHandler.defaultDeadEndpoints {
            XCTAssertTrue(url.contains("web.archive.org"), "Dead endpoint redirect should point to archive.org: \(url)")
        }
    }

    func testHTMLMinification() {
        let html = """
        <html>
        <body>
          <!-- This is a comment -->
          <p>Hello     World</p>


          <p>Another    paragraph</p>
        </body>
        </html>
        """
        let minified = ProxyHTTPHandler.minifyHTML(html)
        // Comments should be removed
        XCTAssertFalse(minified.contains("This is a comment"))
        // Content preserved
        XCTAssertTrue(minified.contains("Hello"))
        XCTAssertTrue(minified.contains("World"))
        // Multiple spaces collapsed
        XCTAssertFalse(minified.contains("     "))
    }
}
