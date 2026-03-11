import Foundation
import Testing
@testable import Ghostty

struct BrowserSplitModelTests {
    @Test(arguments: [
        ("browser_split", BrowserHostAction.open),
        ("browser_close", BrowserHostAction.close),
        ("browser_focus", BrowserHostAction.focus),
        ("browser_open_url:https://ghostty.org", BrowserHostAction.openURL("https://ghostty.org")),
    ])
    func parsesBrowserHostActions(input: String, expected: BrowserHostAction) {
        #expect(BrowserHostAction.parse(input) == expected)
    }

    @Test(arguments: [
        "",
        "search:ghostty",
        "browser_open_url",
        "browser_toggle",
    ])
    func rejectsUnknownBrowserHostActions(input: String) {
        #expect(BrowserHostAction.parse(input) == nil)
    }

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

    @Test
    func roundTripsBrowserSplitCommandRequest() throws {
        let request = BrowserSplitCommandRequest(
            terminalID: UUID().uuidString,
            close: false,
            focus: true,
            url: "https://ghostty.org")

        let parsed = try BrowserSplitCommandRequest.parse(request.serialized())
        #expect(parsed == request)
    }

    @Test
    func roundTripsBrowserSplitCommandResponse() throws {
        let response = BrowserSplitCommandResponse(
            ok: false,
            error: "missing terminal")

        let parsed = try BrowserSplitCommandResponse.parse(response.serialized())
        #expect(parsed == response)
    }

    @MainActor
    @Test
    func onlyPersistentBrowserStateTriggersImmediateInvalidation() {
        let model = BrowserSplitModel()
        var notifications = 0
        model.onRestorableStateChange = {
            notifications += 1
        }

        model.address = "ghostty.org"
        model.requestDefaultFocus()
        #expect(notifications == 0)

        model.splitRatio = 0.6
        model.splitRatio = 0.55
        #expect(notifications == 0)

        model.openLocation("about:blank")
        #expect(notifications == 1)
    }
}
