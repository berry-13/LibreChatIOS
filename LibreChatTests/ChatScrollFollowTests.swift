@testable import LibreChat
import XCTest

final class ChatScrollFollowTests: XCTestCase {
    func testInitialPositioningRunsOnlyOnceAcrossWorkspaceNavigationReturn() {
        var state = ChatInitialPositioningState()

        XCTAssertTrue(state.beginInitialPositioningIfNeeded())
        XCTAssertFalse(state.beginInitialPositioningIfNeeded())
    }

    func testExplicitMessageFocusConsumesInitialPositioning() {
        var state = ChatInitialPositioningState()

        state.recordExplicitFocus()

        XCTAssertFalse(state.beginInitialPositioningIfNeeded())
    }

    func testUserInteractionSuspendsFollowingImmediatelyInsideAutomaticTolerance() {
        var state = stateAtBottom()

        state.beginUserInteraction()
        state.updateBottomOffset(520)

        XCTAssertFalse(state.isFollowingBottom)
        XCTAssertFalse(state.shouldFollowContent)
    }

    func testEndingInteractionAwayFromBottomKeepsFollowingSuspended() {
        var state = stateAtBottom()

        state.beginUserInteraction()
        state.updateBottomOffset(520)
        state.endUserInteraction()

        XCTAssertFalse(state.isUserInteracting)
        XCTAssertFalse(state.isFollowingBottom)
    }

    func testEndingInteractionAtBottomRestoresFollowing() {
        var state = stateAtBottom()

        state.beginUserInteraction()
        state.updateBottomOffset(505)
        state.endUserInteraction()

        XCTAssertTrue(state.isFollowingBottom)
        XCTAssertTrue(state.shouldFollowContent)
    }

    func testAutomaticGrowthToleranceDoesNotDetachStreamingContent() {
        var state = stateAtBottom()

        state.updateBottomOffset(580)

        XCTAssertTrue(state.shouldFollowContent)
    }

    func testScrollGeometryDistanceSuspendsFollowingAwayFromBottom() {
        var state = stateAtBottom()

        state.updateDistanceFromBottom(500)

        XCTAssertFalse(state.shouldFollowContent)
    }

    func testScrollGeometryDistanceRestoresFollowingAtBottom() {
        var state = stateAtBottom()
        state.updateDistanceFromBottom(500)

        state.updateDistanceFromBottom(0)

        XCTAssertTrue(state.shouldFollowContent)
    }

    func testFollowRequestRestoresSuspendedState() {
        var state = stateAtBottom()
        state.beginUserInteraction()
        state.updateBottomOffset(800)
        state.endUserInteraction()

        state.requestFollowBottom()

        XCTAssertTrue(state.shouldFollowContent)
    }

    func testExternalFocusSuspendsAutomaticBottomFollowing() {
        var state = stateAtBottom()

        state.suspendFollowing()
        state.updateBottomOffset(500)

        XCTAssertFalse(state.isUserInteracting)
        XCTAssertFalse(state.isFollowingBottom)
        XCTAssertFalse(state.shouldFollowContent)
    }

    private func stateAtBottom() -> ChatScrollFollowState {
        var state = ChatScrollFollowState()
        state.updateViewportHeight(500)
        state.updateBottomOffset(500)
        return state
    }
}

@MainActor
final class ChatScrollFollowControllerTests: XCTestCase {
    func testFrameRateTelemetryNeverEmitsWhileFollowingIsStable() {
        let controller = ChatScrollFollowController()
        var emissions = 0
        controller.onFollowStateChanged = { _ in emissions += 1 }
        controller.updateViewportHeight(500)

        // Every frame of an at-bottom scroll updates the distance.
        for distance in [0, 3, 8, 20, 40, 12, 0, 5] {
            controller.updateDistanceFromBottom(CGFloat(distance))
        }

        XCTAssertEqual(emissions, 0)
    }

    func testLeavingAndReturningToBottomEmitsExactlyOneFlipEach() {
        let controller = ChatScrollFollowController()
        var recorded: [Bool] = []
        controller.onFollowStateChanged = { following in recorded.append(following) }
        controller.updateViewportHeight(500)

        controller.beginUserInteraction()
        controller.updateDistanceFromBottom(800)
        controller.endUserInteraction()
        controller.updateDistanceFromBottom(900)
        controller.updateDistanceFromBottom(700)
        controller.updateDistanceFromBottom(0)
        controller.updateDistanceFromBottom(2)

        XCTAssertEqual(recorded, [false, true])
        XCTAssertTrue(controller.shouldFollowContent)
    }
}

