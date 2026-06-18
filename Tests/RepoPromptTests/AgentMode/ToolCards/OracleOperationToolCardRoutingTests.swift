@testable import RepoPrompt
import XCTest

final class OracleOperationToolCardRoutingTests: XCTestCase {
    func testContextBuilderSelectsExactPlanOrReviewChatID() throws {
        let planDTO = try contextBuilderDTO(responseType: "plan")
        let questionDTO = try contextBuilderDTO(responseType: "question")
        let reviewDTO = try contextBuilderDTO(responseType: "review")

        XCTAssertEqual(contextBuilderFollowUpChatID(for: planDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: questionDTO), "plan-chat")
        XCTAssertEqual(contextBuilderFollowUpChatID(for: reviewDTO), "review-chat")

        let tabID = UUID()
        let workspaceID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: workspaceID,
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let userInfo = try XCTUnwrap(contextBuilderOraclePopoverUserInfo(
            openContext: openContext,
            chatID: contextBuilderFollowUpChatID(for: reviewDTO)
        ))

        XCTAssertEqual(userInfo["windowID"] as? Int, 42)
        XCTAssertEqual(userInfo["workspaceID"] as? UUID, workspaceID)
        XCTAssertEqual(userInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(userInfo["chatID"] as? String, "review-chat")
    }

    func testContextBuilderOperationRoutingRejectsMissingOrBlankChatIDWithoutAmbientFallback() {
        let openContext = AgentOracleOpenContext(
            windowID: 42,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )

        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: nil))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(openContext: openContext, chatID: "   \n"))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: nil, tabID: UUID()),
            chatID: "exact-chat"
        ))
        XCTAssertNil(contextBuilderOraclePopoverUserInfo(
            openContext: AgentOracleOpenContext(windowID: 42, workspaceID: UUID(), tabID: nil),
            chatID: "exact-chat"
        ))
    }

    func testDirectOracleResultRoutingRequiresExactResultChatID() throws {
        let tabID = UUID()
        let openContext = AgentOracleOpenContext(
            windowID: 7,
            workspaceID: UUID(),
            tabID: tabID,
            chatID: "ambient-chat"
        )
        let exactItem = toolResultItem(
            toolName: "ask_oracle",
            payload: ["chat_id": "  exact-result-chat  ", "mode": "review"]
        )
        let exactUserInfo = try XCTUnwrap(oracleToolResultPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["windowID"] as? Int, 7)
        XCTAssertEqual(exactUserInfo["tabID"] as? UUID, tabID)
        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-result-chat")

        let exactOracleSendUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "oracle_send",
                payload: ["chat_id": "exact-oracle-send-chat"]
            ),
            openContext: openContext
        )
        XCTAssertEqual(exactOracleSendUserInfo?["chatID"] as? String, "exact-oracle-send-chat")

        let malformedOptionalPayloadUserInfo = oracleToolResultPopoverUserInfo(
            item: toolResultItem(
                toolName: "ask_oracle",
                payload: ["chat_id": "exact-despite-malformed-diffs", "diffs": [["path": 42]]]
            ),
            openContext: openContext
        )
        XCTAssertEqual(
            malformedOptionalPayloadUserInfo?["chatID"] as? String,
            "exact-despite-malformed-diffs"
        )

        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["mode": "review"]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "ask_oracle", payload: ["chat_id": "\n  "]),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolResultPopoverUserInfo(
            item: toolResultItem(toolName: "oracle_send", payload: ["chat_id": "   "]),
            openContext: openContext
        ))
    }

    func testOracleToolCallRoutingRequiresExactArgumentChatID() throws {
        let openContext = AgentOracleOpenContext(
            windowID: 9,
            workspaceID: UUID(),
            tabID: UUID(),
            chatID: "ambient-chat"
        )
        let exactItem = AgentChatItem(
            kind: .toolCall,
            text: "",
            toolName: "oracle_send",
            toolArgsJSON: jsonString(["chat_id": "  exact-call-chat  "])
        )
        let exactUserInfo = try XCTUnwrap(oracleToolCallPopoverUserInfo(
            item: exactItem,
            openContext: openContext
        ))

        XCTAssertEqual(exactUserInfo["chatID"] as? String, "exact-call-chat")

        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "ask_oracle",
                toolArgsJSON: jsonString(["message": "start a new chat"])
            ),
            openContext: openContext
        ))
        XCTAssertNil(oracleToolCallPopoverUserInfo(
            item: AgentChatItem(
                kind: .toolCall,
                text: "",
                toolName: "oracle_send",
                toolArgsJSON: jsonString(["chat_id": "\t "])
            ),
            openContext: openContext
        ))
    }

    func testDirectOracleRoutingRejectsNestedAliasedAndConflictingChatIDs() {
        let openContext = AgentOracleOpenContext(
            windowID: 11,
            workspaceID: UUID(),
            tabID: UUID()
        )

        let rejectedPayloads: [[String: Any]] = [
            ["result": ["chat_id": "nested-only"]],
            ["chatID": "camel-only"],
            ["chat_id": 42],
            ["chat_id": "authoritative", "result": ["chat_id": "conflict"]],
            ["chat_id": "authoritative", "items": [["chatID": "conflict"]]]
        ]

        for payload in rejectedPayloads {
            XCTAssertNil(oracleToolResultPopoverUserInfo(
                item: toolResultItem(toolName: "ask_oracle", payload: payload),
                openContext: openContext
            ))
            XCTAssertNil(oracleToolCallPopoverUserInfo(
                item: AgentChatItem(
                    kind: .toolCall,
                    text: "",
                    toolName: "oracle_send",
                    toolArgsJSON: jsonString(payload)
                ),
                openContext: openContext
            ))
        }
    }

    func testContextBuilderRoutingRejectsMismatchedOrUnknownResponseBranch() throws {
        let reviewWithPlanOnly = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "review",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))
        let unknownWithPlan = try XCTUnwrap(ToolJSON.decode(
            ToolResultDTOs.ContextBuilderDTO.self,
            from: jsonString([
                "status": "success",
                "response_type": "clarify",
                "plan": ["chat_id": "wrong-plan-chat", "mode": "plan"]
            ])
        ))

        XCTAssertNil(contextBuilderFollowUpChatID(for: reviewWithPlanOnly))
        XCTAssertNil(contextBuilderFollowUpChatID(for: unknownWithPlan))
    }

    private func contextBuilderDTO(responseType: String) throws -> ToolResultDTOs.ContextBuilderDTO {
        let raw = jsonString([
            "status": "success",
            "response_type": responseType,
            "plan": ["chat_id": "plan-chat", "mode": "plan"],
            "review": ["chat_id": "review-chat", "mode": "review"]
        ])
        return try XCTUnwrap(ToolJSON.decode(ToolResultDTOs.ContextBuilderDTO.self, from: raw))
    }

    private func toolResultItem(toolName: String, payload: [String: Any]) -> AgentChatItem {
        let raw = jsonString(payload)
        return AgentChatItem(
            kind: .toolResult,
            text: raw,
            toolName: toolName,
            toolResultJSON: raw
        )
    }

    private func jsonString(
        _ object: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        XCTAssertTrue(JSONSerialization.isValidJSONObject(object), file: file, line: line)
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }
}
