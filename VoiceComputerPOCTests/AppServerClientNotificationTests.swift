import Darwin
import Foundation
import XCTest

@testable import VoiceComputerPOC

final class AppServerClientNotificationTests: XCTestCase {
    func testSystemSpaceNotificationDoesNotVerifyNativeCommand() {
        let client = makeClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.observeSystemSpaceNotification()
        XCTAssertEqual(client.spaceChangeCount, 1)
        XCTAssertFalse(client.toolCallCompleted)
        let event = client.diagnosticEntries.last { $0.event == "space_changed" }
        XCTAssertEqual(event?.details["causality"], "system_observation")
        XCTAssertEqual(event?.details["command_id"], "one")
        XCTAssertEqual(
            SpaceToolSafety.verification(
                expected: 200, after: 201, eventObserved: true, deadlineReached: false),
            .pending)
    }

    #if DEBUG
        func testLiveProbeReturnsBeforeNativeAndRejectsDuplicateRequest() throws {
            let bridge = try XCTUnwrap(SpaceToolBridge())
            defer { bridge.stop() }
            bridge.serverPID = getpid()
            let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("DesktopToolServer")
            let binary = package.appendingPathComponent(".build/debug/DesktopToolServer")
            let task = Process()
            task.executableURL = binary
            task.standardInput = Pipe()
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try task.run()
            defer { if task.isRunning { task.terminate() } }
            bridge.expectedExecutablePath = binary.resolvingSymlinksInPath().path
            let peer = try XCTUnwrap(bridge.eligiblePeer(task.processIdentifier))
            let client = makeClient()
            client.spaceToolBridge = bridge
            client.isWorking = true
            client.activeCommandID = "one"
            client.turnID = "turn-one"
            client.expectedToolDirection = .right
            client.requestedToolDirection = .right
            client.handleItemStarted(
                [
                    "type": "mcpToolCall", "id": "item-one", "server": "desktop_tool",
                    "tool": "switch_space", "arguments": ["direction": "right"],
                ], eventTurnID: "turn-one")
            client.spaceToolApproval = SpaceToolApproval(
                requestID: 42, commandID: "one", itemID: "item-one",
                turnID: "turn-one", direction: .right, state: .accepted)
            setenv("VOICE_COMPUTER_LIVE_BRIDGE_PROBE", "1", 1)
            defer { unsetenv("VOICE_COMPUTER_LIVE_BRIDGE_PROBE") }
            var results = [SpaceToolResult]()
            for _ in 0..<2 {
                client.handleSpaceToolRequest(
                    .init(sessionID: bridge.sessionID, direction: "right"), peer: peer
                ) { results.append($0) }
            }
            XCTAssertEqual(results.map(\.status), ["probe_no_action", "rejected"])
            XCTAssertFalse(results[0].verified)
            XCTAssertEqual(results[0].commandID, "one")
            XCTAssertFalse(client.diagnosticEntries.contains { $0.event == "native_space_requested" })
            XCTAssertFalse(client.diagnosticEntries.contains { $0.event == "native_space_ax_pressed" })
        }
    #endif

    func testReleaseBuildCannotEnableLiveBridgeProbe() {
        #if !DEBUG
            setenv("VOICE_COMPUTER_LIVE_BRIDGE_PROBE", "1", 1)
            defer { unsetenv("VOICE_COMPUTER_LIVE_BRIDGE_PROBE") }
            XCTAssertFalse(AppServerClient.liveBridgeProbe)
        #endif
    }

    func testSpaceItemRequiresCurrentTurnExactToolIDAndDirection() {
        let client = makeClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.turnID = "turn-one"
        client.requestedToolDirection = .right
        let valid: [String: Any] = [
            "type": "mcpToolCall", "id": "item-one", "server": "desktop_tool",
            "tool": "switch_space", "arguments": ["direction": "right"],
        ]
        let invalid: [[String: Any]] = [
            valid.merging(["server": "other"]) { _, new in new },
            valid.merging(["tool": "other"]) { _, new in new },
            valid.merging(["id": ""]) { _, new in new },
            valid.merging(["arguments": NSNull()]) { _, new in new },
            valid.merging(["arguments": ["direction": "left"]]) { _, new in new },
            valid.merging(["arguments": ["direction": "right", "extra": true]]) { _, new in new },
        ]
        for item in invalid { client.handleItemStarted(item, eventTurnID: "turn-one") }
        client.handleItemStarted(valid)
        XCTAssertNil(client.activeMCPToolItemID)
        client.handleItemStarted(valid, eventTurnID: "stale-turn")
        XCTAssertNil(client.activeMCPToolItemID)
        XCTAssertFalse(client.toolCallObserved)
        client.handleItemStarted(valid, eventTurnID: "turn-one")
        XCTAssertEqual(client.activeMCPToolItemID, "item-one")
        XCTAssertEqual(client.activeMCPToolTurnID, "turn-one")
        XCTAssertEqual(client.activeMCPToolDirection, .right)
    }

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

    func testCalculatorFocusHandoffRequiresCompletedComputerUseTool() {
        let client = makeClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.turnID = "turn-one"
        client.focusTargetBundleID = "com.apple.calculator"

        let turn = ["id": "turn-one", "status": "completed"]
        XCTAssertFalse(
            client.requestCalculatorFocusAfterTool(
                turn, frontmostBundleID: "com.openai.codex"))
        client.record(
            "tool_completed",
            details: [
                "server": "cua_repl", "status": "completed", "result_is_error": "false",
            ])
        client.generalTurnFailure = .accessDeclined
        XCTAssertFalse(
            client.requestCalculatorFocusAfterTool(
                turn, frontmostBundleID: "com.openai.codex"))
        XCTAssertFalse(
            client.diagnosticEntries.contains {
                $0.event == "focus_activation_requested"
            })
    }

    private func makeClient() -> AppServerClient {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppServerClient(logDirectory: directory)
    }
}
