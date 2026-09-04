import XCTest

@MainActor
final class ConversationNavigationUITests: XCTestCase {
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitUntilEnabledAndHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { candidate, _ in
            guard let candidate = candidate as? XCUIElement else { return false }
            return candidate.exists && candidate.isEnabled && candidate.isHittable
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func launchFixtureApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-test-fixtures"]
        app.launch()
        XCTAssertTrue(
            app.otherElements["signed-in-root"].waitForExistence(timeout: 5),
            "The deterministic signed-in fixture root should be visible."
        )
        // Conversation rows live in the overlay drawer on iPhone.
        let sidebarOpener = app.buttons["placeholder-open-sidebar"].firstMatch
        if sidebarOpener.exists {
            sidebarOpener.tap()
        } else {
            app.buttons["open-sidebar-button"].tap()
        }
        let row = app.buttons["conversation-fixture-conversation"]
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "The drawer should reveal the conversation list."
        )
        XCTAssertTrue(
            waitUntilEnabledAndHittable(row, timeout: 5),
            "Sidebar rows must be tappable once the drawer settles."
        )
        // Let the opening spring finish so taps land on the settled layer.
        Thread.sleep(forTimeInterval: 0.6)
        return app
    }


    func testSidebarDrawerInteractionAndLayout() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()

        // The drawer is open from launchFixtureApp; the row must be usable.
        let row = app.buttons["conversation-fixture-conversation"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.isHittable, "Sidebar rows must be directly tappable.")

        let openShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        openShot.name = "drawer-open"
        openShot.lifetime = .keepAlways
        add(openShot)

        row.tap()
        XCTAssertTrue(
            app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 5),
            "Selecting a row must mount the conversation as the main page."
        )

        let chatShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        chatShot.name = "chat-after-select"
        chatShot.lifetime = .keepAlways
        add(chatShot)

        // Reopen via the hamburger and capture the dimmed-page state.
        let opener = app.buttons["open-sidebar-button"]
        XCTAssertTrue(opener.waitForExistence(timeout: 3))
        opener.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))

        let reopenedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        reopenedShot.name = "drawer-reopened"
        reopenedShot.lifetime = .keepAlways
        add(reopenedShot)

        // Tapping the dimmed page closes the drawer without changing chats.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(
            app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3),
            "Closing the drawer must keep the same conversation mounted."
        )

        let closedShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        closedShot.name = "drawer-closed"
        closedShot.lifetime = .keepAlways
        add(closedShot)
    }

    func testTargetDropdownStartsANewChatFromTheProviderPages() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()
        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))

        let changeTarget = app.buttons["execution-envelope"]
        XCTAssertTrue(changeTarget.waitForExistence(timeout: 3))
        changeTarget.tap()
        XCTAssertTrue(element("target-dropdown", in: app).waitForExistence(timeout: 12))
        let provider = app.buttons["target-provider-endpoint:openAI"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()
        let fixtureTarget = app.buttons["target-option-endpoint:openAI:fixture-model"]
        XCTAssertTrue(fixtureTarget.waitForExistence(timeout: 3))
        fixtureTarget.tap()

        let switchedEnvelope = app.buttons["execution-envelope"]
        XCTAssertTrue(switchedEnvelope.waitForExistence(timeout: 3))
        XCTAssertTrue(
            (switchedEnvelope.value as? String)?.contains("fixture-model") == true,
            "The new canvas must report the chosen target."
        )
    }

    func testTemporaryToggleReplacesTheUnsentCanvasInPlace() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()
        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))
        // Pre-send controls (presets, temporary toggle) live on an empty
        // canvas only; spin one up from the pencil.
        let pencil = app.buttons["chat-new-chat-button"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 5))
        pencil.tap()
        XCTAssertTrue(app.buttons["temporary-chat-button"].waitForExistence(timeout: 5))

        let temporaryToggle = app.buttons["temporary-chat-button"]
        XCTAssertTrue(
            temporaryToggle.waitForExistence(timeout: 5),
            "The authenticated fixture role and interface policy should expose Temporary Chat."
        )
        temporaryToggle.tap()
        let disabledState = app.buttons["Disable temporary chat"]
        XCTAssertTrue(disabledState.waitForExistence(timeout: 5))
    }

    func testPresetDropdownAppliesAPresetToANewUnsentChat() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()
        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))
        // Pre-send controls (presets, temporary toggle) live on an empty
        // canvas only; spin one up from the pencil.
        let pencil = app.buttons["chat-new-chat-button"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 5))
        pencil.tap()
        XCTAssertTrue(app.buttons["temporary-chat-button"].waitForExistence(timeout: 5))

        let presetButton = app.buttons["preset-picker-button"]
        XCTAssertTrue(presetButton.waitForExistence(timeout: 5))
        presetButton.tap()
        XCTAssertTrue(element("preset-dropdown", in: app).waitForExistence(timeout: 5))
        let research = app.buttons["preset-option-preset-fixture"]
        XCTAssertTrue(research.waitForExistence(timeout: 5))
        research.tap()

        let envelope = app.buttons["execution-envelope"]
        XCTAssertTrue(envelope.waitForExistence(timeout: 3))
        XCTAssertTrue(
            (envelope.value as? String)?.contains("fixture-model-2") == true,
            "Applying a preset should start an editable local chat with its reviewed target."
        )
    }

    func testReviewedTargetCanBeSavedAsANativePreset() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()
        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))
        // Pre-send controls (presets, temporary toggle) live on an empty
        // canvas only; spin one up from the pencil.
        let pencil = app.buttons["chat-new-chat-button"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 5))
        pencil.tap()
        XCTAssertTrue(app.buttons["temporary-chat-button"].waitForExistence(timeout: 5))

        let presetButton = app.buttons["preset-picker-button"]
        XCTAssertTrue(presetButton.waitForExistence(timeout: 5))
        presetButton.tap()
        XCTAssertTrue(element("preset-dropdown", in: app).waitForExistence(timeout: 5))
        let saveSetup = app.buttons["preset-save-current"]
        XCTAssertTrue(saveSetup.waitForExistence(timeout: 3))
        saveSetup.tap()
        XCTAssertTrue(element("preset-create-sheet", in: app).waitForExistence(timeout: 3))

        let name = app.textFields["preset-create-title"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Native fixture preset")
        let instructions = element("preset-create-instructions", in: app)
        XCTAssertTrue(instructions.exists)
        instructions.tap()
        instructions.typeText("Answer with verified sources.")

        let save = app.buttons["preset-create-save"]
        XCTAssertTrue(waitUntilEnabledAndHittable(save, timeout: 3))
        save.tap()

        XCTAssertFalse(element("preset-create-sheet", in: app).exists)
        // The confirmed preset appears in the preset dropdown for the next new chat.
        let presetButtonAgain = app.buttons["preset-picker-button"]
        XCTAssertTrue(presetButtonAgain.waitForExistence(timeout: 5))
        presetButtonAgain.tap()
        XCTAssertTrue(element("preset-dropdown", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Native fixture preset"].waitForExistence(timeout: 8),
            "The saved preset should appear in the preset dropdown after refresh."
        )
    }

    func testPrivateBasicAgentCanBeCreatedFromReviewedModel() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()

        app.buttons["Account"].tap()
        let agents = app.buttons["Agents"]
        XCTAssertTrue(agents.waitForExistence(timeout: 3))
        agents.tap()

        XCTAssertTrue(element("agents-library", in: app).waitForExistence(timeout: 5))
        let newAgent = app.buttons["agent-create"]
        XCTAssertTrue(waitUntilEnabledAndHittable(newAgent, timeout: 5))
        newAgent.tap()
        XCTAssertTrue(element("agent-create-sheet", in: app).waitForExistence(timeout: 5))

        let name = app.textFields["agent-create-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Native researcher")

        let description = app.textFields["agent-create-description"]
        description.tap()
        description.typeText("Fixture evidence assistant")

        let category = app.textFields["agent-create-category"]
        category.tap()
        category.typeText("Research")

        let instructions = element("agent-create-instructions", in: app)
        XCTAssertTrue(instructions.exists)
        instructions.tap()
        instructions.typeText("Use primary sources and explain uncertainty.")

        let create = app.buttons["agent-create-confirm"]
        XCTAssertTrue(waitUntilEnabledAndHittable(create, timeout: 3))
        create.tap()

        XCTAssertFalse(element("agent-create-sheet", in: app).waitForExistence(timeout: 1))
        XCTAssertTrue(
            app.staticTexts["Native researcher"].waitForExistence(timeout: 5),
            "The directory should refresh only after the strict 201 confirmation."
        )
    }

    func testAccountFileLibraryLoadsSearchesAndOpensSafeDetails() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()

        app.buttons["Account"].tap()
        let files = app.buttons["Files"]
        XCTAssertTrue(files.waitForExistence(timeout: 3))
        files.tap()

        XCTAssertTrue(element("file-library", in: app).waitForExistence(timeout: 5))
        let search = app.searchFields["Search files"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("budget")

        let budget = element("file-library-item-0", in: app)
        XCTAssertTrue(budget.waitForExistence(timeout: 3))
        XCTAssertFalse(element("file-library-item-1", in: app).exists)
        budget.tap()

        XCTAssertTrue(element("file-library-detail", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Budget.pdf"].exists)
        XCTAssertTrue(
            app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'PDF'")).firstMatch.exists
        )
        XCTAssertFalse(app.staticTexts["s3"].exists)
        XCTAssertTrue(element("file-preview-text", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Budget preview fixture"].exists)

        let download = app.buttons["file-download-action"]
        XCTAssertTrue(download.waitForExistence(timeout: 3))
        download.tap()
        XCTAssertTrue(
            app.buttons["file-download-share"].waitForExistence(timeout: 5),
            "A successful protected transfer should expose only the native Share/Save handoff."
        )

        let delete = app.buttons["file-delete-action"]
        for _ in 0..<4 where !delete.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            waitUntilEnabledAndHittable(delete, timeout: 3),
            "A server-compatible owner file should expose the confirmed deletion action."
        )
        delete.tap()
        let confirm = app.buttons["Delete file"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        XCTAssertTrue(
            app.staticTexts["No matching files"].waitForExistence(timeout: 5),
            "The detail should dismiss only after a fresh owner catalog proves the file absent."
        )
        XCTAssertFalse(element("file-library-item-0", in: app).exists)
    }

    func testExistingConversationOpensItsMatchingChatAndMessage() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        let conversation = app.buttons["conversation-fixture-conversation"]
        XCTAssertEqual(
            app.buttons.matching(identifier: "conversation-fixture-conversation").count,
            1,
            "The chat row must remain the row's single semantic identity."
        )
        conversation.tap()

        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))
        // The top bar hosts the model picker instead of the conversation title.
        XCTAssertTrue(app.buttons["execution-envelope"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["message-fixture-message-80"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Fixture message 080"].exists)

        let envelope = app.buttons["execution-envelope"]
        XCTAssertTrue(envelope.exists)
        XCTAssertEqual(envelope.label, "Message setup")
        XCTAssertEqual(
            envelope.value as? String,
            "Target: fixture-model. Attachments: No attachments. Server: ui-test.invalid."
        )
        let attachmentMenu = app.buttons["attachment-menu"]
        XCTAssertTrue(attachmentMenu.exists)
        XCTAssertTrue(app.buttons["composer-send"].exists)
        attachmentMenu.tap()
        XCTAssertTrue(app.buttons["attach-photo"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["attach-camera"].exists)
        XCTAssertTrue(app.buttons["attach-file"].exists)
    }

    func testManualHistoryScrollRevealsJumpToLatestAndReturnsToLatestMessage() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()
        let history = app.scrollViews["chat-view-fixture-conversation"]
        XCTAssertTrue(history.waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["message-fixture-message-80"].waitForExistence(timeout: 3))

        history.swipeDown()
        history.swipeDown()
        let jumpToLatest = app.buttons["jump-to-latest"]
        XCTAssertTrue(jumpToLatest.waitForExistence(timeout: 3))
        jumpToLatest.tap()

        XCTAssertTrue(element("message-fixture-message-80", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Fixture message 080"].exists)
    }

    func testArtifactCardPushesNativeWorkspaceAndBackPreservesChat() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()

        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))
        let artifact = app.buttons["message-artifact-0"]
        XCTAssertTrue(artifact.waitForExistence(timeout: 5))
        artifact.tap()

        XCTAssertTrue(element("artifact-workspace", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.navigationBars["Fixture artifact"].exists)
        XCTAssertTrue(element("artifact-workspace-provenance", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Native artifact workspace"].exists)

        app.navigationBars["Fixture artifact"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["message-fixture-message-80"].exists)
    }

    func testExistingChatTargetSelectionStartsANewConversationWithoutRetargetingHistory() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()
        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))

        let changeTarget = app.buttons["execution-envelope"]
        XCTAssertTrue(changeTarget.waitForExistence(timeout: 3))
        XCTAssertTrue(
            waitUntilEnabledAndHittable(changeTarget, timeout: 5),
            "Changing targets must wait for authoritative routing and history readiness."
        )
        changeTarget.tap()
        // A real anchored dropdown appears under the top bar.
        XCTAssertTrue(element("target-dropdown", in: app).waitForExistence(timeout: 12))
        let provider = app.buttons["target-provider-endpoint:openAI"]
        XCTAssertTrue(provider.waitForExistence(timeout: 5))
        provider.tap()

        let target = app.buttons["target-option-endpoint:openAI:fixture-model-2"]
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        // Tapping the target starts the new chat directly, LibreChat-style.
        target.tap()

        // The new-chat canvas shows the top-bar model picker instead of a title.
        let switchedEnvelope = app.buttons["execution-envelope"]
        XCTAssertTrue(switchedEnvelope.waitForExistence(timeout: 3))
        XCTAssertTrue(
            (switchedEnvelope.value as? String)?.contains("fixture-model-2") == true,
            "The new canvas must report the switched target."
        )

        // The drawer-era canvas replaces the main page in place; return to
        // the original conversation through the sidebar.
        let reopen = app.buttons["open-sidebar-button"]
        XCTAssertTrue(reopen.waitForExistence(timeout: 3))
        reopen.tap()
        let originalRow = app.buttons["conversation-fixture-conversation"]
        XCTAssertTrue(originalRow.waitForExistence(timeout: 5))
        originalRow.tap()
        XCTAssertTrue(app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3))
        let originalEnvelope = app.buttons["execution-envelope"]
        XCTAssertTrue(originalEnvelope.waitForExistence(timeout: 3))
        XCTAssertTrue(
            (originalEnvelope.value as? String)?.contains("fixture-model.") == true
                || (originalEnvelope.value as? String)?.contains("fixture-model ") == true,
            "The original conversation keeps its original target."
        )
    }

    func testMessageSearchOpensAndFocusesExactNondefaultBranch() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        let search = app.searchFields["Search chats and messages"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        XCTAssertTrue(waitUntilEnabledAndHittable(search, timeout: 5))
        search.tap()
        search.typeText("branch match")

        let scope = app.segmentedControls["search-scope-picker"]
        XCTAssertTrue(scope.waitForExistence(timeout: 3))
        scope.buttons["Messages"].tap()

        let result = app.buttons["search-message-fixture-search-match"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()

        XCTAssertTrue(
            app.scrollViews["chat-view-fixture-conversation"].waitForExistence(timeout: 3)
        )
        let matchedMessage = app.otherElements["message-fixture-search-match"]
        XCTAssertTrue(matchedMessage.waitForExistence(timeout: 8))
        XCTAssertTrue(matchedMessage.isHittable)
        XCTAssertFalse(
            app.otherElements["message-fixture-message-80"].exists,
            "The default branch tail must not remain projected after exact-hit focus"
        )
    }

    func testSelectedAssistantOffersOneShotResponseRegenerationReview() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()

        let response = element("message-fixture-message-80", in: app)
        XCTAssertTrue(response.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        response.press(forDuration: 1.2)

        let regenerate = app.buttons["Regenerate response"]
        XCTAssertTrue(regenerate.waitForExistence(timeout: 6))
        regenerate.tap()

        XCTAssertTrue(element("response-regeneration-sheet", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["The existing response and its replies stay unchanged."].exists)
        XCTAssertTrue(app.staticTexts["A new response branch will be generated using the current chat target: fixture-model."].exists)
        XCTAssertTrue(app.buttons["response-regeneration-submit"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(element("response-regeneration-sheet", in: app).exists)
    }

    func testSavedMessageOffersOneShotConversationForkReview() throws {
        continueAfterFailure = false
        let app = launchFixtureApp()
        app.buttons["conversation-fixture-conversation"].tap()

        let response = element("message-fixture-message-80", in: app)
        XCTAssertTrue(response.waitForExistence(timeout: 3))
        Thread.sleep(forTimeInterval: 0.5)
        response.press(forDuration: 1.2)

        let fork = app.buttons["Branch in new chat"]
        XCTAssertTrue(fork.waitForExistence(timeout: 6))
        fork.tap()

        XCTAssertTrue(element("conversation-fork-sheet", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Original conversation stays unchanged"].exists)
        XCTAssertTrue(app.staticTexts["Copies the selected path through this message"].exists)
        XCTAssertTrue(app.buttons["submit-conversation-fork"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertFalse(element("conversation-fork-sheet", in: app).exists)
    }
}
