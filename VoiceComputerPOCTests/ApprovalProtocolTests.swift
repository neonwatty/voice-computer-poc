import Darwin
import Foundation
import XCTest

@testable import VoiceComputerPOC

final class ApprovalProtocolTests: XCTestCase {
    private let requestID = 42

    func testOnlyComputerUseEmptyFormIsPresented() throws {
        let valid = makeRequest(sessionGrant: true)
        let parsed = ApprovalRequest.parse(
            method: "mcpServer/elicitation/request",
            id: requestID,
            params: valid
        )
        XCTAssertEqual(parsed?.id, requestID)
        XCTAssertEqual(parsed?.detail, "Computer Use · Calculator · get_app_state")
        XCTAssertTrue(parsed?.supportsSessionGrant == true)

        var otherConnector = valid
        var metadata = try XCTUnwrap(otherConnector["_meta"] as? [String: Any])
        metadata["connector_id"] = "some-other-connector"
        otherConnector["_meta"] = metadata
        XCTAssertNil(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID, params: otherConnector
            ))

        var formWithFields = valid
        formWithFields["requestedSchema"] = ["properties": ["secret": ["type": "string"]]]
        XCTAssertNil(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID, params: formWithFields
            ))

        var unrelatedServer = valid
        unrelatedServer["serverName"] = "other"
        XCTAssertNil(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID, params: unrelatedServer))
        var urlMode = valid
        urlMode["mode"] = "url"
        XCTAssertNil(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID, params: urlMode))
        var unknownMode = valid
        unknownMode["mode"] = "future"
        XCTAssertNil(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID, params: unknownMode))
    }

    func testSessionGrantIsSentOnlyWhenAdvertised() throws {
        let supported = try XCTUnwrap(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID,
                params: makeRequest(sessionGrant: true)
            ))
        let accepted = try result(of: supported.response(allow: true, forSession: true))
        XCTAssertEqual(accepted["action"] as? String, "accept")
        XCTAssertEqual((accepted["_meta"] as? [String: String])?["persist"], "session")
        let once = try result(of: supported.response(allow: true, forSession: false))
        XCTAssertEqual(once["action"] as? String, "accept")
        XCTAssertNil(once["_meta"])

        let unsupported = try XCTUnwrap(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID,
                params: makeRequest(sessionGrant: false)
            ))
        let oneTime = try result(of: unsupported.response(allow: true, forSession: true))
        XCTAssertNil(oneTime["_meta"])
    }

    func testDeclineCannotPersistAnApproval() throws {
        let request = try XCTUnwrap(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID,
                params: makeRequest(sessionGrant: true)
            ))
        let wire = request.response(allow: false, forSession: true)
        XCTAssertEqual(wire["id"] as? Int, requestID)
        let response = try result(of: wire)
        XCTAssertEqual(response["action"] as? String, "decline")
        XCTAssertTrue(response["content"] is NSNull)
        XCTAssertNil(response["_meta"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(wire))
    }

    func testSpaceToolApprovalUsesExistingVisibleFlow() throws {
        let request: [String: Any] = [
            "serverName": "desktop_tool", "mode": "form",
            "message": "Allow desktop_tool to call switch_space?",
            "requestedSchema": ["properties": [String: Any]()],
            "_meta": [
                "codex_approval_kind": "mcp_tool_call",
                "tool_params": ["direction": "right"],
                "persist": ["session"],
            ],
        ]
        let parsed = try XCTUnwrap(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID, params: request))
        XCTAssertEqual(parsed.detail, "Space tool · switch_space · right")
        XCTAssertTrue(parsed.supportsSessionGrant)
        XCTAssertEqual(
            try result(of: parsed.response(allow: false, forSession: false))["action"] as? String,
            "decline")
        var wrong = request
        wrong["serverName"] = "other"
        XCTAssertNil(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: requestID, params: wrong))
    }

    func testRealShapeWaitsForVisibleChoiceAndSendsOneTimeResponse() throws {
        let client = AppServerClient()
        let pipe = Pipe()
        client.input = pipe
        client.isWorking = true
        client.handleServerRequest(
            method: "mcpServer/elicitation/request", id: requestID,
            params: makeRequest(sessionGrant: true))
        XCTAssertEqual(client.approval?.detail, "Computer Use · Calculator · get_app_state")
        XCTAssertNil(client.diagnosticEntries.last { $0.event == "approval_requested" }?.details["detail"])
        var descriptor = pollfd(
            fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&descriptor, 1, 0), 0)
        client.decideApproval(allow: true)
        let data = pipe.fileHandleForReading.availableData
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(wire["id"] as? Int, requestID)
        XCTAssertEqual(try result(of: wire)["action"] as? String, "accept")
        XCTAssertNil(try result(of: wire)["_meta"])
        XCTAssertNil(client.approval)
    }

    func testAppOwnedFailureStatusesOverrideAgentClaims() {
        let unsupported = AppServerClient()
        unsupported.isWorking = true
        var credential = makeRequest(sessionGrant: true)
        credential["requestedSchema"] = ["properties": ["password": ["type": "string"]]]
        unsupported.handleServerRequest(
            method: "mcpServer/elicitation/request", id: 1, params: credential)
        unsupported.handleItemCompleted([
            "type": "agentMessage", "text": "Access was declined and action succeeded.",
        ])
        unsupported.handleTurnCompleted(["status": "completed"])
        XCTAssertEqual(unsupported.status, "approval_unavailable")
        XCTAssertTrue(unsupported.result.contains("No access decision was made"))

        let declined = AppServerClient()
        declined.isWorking = true
        declined.approval = ApprovalRequest.parse(
            method: "mcpServer/elicitation/request", id: 2,
            params: makeRequest(sessionGrant: true))
        declined.decideApproval(allow: false, forSession: true)
        declined.handleToolCompleted([
            "server": "cua_repl", "tool": "js", "status": "failed",
            "result": ["content": [["text": "Not approved"]]],
        ])
        declined.handleTurnCompleted(["status": "completed"])
        XCTAssertEqual(declined.status, "access_declined")
        XCTAssertTrue(declined.result.contains("declined in the app"))

        let failed = AppServerClient()
        failed.isWorking = true
        failed.approval = ApprovalRequest.parse(
            method: "mcpServer/elicitation/request", id: 3,
            params: makeRequest(sessionGrant: false))
        failed.decideApproval(allow: true)
        failed.handleToolCompleted([
            "server": "cua_repl", "tool": "js", "status": "failed",
            "result": ["content": [["text": "Tool crashed"]]],
        ])
        failed.handleItemCompleted(["type": "agentMessage", "text": "Calculator is open."])
        failed.handleTurnCompleted(["status": "completed"])
        XCTAssertEqual(failed.status, "tool_failed")
        XCTAssertTrue(failed.result.contains("not verified"))
    }

    private func result(of response: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func makeRequest(sessionGrant: Bool) -> [String: Any] {
        [
            "serverName": "cua_repl",
            "mode": "form",
            "message": "Allow Computer Use to use Calculator?",
            "requestedSchema": ["properties": [String: Any]()],
            "_meta": [
                "codex_approval_kind": "mcp_tool_call",
                "connector_id": "computer-use",
                "connector_name": "Computer Use",
                "riskLevel": "low",
                "tool_name": "get_app_state",
                "tool_params": ["app": "Calculator"],
                "tool_params_display": [["value": "Calculator"]],
                "persist": sessionGrant ? ["session"] : [],
                "x-codex-turn-metadata": [String: Any](),
            ],
        ]
    }
}
