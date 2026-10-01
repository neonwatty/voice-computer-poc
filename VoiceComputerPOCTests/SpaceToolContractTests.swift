import Darwin
import XCTest

@testable import VoiceComputerPOC

final class SpaceToolContractTests: XCTestCase {
    func testAgentRouteIsExplicitAndPreservesNativePhrases() {
        XCTAssertEqual(SpaceToolRequest.direction(for: "agent switch desktop space right"), .right)
        XCTAssertEqual(SpaceToolRequest.direction(for: " AGENT SWITCH DESKTOP SPACE LEFT "), .left)
        XCTAssertNil(SpaceToolRequest.direction(for: "switch to the next desktop Space"))
        XCTAssertNil(SpaceToolRequest.direction(for: "agent switch desktop space right twice"))
        XCTAssertEqual(SpaceCommand(phrase: "switch to the next desktop Space"), .one(.right))
    }

    func testVerifiedRequiresTargetIDAndNotification() {
        let valid = SpaceToolResult(
            commandID: "one", status: "verified", direction: "right", beforeID: 1,
            expectedID: 2, afterID: 2, notificationObserved: true, message: "Moved")
        XCTAssertTrue(valid.verified)
        XCTAssertFalse(
            SpaceToolResult(
                commandID: "one", status: "verified", direction: "right", beforeID: 1,
                expectedID: 2, afterID: 2, notificationObserved: false, message: "Stale"
            ).verified)
        XCTAssertFalse(
            SpaceToolResult(
                commandID: "one", status: "verified", direction: "right", beforeID: 1,
                expectedID: 2, afterID: 1, notificationObserved: true, message: "Wrong"
            ).verified)
        XCTAssertFalse(
            SpaceToolResult.failure(
                "timeout", commandID: "one", direction: "right",
                message: "Timed out"
            ).verified)
    }

    func testPreflightCannotStartWithoutPermissionStateAndNeighbor() {
        let first = SpaceSnapshot(current: 1, ordered: [1, 2])
        XCTAssertEqual(
            SpaceToolSafety.preflight(trusted: false, snapshot: first, direction: .right),
            .permissionMissing)
        XCTAssertEqual(
            SpaceToolSafety.preflight(trusted: true, snapshot: nil, direction: .right),
            .stateMissing)
        XCTAssertEqual(
            SpaceToolSafety.preflight(trusted: true, snapshot: first, direction: .left),
            .noAdjacentSpace)
        XCTAssertEqual(
            SpaceToolSafety.preflight(trusted: true, snapshot: first, direction: .right),
            .ready(2))
    }

    func testStaleStateAndTimeoutNeverVerify() {
        XCTAssertEqual(
            SpaceToolSafety.verification(
                expected: 2, after: 1, eventObserved: true, deadlineReached: false),
            .pending)
        XCTAssertEqual(
            SpaceToolSafety.verification(
                expected: 2, after: 2, eventObserved: false, deadlineReached: true),
            .timedOut)
        XCTAssertEqual(
            SpaceToolSafety.verification(
                expected: 2, after: 2, eventObserved: true, deadlineReached: false),
            .verified)
        XCTAssertNil(SpaceToolSafety.nextStep(after: .timedOut, remaining: [.left]))
        XCTAssertNil(SpaceToolSafety.nextStep(after: .pending, remaining: [.left]))
        XCTAssertEqual(SpaceToolSafety.nextStep(after: .verified, remaining: [.left]), .left)
    }

    func testBridgeRejectsMissingSessionBeforeNativeAction() {
        let client = AppServerClient()
        client.activeCommandID = "one"
        client.expectedToolDirection = .right
        client.isWorking = true
        var result: SpaceToolResult?
        client.handleSpaceToolRequest(
            .init(sessionID: "stale", direction: "right"),
            peer: .init(pid: getpid(), startSecond: 0, startMicrosecond: 0)
        ) { result = $0 }
        XCTAssertEqual(result?.status, "rejected")
        XCTAssertNil(client.toolReply)
    }

    func testInterruptionReturnsTypedNonSuccess() {
        let client = AppServerClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.activeToolDirection = .right
        var reply: SpaceToolResult?
        client.toolReply = { reply = $0 }
        client.stop()
        XCTAssertEqual(reply?.status, "stopped")
        XCTAssertFalse(reply?.verified ?? true)
    }

    func testWrongDirectionAndLateCommandCannotStartAction() throws {
        let client = AppServerClient()
        let bridge = try XCTUnwrap(SpaceToolBridge())
        client.spaceToolBridge = bridge
        client.activeCommandID = "one"
        client.expectedToolDirection = .right
        client.isWorking = true
        var response: SpaceToolResult?
        client.handleSpaceToolRequest(
            .init(sessionID: bridge.sessionID, direction: "left"),
            peer: .init(pid: getpid(), startSecond: 0, startMicrosecond: 0)
        ) { response = $0 }
        XCTAssertEqual(response?.status, "rejected")
        XCTAssertNil(client.toolReply)
        client.isWorking = false
        client.handleSpaceToolRequest(
            .init(sessionID: bridge.sessionID, direction: "right"),
            peer: .init(pid: getpid(), startSecond: 0, startMicrosecond: 0)
        ) { response = $0 }
        XCTAssertEqual(response?.status, "rejected")
        bridge.stop()
    }

