import Foundation
import Testing
@testable import Ghostty

struct BrowserSplitModelTests {
    @Test(arguments: [
        ("https://ghostty.org", "https://ghostty.org"),
        ("ghostty.org", "https://ghostty.org"),
        ("localhost:8080/docs", "https://localhost:8080/docs"),
        ("data:text/html,Hello", "data:text/html,Hello"),
        ("file:///tmp/browser-split.html", "file:///tmp/browser-split.html"),
    ])
    func resolvesSupportedLocations(input: String, expected: String) {
        #expect(BrowserSplitModel.resolvedURL(from: input)?.absoluteString == expected)
    }

    @Test
    func resolvesAbsolutePathsToFileURLs() {
        let path = "/tmp/browser-split.html"
        #expect(BrowserSplitModel.resolvedURL(from: path) == URL(fileURLWithPath: path))
    }

    @Test(arguments: [
        "",
        "   ",
        "not a url",
        "two words.example",
    ])
    func rejectsInvalidLocations(input: String) {
        #expect(BrowserSplitModel.resolvedURL(from: input) == nil)
    }
}
