import Foundation
import XCTest

@testable import VoiceComputerPOC

final class AppServerClientNotificationTests: XCTestCase {
    func testFailedToolResultIsLoggedWithError() {
        let client = makeClient()
        client.handleNotification(
            method: "item/completed",
            params: [
                "item": [
                    "type": "mcpToolCall", "id": "tool-1", "server": "computer-use",
                    "tool": "js", "status": "completed",
                    "result": ["isError": true, "content": [["text": "Window not found"]]],
                ]
            ])

        let entry = client.diagnosticEntries.last { $0.event == "tool_completed" }
        XCTAssertEqual(entry?.details["result_is_error"], "true")
        XCTAssertEqual(entry?.details["error"], "Window not found")
    }

    func testCompletedTurnWithoutSpaceChangeRemainsUnverified() {
        let client = makeClient()
        client.isWorking = true
        client.spaceCountAtTurnStart = client.spaceChangeCount
        client.result = "I switched Spaces."

        client.handleNotification(
            method: "turn/completed", params: ["turn": ["id": "turn-1", "status": "completed"]])

        XCTAssertFalse(client.isWorking)
        XCTAssertTrue(client.result.contains("unverified"))
        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "command_finished" }?.details["verification"],
            "unverified")
    }

    func testCompletedTurnWithSpaceChangeIsVerified() {
        let client = makeClient()
        client.isWorking = true
        client.spaceCountAtTurnStart = client.spaceChangeCount
        client.spaceChangeCount += 1

        client.handleNotification(
            method: "turn/completed", params: ["turn": ["id": "turn-2", "status": "completed"]])

        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "command_finished" }?.details["verification"],
            "verified")
    }

    private func makeClient() -> AppServerClient {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppServerClient(logDirectory: directory)
    }
}