    func testFailureInvalidatesLateNativeSuccess() {
        let client = AppServerClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.activeToolDirection = .right
        var response: SpaceToolResult?
        client.toolReply = { response = $0 }
        client.fail("Server failed")
        XCTAssertEqual(response?.status, "failed")
        client.completeNativeSpace(
            status: "completed", verification: "verified", message: "Moved",
            details: [
                "direction": "right", "space_target_id": "2", "space_after_id": "2",
                "space_change_events": "1",
            ])
        XCTAssertEqual(client.status, "Error")
        XCTAssertEqual(client.result, "Server failed")
        XCTAssertFalse(response?.verified ?? true)
    }

    func testFailedTurnCannotDisplayVerifiedResult() {
        let client = AppServerClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.requestedToolDirection = .right
        client.toolCallObserved = true
        client.toolCallCompleted = true
        client.toolResult = SpaceToolResult(
            commandID: "one", status: "verified", direction: "right", beforeID: 1,
            expectedID: 2, afterID: 2, notificationObserved: true, message: "Moved")
        client.handleTurnCompleted(["status": "failed"])
        XCTAssertEqual(client.status, "Space unverified")
        XCTAssertNotEqual(client.result, "Moved")
    }

    func testAgentToolFailureDisplaysTypedNonSuccess() throws {
        let client = AppServerClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.requestedToolDirection = .right
        client.toolCallObserved = true
        client.activeMCPToolItemID = "item-one"
        let failure = SpaceToolResult.failure(
            "bridge_unavailable", commandID: "unknown", direction: "right",
            message: "Bridge connect failed or timed out.")
        let text = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
        client.handleToolCompleted([
            "type": "mcpToolCall", "id": "item-one", "server": "desktop_tool", "tool": "switch_space",
            "status": "failed", "result": ["content": [["type": "text", "text": text]]],
        ])
        client.handleTurnCompleted(["status": "completed"])
        XCTAssertEqual(client.toolResult, failure)
        XCTAssertEqual(client.result, failure.message)
        XCTAssertEqual(client.status, "Space unverified")
        XCTAssertFalse(client.toolCallCompleted)
    }

    func testMissingToolDoesNotBlockGeneralTurn() {
        let client = AppServerClient()
        client.pending[1] = .mcpStatus
        client.selectedModel = "gpt-5.6-sol"
        client.serverDirectory = URL(fileURLWithPath: "/tmp")
        client.queuedPhrase = "Open Calculator"
        client.isWorking = true
        client.handleResponse(id: 1, message: ["result": ["data": []]])
        XCTAssertTrue(client.pending.values.contains { $0 == .thread })
    }

    func testMissingToolFailsSpaceCommand() {
        let client = AppServerClient()
        client.pending[1] = .mcpStatus
        client.threadID = "thread"
        client.queuedPhrase = "agent switch desktop space right"
        client.requestedToolDirection = .right
        client.isWorking = true
        client.handleResponse(id: 1, message: ["result": ["data": []]])
        XCTAssertEqual(client.status, "Error")
        XCTAssertFalse(client.isWorking)
    }

    func testSpacePromptIsIsolatedFromGeneralComputerUseRule() {
        let client = AppServerClient()
        let exact = client.turnInstruction(for: "agent switch desktop space right")
        XCTAssertTrue(exact.contains("mcp__desktop_tool__switch_space"))
        XCTAssertTrue(exact.contains("\"direction\":\"right\""))
        XCTAssertFalse(exact.contains("Use only mcp__cua_repl.js"))
        let near = client.turnInstruction(for: "agent switch desktop space right twice")
        XCTAssertTrue(near.contains("Use only mcp__cua_repl.js"))
        XCTAssertFalse(near.contains("mcp__desktop_tool__switch_space"))
    }

    func testNativeCallbackDeadlineFailsAndIgnoresLaterResult() {
        let client = AppServerClient()
        client.isWorking = true
        client.activeCommandID = "one"
        client.activeToolDirection = .right
        var response: SpaceToolResult?
        client.toolReply = { response = $0 }
        client.handleSpaceToolTimeout(commandID: "wrong")
        XCTAssertNil(response)
        client.handleSpaceToolTimeout(commandID: "one")
        XCTAssertEqual(response?.status, "failed")
        client.completeNativeSpace(
            status: "completed", verification: "verified", message: "Moved",
            details: [
                "direction": "right", "space_target_id": "2", "space_after_id": "2",
                "space_change_events": "1",
            ])
        XCTAssertEqual(client.status, "Error")
        XCTAssertFalse(response?.verified ?? true)
    }

    func testBridgeAcceptsOnlyServerDescendant() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.onRequest = { request, _, reply in
            reply(
                .failure(
                    "rejected", commandID: "one", direction: request.direction,
                    message: "No action was taken."))
        }
        bridge.serverPID = 999_999
        XCTAssertEqual(try queryBridge(bridge)["status"] as? String, "unauthorized")
        bridge.serverPID = getpid()
        XCTAssertEqual(try queryBridge(bridge)["status"] as? String, "unauthorized")
    }

    private func queryBridge(_ bridge: SpaceToolBridge) throws -> [String: Any] {
        let script = """
            import json,socket,sys
            s=socket.socket(socket.AF_UNIX)
            s.connect(sys.argv[1])
            s.sendall((json.dumps({'sessionID':sys.argv[2],'direction':'right'})+'\\n').encode())
            data=s.recv(4096)
            print(data.decode())
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", script, bridge.socketPath, bridge.sessionID]
        let output = Pipe()
        task.standardOutput = output
        let expectation = expectation(description: "Bridge answered")
        var data = Data()
        DispatchQueue.global().async {
            do {
                try task.run()
                data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
            } catch { XCTFail(error.localizedDescription) }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
