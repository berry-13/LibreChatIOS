import XCTest

/// Opens the seeded 5000-message stress conversation and records load time,
/// rendering, and scroll behavior for the performance pass.
@MainActor
final class StressConversationProbe: XCTestCase {
    private func saveScreenshot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? png.write(to: dir.appendingPathComponent(name))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func saveText(_ name: String, _ payload: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? Data(payload.utf8).write(to: dir.appendingPathComponent(name))
        let attachment = XCTAttachment(
            uniformTypeIdentifier: "public.plain-text",
            name: name,
            payload: Data(payload.utf8),
            userInfo: nil
        )
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testOpenStressConversation() throws {
        let app = XCUIApplication()
        app.launchEnvironment["E2E_SERVER"] = "http://localhost:3080"
        app.launchEnvironment["E2E_EMAIL"] = "e2e@test.local"
        app.launchEnvironment["E2E_PASSWORD"] = "Test-Passw0rd!123"
        app.launchEnvironment["E2E_AUTOLOGIN"] = "1"
        app.launch()

        // Relaunch retries: a later launch restores the session directly.
        var signedIn = app.descendants(matching: .any)
            .matching(identifier: "signed-in-root").firstMatch
            .waitForExistence(timeout: 30)
        for _ in 0..<2 where !signedIn {
            if app.state == .runningForeground || app.state == .runningBackground {
                app.terminate()
            }
            app.launch()
            signedIn = app.descendants(matching: .any)
                .matching(identifier: "signed-in-root").firstMatch
                .waitForExistence(timeout: 30)
        }
        XCTAssertTrue(signedIn, "Signed-in root missing.")
        Thread.sleep(forTimeInterval: 2)

        let opener = app.descendants(matching: .any).matching(identifier: "open-sidebar-button").firstMatch
        if opener.waitForExistence(timeout: 6), opener.isHittable {
            opener.tap()
        } else {
            let placeholder = app.descendants(matching: .any)
                .matching(identifier: "placeholder-open-sidebar").firstMatch
            XCTAssertTrue(placeholder.waitForExistence(timeout: 8), "No sidebar opener found.")
            placeholder.tap()
        }

        // Sidebar rows are combined-accessibility buttons; the title lives in
        // the button label rather than a standalone static text.
        let stressRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Stress test — 5000'")
        ).firstMatch
        if !stressRow.waitForExistence(timeout: 20) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "stress-sidebar-missing"
            attachment.lifetime = .keepAlways
            add(attachment)
            let rows = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH 'conversation-'"))
                .allElementsBoundByIndex.prefix(30)
            let tree = XCTAttachment(
                uniformTypeIdentifier: "public.plain-text",
                name: "stress-sidebar-rows.txt",
                payload: Data(rows.map { $0.identifier + " :: " + $0.label }.joined(separator: "\n").utf8),
                userInfo: nil
            )
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(stressRow.waitForExistence(timeout: 5), "Stress conversation row missing in sidebar.")
        stressRow.tap()

        let start = Date()
        let chat = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'chat-view-'")
        ).firstMatch
        _ = chat.waitForExistence(timeout: 60)
        let surfaced = Date().timeIntervalSince(start)

        // The newest assistant message (bottom of a 5k chain) must render.
        let lastMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Response 4999'")
        ).firstMatch
        let lastShown = lastMessage.waitForExistence(timeout: 120)
        let fullyLoaded = Date().timeIntervalSince(start)

        saveText(
            "stress-metrics.txt",
            """
            surfacedSeconds: \(String(format: "%.2f", surfaced))
            lastMessageShown: \(lastShown)
            fullLoadSeconds: \(String(format: "%.2f", fullyLoaded))
            """
        )
        saveScreenshot("stress-01-opened.png")

        // Scroll back through history a few screens.
        let scrollStart = Date()
        for _ in 0..<3 {
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.8)
        }
        saveScreenshot("stress-02-scrolled-up.png")
        let scrollUpSeconds = Date().timeIntervalSince(scrollStart)
        let returnStart = Date()
        for _ in 0..<4 {
            app.swipeUp()
        }
        Thread.sleep(forTimeInterval: 1)
        saveScreenshot("stress-03-back-to-bottom.png")
        saveText(
            "stress-metrics-scroll.txt",
            """
            scrollUpSeconds: \(String(format: "%.2f", scrollUpSeconds))
            returnToBottomSeconds: \(String(format: "%.2f", Date().timeIntervalSince(returnStart)))
            """
        )
    }

    /// Measures sustained finger-drag scrolling (not flick swipes) through the
    /// 5000-message history. These drags run long enough for an external
    /// `sample` of the app process to attribute main-thread cost during the
    /// gestures. A drag holds the scroll view in the tracking/dragging phase
    /// the whole time, so any per-frame view invalidation shows up as lag.
    func testDragScrollLag() throws {
        let app = XCUIApplication()
        app.launchEnvironment["E2E_SERVER"] = "http://localhost:3080"
        app.launchEnvironment["E2E_EMAIL"] = "e2e@test.local"
        app.launchEnvironment["E2E_PASSWORD"] = "Test-Passw0rd!123"
        app.launchEnvironment["E2E_AUTOLOGIN"] = "1"
        app.launch()

        var signedIn = app.descendants(matching: .any)
            .matching(identifier: "signed-in-root").firstMatch
            .waitForExistence(timeout: 30)
        for _ in 0..<2 where !signedIn {
            if app.state == .runningForeground || app.state == .runningBackground {
                app.terminate()
            }
            app.launch()
            signedIn = app.descendants(matching: .any)
                .matching(identifier: "signed-in-root").firstMatch
                .waitForExistence(timeout: 30)
        }
        XCTAssertTrue(signedIn, "Signed-in root missing.")
        Thread.sleep(forTimeInterval: 2)

        let opener = app.descendants(matching: .any).matching(identifier: "open-sidebar-button").firstMatch
        if opener.waitForExistence(timeout: 6), opener.isHittable {
            opener.tap()
        } else {
            let placeholder = app.descendants(matching: .any)
                .matching(identifier: "placeholder-open-sidebar").firstMatch
            XCTAssertTrue(placeholder.waitForExistence(timeout: 8), "No sidebar opener found.")
            placeholder.tap()
        }

        let stressRow = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Stress test — 5000'")
        ).firstMatch
        XCTAssertTrue(stressRow.waitForExistence(timeout: 20), "Stress conversation row missing in sidebar.")
        stressRow.tap()

        let lastMessage = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Response 4999'")
        ).firstMatch
        XCTAssertTrue(lastMessage.waitForExistence(timeout: 120), "Last message never rendered.")

        let dragUpStart = Date()
        for _ in 0..<6 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        let dragUpSeconds = Date().timeIntervalSince(dragUpStart)
        saveScreenshot("stress-drag-up.png")

        let dragDownStart = Date()
        for _ in 0..<6 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72))
            start.press(forDuration: 0.08, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        let dragDownSeconds = Date().timeIntervalSince(dragDownStart)
        saveScreenshot("stress-drag-down.png")

        saveText(
            "stress-metrics-drag.txt",
            """
            dragUpSeconds: \(String(format: "%.2f", dragUpSeconds))
            dragDownSeconds: \(String(format: "%.2f", dragDownSeconds))
            """
        )
    }
}
