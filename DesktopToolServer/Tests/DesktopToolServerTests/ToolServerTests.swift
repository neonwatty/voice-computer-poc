import MCP
import XCTest

@testable import DesktopToolServer

final class ToolServerTests: XCTestCase {
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
