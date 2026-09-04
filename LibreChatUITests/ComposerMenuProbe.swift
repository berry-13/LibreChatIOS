import XCTest

/// Captures our composer and open "+" menu for visual comparison with the
/// official ChatGPT app. Simulator-only convenience probe.
@MainActor
final class ComposerMenuProbe: XCTestCase {
    func testCaptureOurComposerAndMenu() throws {
        let app = XCUIApplication()
        app.launchEnvironment["E2E_SERVER"] = "http://localhost:3080"
        app.launchEnvironment["E2E_EMAIL"] = "e2e@test.local"
        app.launchEnvironment["E2E_PASSWORD"] = "Test-Passw0rd!123"
        app.launchEnvironment["E2E_AUTOLOGIN"] = "1"
        app.launch()

        let root = app.descendants(matching: .any).matching(identifier: "signed-in-root").firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 30), "Signed-in root missing.")
        Thread.sleep(forTimeInterval: 2)

        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? png.write(to: dir.appendingPathComponent("ours-01-composer.png"))

        let plus = app.descendants(matching: .any).matching(identifier: "attachment-menu").firstMatch
        XCTAssertTrue(plus.waitForExistence(timeout: 10), "Attachment menu button missing.")
        plus.tap()
        Thread.sleep(forTimeInterval: 1.2)

        let open = XCUIScreen.main.screenshot().pngRepresentation
        try? open.write(to: dir.appendingPathComponent("ours-02-plus-menu.png"))

        // Close the menu.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }
}
