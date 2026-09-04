import XCTest

/// On-device probe that captures the official ChatGPT app's composer and "+"
/// menu for design-parity comparison with our composer. Screenshots are
/// written to the runner's Documents container (attachment streaming from
/// physical devices is unreliable) and pulled with devicectl.
@MainActor
final class ChatGPTComposerProbe: XCTestCase {
    private func saveScreenshot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try png.write(to: dir.appendingPathComponent(name))
        } catch {
            XCTFail("Screenshot write failed: \(error)")
        }
    }

    private func saveText(_ name: String, _ payload: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try Data(payload.utf8).write(to: dir.appendingPathComponent(name))
        } catch {
            XCTFail("Text write failed: \(error)")
        }
    }

    func testCaptureComposerAndPlusMenu() throws {
        let app = XCUIApplication(bundleIdentifier: "com.openai.chat")
        app.launch()
        sleep(8)
        saveScreenshot("cgpt-01-launch.png")
        saveText("cgpt-tree-idle.txt", app.debugDescription)

        // Focus the composer.
        var focused = false
        for candidate in [app.textFields.firstMatch, app.textViews.firstMatch] {
            if candidate.waitForExistence(timeout: 4), candidate.isHittable {
                candidate.tap()
                focused = true
                break
            }
        }
        if !focused {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94)).tap()
        }
        sleep(2)
        saveScreenshot("cgpt-02-focused.png")
        saveText("cgpt-tree-focused.txt", app.debugDescription)

        // Open the "+" menu (bottom-left of the composer, keyboard-up layout).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.084, dy: 0.585)).tap()
        sleep(2)
        saveScreenshot("cgpt-03-plus-menu.png")
        saveText("cgpt-tree-plus-menu.txt", app.debugDescription)

        // Dismiss the menu and leave the app in a sane state.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        sleep(1)
    }
}
