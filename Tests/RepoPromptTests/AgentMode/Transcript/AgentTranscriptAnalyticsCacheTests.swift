import Foundation
@testable import RepoPrompt
import XCTest

final class AgentTranscriptAnalyticsCacheTests: XCTestCase {
    func testBuildTranscriptPresentationReusesAnalyticsForUnchangedTranscriptAndAgent() {
        let previousAnalytics = AgentTranscriptAnalyticsSnapshot(
            observedReadFiles: ["Sources/RepoPrompt/App/AppDelegate.swift"],
            estimatedTranscriptTokens: 42,
            selectedAgent: .codexExec
        )

        let presentation = AgentModeViewModel.buildTranscriptPresentation(
            from: .empty,
            sourceItems: [],
            selectedAgent: .codexExec,
            previousPerformanceSnapshot: .empty,
            previousAnalyticsSnapshot: previousAnalytics,
            previousSanitizedTranscript: .empty
        )

        XCTAssertEqual(presentation.analyticsSnapshot, previousAnalytics)
    }
}
