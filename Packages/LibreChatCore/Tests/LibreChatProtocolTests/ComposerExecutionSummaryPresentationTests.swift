import DesignKit
import XCTest

final class ComposerExecutionSummaryPresentationTests: XCTestCase {
    func testTargetUsesTruthfulPriorityAndAttachmentSummary() {
        let presentation = ComposerExecutionSummaryPresentation(
            targetSpec: "  Responses API  ",
            model: "gpt-5",
            selectedAgentOrAssistant: "Selected agent",
            endpoint: "openAI",
            attachmentCount: 2,
            attachmentState: "ready",
            serverHost: "chat.example.com"
        )

        XCTAssertEqual(presentation.target, "Responses API")
        XCTAssertEqual(presentation.attachments, "2 attachments, ready")
        XCTAssertEqual(presentation.serverHost, "chat.example.com")
        XCTAssertEqual(
            presentation.supportingText,
            "2 attachments, ready · chat.example.com"
        )
        XCTAssertEqual(presentation.accessibilityLabel, "Message setup")
        XCTAssertEqual(
            presentation.accessibilityValue,
            "Target: Responses API. Attachments: 2 attachments, ready. Server: chat.example.com."
        )
    }

    func testTargetFallsBackThroughModelSelectionAndEndpoint() {
        let model = ComposerExecutionSummaryPresentation(
            targetSpec: nil,
            model: "gpt-5",
            selectedAgentOrAssistant: "Selected assistant",
            endpoint: "openAI",
            attachmentCount: 1,
            attachmentState: "uploading",
            serverHost: "chat.example.com"
        )
        XCTAssertEqual(model.target, "gpt-5")

        let selection = ComposerExecutionSummaryPresentation(
            targetSpec: " ",
            model: nil,
            selectedAgentOrAssistant: "Selected assistant",
            endpoint: "openAI",
            attachmentCount: 0,
            attachmentState: "ignored",
            serverHost: "chat.example.com"
        )
        XCTAssertEqual(selection.target, "Selected assistant")
        XCTAssertEqual(selection.attachments, "No attachments")
        XCTAssertEqual(selection.displayText, "Selected assistant · chat.example.com")
        XCTAssertEqual(selection.supportingText, "chat.example.com")

        let endpoint = ComposerExecutionSummaryPresentation(
            targetSpec: nil,
            model: nil,
            selectedAgentOrAssistant: nil,
            endpoint: "agents",
            attachmentCount: -1,
            attachmentState: nil,
            serverHost: " "
        )
        XCTAssertEqual(endpoint.target, "agents")
        XCTAssertEqual(endpoint.attachments, "No attachments")
        XCTAssertEqual(endpoint.serverHost, "Server unavailable")
    }

    func testTargetUnavailableIsExplicit() {
        let presentation = ComposerExecutionSummaryPresentation(
            targetSpec: nil,
            model: nil,
            selectedAgentOrAssistant: nil,
            endpoint: nil,
            attachmentCount: 1,
            attachmentState: nil,
            serverHost: nil
        )

        XCTAssertEqual(presentation.target, "Target unavailable")
        XCTAssertEqual(presentation.attachments, "1 attachment")
        XCTAssertEqual(presentation.serverHost, "Server unavailable")
    }

    func testExecutionScopeIsOptionalDeduplicatedAndAccessible() {
        let unknown = ComposerExecutionSummaryPresentation(
            targetSpec: "Spec",
            model: nil,
            selectedAgentOrAssistant: nil,
            endpoint: "agents",
            attachmentCount: 0,
            attachmentState: nil,
            serverHost: "chat.example.com"
        )
        XCTAssertNil(unknown.executionScopeDisplayText)
        XCTAssertFalse(unknown.accessibilityValue.contains("Tools:"))

        let none = ComposerExecutionSummaryPresentation(
            targetSpec: "Spec",
            model: nil,
            selectedAgentOrAssistant: nil,
            endpoint: "agents",
            attachmentCount: 0,
            attachmentState: nil,
            serverHost: "chat.example.com",
            executionCapabilities: []
        )
        XCTAssertEqual(none.executionScopeDisplayText, "Tools: None")
        XCTAssertEqual(
            none.accessibilityValue,
            "Target: Spec. Attachments: No attachments. Server: chat.example.com. Tools: None."
        )

        let scoped = ComposerExecutionSummaryPresentation(
            targetSpec: "Spec",
            model: nil,
            selectedAgentOrAssistant: nil,
            endpoint: "agents",
            attachmentCount: 0,
            attachmentState: nil,
            serverHost: "chat.example.com",
            executionCapabilities: [" Web search ", "Code execution", "Web search", " "]
        )
        XCTAssertEqual(scoped.executionCapabilities, ["Web search", "Code execution"])
        XCTAssertEqual(scoped.executionScopeDisplayText, "Tools: Web search · Code execution")
        XCTAssertEqual(
            scoped.supportingText,
            "Tools: Web search · Code execution · chat.example.com"
        )
        XCTAssertEqual(
            scoped.accessibilityValue,
            "Target: Spec. Attachments: No attachments. Server: chat.example.com. Tools: Web search, Code execution."
        )
    }
}
