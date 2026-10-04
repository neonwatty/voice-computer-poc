import MCP
import XCTest

@testable import DesktopToolServer

final class ToolServerTests: XCTestCase {
    func testCodexInitializeWithObjectExperimentalCapability() throws {
        // Captured from Codex 0.155.0-alpha.16.4 on the Air during a no-tool turn.
        let frame = Data(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"codex-mcp-client","version":"0.155.0-alpha.16.4"},"capabilities":{"elicitation":{"form":{},"url":{}},"experimental":{"codex/auth-change":{}}}}}"#
                .utf8)
        let parameters = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: frame) as? [String: Any])?["params"])
        let original = try JSONSerialization.data(withJSONObject: parameters)
        XCTAssertThrowsError(try JSONDecoder().decode(Initialize.Parameters.self, from: original))

        let compatible = InitializeCompatibilityTransport.compatibleInitialize(frame)
        let normalized = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: compatible) as? [String: Any])?["params"])
        let decoded = try JSONDecoder().decode(
            Initialize.Parameters.self,
            from: JSONSerialization.data(withJSONObject: normalized))
        XCTAssertEqual(decoded.protocolVersion, "2025-06-18")
        XCTAssertEqual(decoded.clientInfo.name, "codex-mcp-client")
        XCTAssertNotNil(decoded.capabilities.elicitation?.form)
        XCTAssertNil(decoded.capabilities.experimental)
    }

    func testCompatibilityLeavesToolsListAndMalformedFramesUntouched() {
        for frame in [
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"feature":"text"}}}}"#,
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":"invalid"}"#,
        ] {
            let data = Data(frame.utf8)
            XCTAssertEqual(InitializeCompatibilityTransport.compatibleInitialize(data), data)
        }
    }

    func testCompatibilityRetainsStringExperimentalEntries() throws {
        let frame = Data(
            #"{"method":"initialize","params":{"capabilities":{"experimental":{"future":"supported","codex/auth-change":{}}}}}"#
                .utf8)
        let compatible = InitializeCompatibilityTransport.compatibleInitialize(frame)
        let params = try XCTUnwrap(
            (JSONSerialization.jsonObject(with: compatible) as? [String: Any])?["params"])
        let decoded = try JSONDecoder().decode(
            Initialize.Parameters.self,
            from: JSONSerialization.data(withJSONObject: params))
        XCTAssertEqual(decoded.capabilities.experimental, ["future": "supported"])
    }

    func testInvalidDirectionsNeverReachBridge() {
        var calls = 0
        for arguments: [String: Value] in [
            [:], ["direction": "up"],
            ["direction": "left", "steps": 2],
        ] {
            let result = ToolServer.call(arguments: arguments) { _ in
                calls += 1
                return .failure("unexpected", "left", "Called")
            }
            XCTAssertEqual(result.status, "invalid_direction")
        }
        XCTAssertEqual(calls, 0)
    }

    func testUnverifiedBridgeSuccessCannotPass() {
        let result = ToolServer.call(arguments: ["direction": "right"]) { direction in
            .init(
                commandID: "one", status: "verified", direction: direction,
                beforeID: 1, expectedID: 2, afterID: 2, notificationObserved: false,
                message: "untrusted")
        }
        XCTAssertEqual(result.status, "unverified")
        XCTAssertFalse(result.verified)
    }

    func testProtocolAdvertisesOneToolAndTypedFailure() {
        XCTAssertEqual(ToolServer.definition().name, "switch_space")
        let invalid = ToolServer.call(arguments: ["direction": "up"]) { _ in
            XCTFail("Invalid direction reached bridge")
            return .failure("unexpected", "up", "Unexpected")
        }
        XCTAssertEqual(ToolServer.toolResponse(invalid).isError, true)
    }

    func testMissingBridgeReturnsTypedNonSuccess() {
        let result = ToolServer.call(arguments: ["direction": "right"]) { direction in
            .failure("bridge_unavailable", direction, "No bridge")
        }
        XCTAssertEqual(result.status, "bridge_unavailable")
        XCTAssertEqual(ToolServer.toolResponse(result).isError, true)
    }
}
