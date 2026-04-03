import XCTest
@testable import HTMLTranscoder
@testable import WaybackBridge

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

final class WaybackBridgeTests: XCTestCase {
    
    func testURLRewriting() {
        var bridge = WaybackBridge()
        // Set to a known date
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        bridge.targetDate = formatter.date(from: "1997-06-15")!
        
        let original = URL(string: "http://apple.com")!
        let rewritten = bridge.rewriteURL(original)
        
        XCTAssertEqual(rewritten.absoluteString, "https://web.archive.org/web/19970615/http://apple.com")
    }
    
    func testIsWaybackURL() {
        let bridge = WaybackBridge()
        XCTAssertTrue(bridge.isWaybackURL(URL(string: "https://web.archive.org/web/2001/http://example.com")!))
        XCTAssertFalse(bridge.isWaybackURL(URL(string: "http://example.com")!))
    }
}
