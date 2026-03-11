import XCTest

final class BrowserSplitUITests: GhosttyCustomConfigCase {
    @MainActor
    func testToggleBrowserSplit() throws {
        let app = try ghosttyApplication()
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 1), "Main window should exist")

        app.typeKey("b", modifierFlags: [.command, .option])

        let addressField = app.textFields["BrowserSplitAddressField"]
        XCTAssertTrue(addressField.waitForExistence(timeout: 2), "Browser address field should appear")
        XCTAssertTrue(app.buttons["Close Browser Split"].exists, "Browser split close button should appear")

        app.buttons["Close Browser Split"].click()

        let addressFieldGone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: addressField)
        XCTAssertEqual(XCTWaiter().wait(for: [addressFieldGone], timeout: 2), .completed)
    }
}
