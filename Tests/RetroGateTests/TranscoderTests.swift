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
