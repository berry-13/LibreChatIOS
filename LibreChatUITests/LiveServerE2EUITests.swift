import XCTest

/// End-to-end smoke test against a live LibreChat backend.
///
/// Requires a local stack before launching:
/// - LibreChat API on `http://localhost:3080` with email login enabled
///   (`ALLOW_UNVERIFIED_EMAIL_LOGIN=true`) and a streaming custom endpoint.
/// - The credentials below must already exist (seeded once via the API).
/// - At least one conversation on the account so the sidebar has content.
///
/// The test exercises the real network stack: server setup, login, streaming
/// generation, cold-start persistence, and the sidebar conversation list.
/// Login credentials and the composer draft are seeded through the launch
/// environment (DEBUG-only hooks) because synthesized hardware-keyboard
/// focus is unreliable on headless simulator clones.
@MainActor
final class LiveServerE2EUITests: XCTestCase {
    private static let serverAddress = "http://localhost:3080"
    private static let email = "e2e@test.local"
    private static let password = "Test-Passw0rd!123"
    private static let draft = "Live E2E: please stream a reply."

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitExists(_ element: XCUIElement, _ timeout: TimeInterval, _ message: String) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message)
    }

    func testLoginStreamPersistAndSidebar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["E2E_SERVER"] = Self.serverAddress
        app.launchEnvironment["E2E_EMAIL"] = Self.email
        app.launchEnvironment["E2E_PASSWORD"] = Self.password
        app.launchEnvironment["E2E_DRAFT"] = Self.draft
        app.launch()

        // A fresh install opens on server setup (address prefilled via the
        // launch environment); a valid prior session opens straight onto the
        // signed-in shell.
        let connect = element("connect-server", in: app)
        if connect.waitForExistence(timeout: 4) {
            connect.tap()
        }

        let signIn = element("sign-in", in: app)
        if signIn.waitForExistence(timeout: 15) {
            let enabled = NSPredicate { candidate, _ in
                (candidate as? XCUIElement)?.isEnabled == true
            }
            XCTAssertEqual(
                XCTWaiter.wait(
                    for: [XCTNSPredicateExpectation(predicate: enabled, object: signIn)],
                    timeout: 8
                ),
                .completed,
                "Sign-in button never enabled; seeded credentials missing."
            )
            signIn.tap()
        }

        // Accessibility snapshots on loaded hosts can lag well behind the UI.
        // Relaunch a few times: every launch after the first restores the
        // session directly, so later attempts are progressively warmer.
        var signedIn = element("signed-in-root", in: app).waitForExistence(timeout: 20)
        for _ in 0..<2 where !signedIn {
            app.terminate()
            app.launch()
            signedIn = element("signed-in-root", in: app).waitForExistence(timeout: 20)
        }
        XCTAssertTrue(
            signedIn,
            "Signed-in root never appeared (login or restore failed)."
        )

        // The new-chat canvas is mounted behind the sidebar by default, but a
        // freshly signed-in session can legitimately land on the placeholder
        // until the conversation list syncs — route through the sidebar then.
        let draft = element("composer-draft", in: app)
        if !draft.waitForExistence(timeout: 2) {
            let placeholderSidebar = element("placeholder-open-sidebar", in: app)
            XCTAssertTrue(
                placeholderSidebar.waitForExistence(timeout: 20),
                "Neither the composer nor the placeholder sidebar opener appeared."
            )
            placeholderSidebar.tap()
            let newChat = element("new-chat-button", in: app)
            XCTAssertTrue(
                newChat.waitForExistence(timeout: 20),
                "Sidebar new-chat button missing after opening the sidebar."
            )
            newChat.tap()
        }
        waitExists(draft, 25, "Composer draft field missing after starting a new chat.")

        let send = element("composer-send", in: app)
        waitExists(send, 4, "Send button missing.")
        // Programmatic draft seeding never refreshes the TextField's
        // accessibility value, so a value-based wait is unreliable. Give the
        // canvas a moment to settle, then send; the streaming assertion below
        // is the real judge of whether the send fired.
        Thread.sleep(forTimeInterval: 2)
        send.tap()

        // The mock provider streams a recognizable reply prefix. The host
        // running these tests can be heavily loaded and accessibility
        // snapshots get slow, so use a generous window and keep evidence.
        let beforeSend = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        beforeSend.name = "after-send-tap"
        beforeSend.lifetime = .keepAlways
        add(beforeSend)
        let streamed = NSPredicate(format: "label CONTAINS 'streamed reply'")
        let streamResult = XCTWaiter.wait(
            for: [XCTNSPredicateExpectation(predicate: streamed, object: app)],
            timeout: 120
        )
        let afterStream = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        afterStream.name = "after-stream-window"
        afterStream.lifetime = .keepAlways
        add(afterStream)
        XCTAssertEqual(
            streamResult, .completed,
            "Streamed assistant reply never appeared in the chat surface."
        )

        // Cold-start persistence: session and conversation must survive relaunch.
        app.terminate()
        app.launch()
        waitExists(
            element("signed-in-root", in: app),
            25,
            "Session did not survive a cold start."
        )

        // Sidebar: seeded live-server conversations must be listed.
        Thread.sleep(forTimeInterval: 1.5)
        let sidebarOpener = element("open-sidebar-button", in: app)
        waitExists(sidebarOpener, 6, "Sidebar opener missing on the chat top bar.")
        sidebarOpener.tap()
        waitExists(element("sidebar-panel", in: app), 6, "Sidebar panel missing.")
        waitExists(
            element("conversation-search-field", in: app),
            6,
            "Conversation search field missing in sidebar."
        )
        let conversationRows = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'conversation-'")).count
        XCTAssertGreaterThan(
            conversationRows, 0,
            "Sidebar should list conversations from the live server."
        )
    }
}
