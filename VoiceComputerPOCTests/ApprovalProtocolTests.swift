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

    private func result(of response: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(response["result"] as? [String: Any])
    }

    private func makeRequest(sessionGrant: Bool) -> [String: Any] {
        [
            "mode": "form",
            "message": "Allow Computer Use to use Calculator?",
            "requestedSchema": ["properties": [String: Any]()],
            "_meta": [
                "connector_id": "computer-use",
                "connector_name": "Computer Use",
                "tool_name": "get_app_state",
                "tool_params_display": [["value": "Calculator"]],
                "persist": sessionGrant ? ["session"] : [],
            ],
        ]
    }
}
