import DesignKit
import Testing

@Suite("Generation activity presentation")
struct GenerationActivityPresentationTests {
    @Test func activeAndAttentionItemsDriveTheCompactSummary() throws {
        let completed = try #require(GenerationActivityItem(
            id: "step:1",
            title: "Read project files",
            state: .completed
        ))
        let running = try #require(GenerationActivityItem(
            id: "tool:1",
            title: "Search workspace",
            state: .running
        ))
        let attention = try #require(GenerationActivityItem(
            id: "tool:2",
            title: "Confirm deployment",
            state: .attention
        ))
        let group = try #require(GenerationActivityGroup(
            id: "tools",
            title: "Tools",
            items: [completed, running, attention]
        ))

        let presentation = GenerationActivityPresentation(
            phase: .needsAttention,
            groups: [group]
        )

        #expect(presentation.headerDetail == "Confirm deployment · Needs attention")
        #expect(presentation.accessibilityLabel == "Response activity")
        #expect(presentation.accessibilityValue.contains("Needs your input"))
        #expect(presentation.accessibilityValue.contains("3 activity items"))
    }

    @Test func completedSummaryCountsOnlyTrackedWork() throws {
        let completed = try #require(GenerationActivityItem(
            id: "step:done",
            title: "Collect sources",
            state: .completed
        ))
        let failed = try #require(GenerationActivityItem(
            id: "step:failed",
            title: "Open restricted file",
            state: .stopped
        ))
        let update = try #require(GenerationActivityItem(
            id: "activity:1",
            title: "Researcher updated",
            state: .informational
        ))
        let group = try #require(GenerationActivityGroup(
            id: "steps",
            title: "Steps",
            items: [completed, failed, update]
        ))

        let presentation = GenerationActivityPresentation(
            phase: .stopped,
            groups: [group]
        )

        #expect(presentation.headerDetail == "1 of 2 steps completed")
    }

    @Test func textAndNumericMetadataAreBoundedAndFailClosed() throws {
        let item = try #require(GenerationActivityItem(
            id: "tool:search\nprivate",
            title: "  Search\nworkspace  ",
            detail: String(repeating: "x", count: 400),
            state: .running,
            progress: 1.5,
            duration: -.infinity
        ))

        #expect(item.id == "tool:search private")
        #expect(item.title == "Search workspace")
        #expect(item.detail?.count == 320)
        #expect(item.detail?.hasSuffix("…") == true)
        #expect(item.progress == nil)
        #expect(item.duration == nil)
        #expect(GenerationActivityItem(
            id: " ",
            title: "Hidden",
            state: .informational
        ) == nil)
        #expect(GenerationActivityGroup(id: "empty", title: "Empty", items: []) == nil)
    }

    @Test func durationAndProgressRemainTruthful() throws {
        let brief = try #require(GenerationActivityItem(
            id: "tool:brief",
            title: "Brief tool",
            state: .completed,
            progress: 0.625,
            duration: 0.4
        ))
        let long = try #require(GenerationActivityItem(
            id: "tool:long",
            title: "Long tool",
            state: .completed,
            duration: 125
        ))

        #expect(brief.progress == 0.625)
        #expect(brief.durationLabel == "Under 1 second")
        #expect(long.durationLabel == "2 minutes, 5 seconds")
    }

    @Test func metricsAreOptionalAndNeverInventZeroValues() {
        let empty = GenerationActivityPresentation(phase: .starting, groups: [])
        #expect(!empty.isExpandable)
        #expect(empty.headerDetail == "LibreChat is preparing the response.")
        #expect(!empty.accessibilityValue.contains("tokens"))

        let measured = GenerationActivityPresentation(
            phase: .completed,
            groups: [],
            tokenSummary: "120 input · 45 output tokens",
            contextSummary: "179500 context tokens remaining"
        )
        #expect(measured.isExpandable)
        #expect(measured.accessibilityValue.contains("120 input · 45 output tokens"))
        #expect(measured.accessibilityValue.contains("179500 context tokens remaining"))
    }
}
