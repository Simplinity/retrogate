import XCTest
@testable import ProxyServer

final class CacheWarmerTests: XCTestCase {

    func testParseURLListAcceptsPlainList() {
        let input = """
        http://apple.com
        http://microsoft.com/about
        https://geocities.com/cool-page.html
        """
        let (urls, rejected) = CacheWarmer.parseURLList(input)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "http://apple.com",
            "http://microsoft.com/about",
            "https://geocities.com/cool-page.html"
        ])
        XCTAssertEqual(rejected, 0)
    }

    func testParseURLListSkipsBlankAndCommentLines() {
        let input = """
        # My favorite pages
        http://apple.com

        # mid-list comment
        http://sun.com
        """
        let (urls, _) = CacheWarmer.parseURLList(input)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0].host, "apple.com")
        XCTAssertEqual(urls[1].host, "sun.com")
    }

    func testParseURLListAddsSchemeToBareHosts() {
        let (urls, rejected) = CacheWarmer.parseURLList("apple.com\nmicrosoft.com/foo")
        XCTAssertEqual(rejected, 0)
        XCTAssertEqual(urls[0].absoluteString, "http://apple.com")
        XCTAssertEqual(urls[1].absoluteString, "http://microsoft.com/foo")
    }

    func testParseURLListRejectsGarbage() {
        let (urls, rejected) = CacheWarmer.parseURLList("http://good.com\n\thttp ://not a url\nalso:not:a:url")
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.host, "good.com")
        XCTAssertGreaterThanOrEqual(rejected, 1)
    }
}
