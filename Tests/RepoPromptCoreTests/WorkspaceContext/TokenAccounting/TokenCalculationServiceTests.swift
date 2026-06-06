import Foundation
@testable import RepoPromptCore
import XCTest

final class TokenCalculationServiceTests: XCTestCase {
    func testEstimateTokensUsesUTF8BytesAndSafetyMultiplier() {
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: ""), 0)
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: "1234"), 1)
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: "éé"), 1)
        XCTAssertEqual(TokenCalculationService.estimateTokens(for: String(repeating: "a", count: 40)), 10)
    }

    func testMiddleTruncateIsDeterministicIdempotentAndUnicodeSafe() {
        let text = String(repeating: "🙂abcdef", count: 100)
        let truncated = TokenCalculationService.middleTruncate(text: text, maxTokens: 30)

        XCTAssertTrue(truncated.contains("[content truncated]"))
        XCTAssertLessThan(truncated.utf8.count, text.utf8.count)
        XCTAssertEqual(TokenCalculationService.middleTruncate(text: truncated, maxTokens: 30), truncated)
        XCTAssertNotNil(truncated.data(using: .utf8))
    }

    func testComponentBreakdownPreservesDuplicatePromptAndNonFileTotals() {
        let breakdown = TokenCalculationService.calculateComponentBreakdown(
            promptText: "12345678",
            selectedInstructionsText: "1234",
            fileTreeText: "12345678",
            gitDiffText: "1234",
            metadataText: "1234",
            duplicateUserInstructionsAtTop: true
        )

        XCTAssertEqual(breakdown.prompt, 2)
        XCTAssertEqual(breakdown.duplicatePrompt, 2)
        XCTAssertEqual(breakdown.instructions, 1)
        XCTAssertEqual(breakdown.fileTree, 2)
        XCTAssertEqual(breakdown.gitDiff, 1)
        XCTAssertEqual(breakdown.metadata, 1)
        XCTAssertEqual(breakdown.promptDisplay, 4)
        XCTAssertEqual(breakdown.totalNonFile, 9)
    }

    func testPromptEntryEvaluationDistinguishesFullSliceAndCodemapModes() async {
        let service = TokenCalculationService()
        let fullID = UUID()
        let sliceID = UUID()
        let codemapID = UUID()
        let entries = [
            PromptFileEntrySnapshot(
                fileID: fullID,
                relativePath: "Full.swift",
                isCodemapRequested: false,
                ranges: nil,
                cachedFullTokenCount: nil,
                loadedContent: "one\ntwo\nthree\n",
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: sliceID,
                relativePath: "Slice.swift",
                isCodemapRequested: false,
                ranges: [LineRange(start: 2, end: 2)],
                cachedFullTokenCount: nil,
                loadedContent: "one\ntwo\nthree\n",
                codeMapContent: nil,
                availableCodeMapTokenCount: 0
            ),
            PromptFileEntrySnapshot(
                fileID: codemapID,
                relativePath: "Map.swift",
                isCodemapRequested: true,
                ranges: nil,
                cachedFullTokenCount: 20,
                loadedContent: nil,
                codeMapContent: "struct Map {}",
                availableCodeMapTokenCount: 4
            )
        ]

        let result = await service.evaluatePromptEntries(entries)

        XCTAssertEqual(result.entryResultsByFileID[fullID]?.renderMode, .full)
        XCTAssertEqual(result.entryResultsByFileID[sliceID]?.renderMode, .slice)
        XCTAssertEqual(result.entryResultsByFileID[codemapID]?.renderMode, .codemap)
        XCTAssertEqual(result.fullCount, 1)
        XCTAssertEqual(result.sliceCount, 1)
        XCTAssertEqual(result.codemapCount, 1)
        XCTAssertEqual(result.codeMapFileCount, 1)
        XCTAssertTrue(result.codeMapContent.contains("struct Map"))
    }
}
