import Darwin
import Foundation
import XCTest

@testable import VoiceComputerPOC

final class SpaceToolBridgeSecurityTests: XCTestCase {
    func testSameSessionNonHelperDescendantCannotReachNativeCallback() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getpid()
        var callbacks = 0
        bridge.onRequest = { request, _, reply in
            callbacks += 1
            reply(
                .failure("unexpected", commandID: "one", direction: request.direction, message: "No action"))
        }
        XCTAssertEqual(try queryFromPython(bridge)["status"] as? String, "unauthorized")
        XCTAssertEqual(callbacks, 0)
    }
    func testExactBinaryWithWrongParentCannotReachBridgeCallback() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getppid()
        var callbacks = 0
        bridge.onRequest = { _, _, _ in callbacks += 1 }
        let (task, input, output) = try launchHelper(bridge)
        defer { if task.isRunning { task.terminate() } }
        XCTAssertNil(bridge.eligiblePeer(task.processIdentifier))
        let call = try callTool(input: input, output: output)
        let result = try XCTUnwrap(call["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let typed = try JSONDecoder().decode(SpaceToolResult.self, from: Data(text.utf8))
        XCTAssertFalse(typed.verified)
        XCTAssertNotEqual(typed.status, "verified")
        XCTAssertEqual(callbacks, 0)
    }
    func testMatchingCommandWithoutObservedMCPItemCannotStartNativeAction() throws {
        let client = AppServerClient()
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        client.spaceToolBridge = bridge
        client.activeCommandID = "one"
        client.expectedToolDirection = .right
        client.requestedToolDirection = .right
        client.turnID = "turn-one"
        client.isWorking = true
        var response: SpaceToolResult?
        client.handleSpaceToolRequest(
            .init(sessionID: bridge.sessionID, direction: "right"),
            peer: .init(pid: getpid(), startSecond: 0, startMicrosecond: 0)
        ) {
            response = $0
        }
        XCTAssertEqual(response?.status, "rejected")
        XCTAssertNil(client.toolReply)
        client.handleItemStarted(
            [
                "type": "mcpToolCall", "id": "item-one", "server": "desktop_tool",
                "tool": "switch_space", "arguments": ["direction": "right"],
            ], eventTurnID: "turn-one")
        XCTAssertEqual(client.activeMCPToolItemID, "item-one")
        let typed = SpaceToolResult.failure(
            "rejected", commandID: "one", direction: "right", message: "No action")
        let text = String(decoding: try JSONEncoder().encode(typed), as: UTF8.self)
        client.handleToolCompleted([
            "type": "mcpToolCall", "id": "other-item", "server": "desktop_tool",
            "tool": "switch_space", "status": "completed",
            "result": ["content": [["text": text]], "isError": false],
        ])
        XCTAssertFalse(client.toolCallCompleted)
        XCTAssertNil(client.toolResult)
    }
    func testLiveMCPHelperCanReturnTypedNoAction() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getpid()
        var callbacks = 0
        bridge.onRequest = { request, peer, reply in
            callbacks += 1
            XCTAssertTrue(bridge.bind(peer, commandID: "one", itemID: "item-one"))
            XCTAssertTrue(bridge.isBoundPeerAlive(commandID: "one", itemID: "item-one"))
            reply(.failure("rejected", commandID: "one", direction: request.direction, message: "No action"))
        }
        let (task, input, output) = try launchHelper(bridge)
        defer { if task.isRunning { task.terminate() } }
        XCTAssertNotNil(bridge.eligiblePeer(task.processIdentifier))
        XCTAssertEqual(try queryFromPython(bridge)["status"] as? String, "unauthorized")

        let callResponse = try callTool(input: input, output: output)
        let result = try XCTUnwrap(callResponse["result"] as? [String: Any])
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        let typed = try JSONDecoder().decode(SpaceToolResult.self, from: Data(text.utf8))
        XCTAssertEqual(typed.status, "rejected")
        XCTAssertFalse(typed.verified)
        XCTAssertEqual(callbacks, 1)
    }
    func testWrongPathAndStaleStartIdentityFailClosed() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getpid()
        let (task, _, _) = try launchHelper(bridge)
        defer { if task.isRunning { task.terminate() } }
        let correctPath = try XCTUnwrap(bridge.expectedExecutablePath)
        bridge.expectedExecutablePath = "/tmp/not-the-desktop-tool/DesktopToolServer"
        XCTAssertNil(bridge.eligiblePeer(task.processIdentifier))
        bridge.expectedExecutablePath = correctPath
        let identity = try XCTUnwrap(bridge.eligiblePeer(task.processIdentifier))
        XCTAssertTrue(bridge.bind(identity, commandID: "one", itemID: "item-one"))
        XCTAssertTrue(bridge.isBoundPeerAlive(commandID: "one", itemID: "item-one"))
        #if DEBUG
            bridge.invalidateStartIdentityForTesting()
            XCTAssertFalse(bridge.isBoundPeerAlive(commandID: "one", itemID: "item-one"))
        #endif
    }
    func testMultipleMatchingHelpersCannotBePinned() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getpid()
        let (first, _, _) = try launchHelper(bridge)
        defer { if first.isRunning { first.terminate() } }
        let (second, _, _) = try launchHelper(bridge)
        defer { if second.isRunning { second.terminate() } }
        XCTAssertNil(bridge.eligiblePeer(first.processIdentifier))
        XCTAssertNil(bridge.eligiblePeer(second.processIdentifier))
    }
    func testStatusHelperMayExitBeforeActingHelperBinds() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getpid()
        let (statusHelper, _, _) = try launchHelper(bridge)
        XCTAssertNotNil(bridge.eligiblePeer(statusHelper.processIdentifier))
        statusHelper.terminate()
        statusHelper.waitUntilExit()
        XCTAssertNil(bridge.eligiblePeer(statusHelper.processIdentifier))
        let (actingHelper, _, _) = try launchHelper(bridge)
        defer { if actingHelper.isRunning { actingHelper.terminate() } }
        let identity = try XCTUnwrap(bridge.eligiblePeer(actingHelper.processIdentifier))
        XCTAssertTrue(bridge.bind(identity, commandID: "one", itemID: "item-one"))
        XCTAssertFalse(bridge.bind(identity, commandID: "one", itemID: "item-one"))
        XCTAssertTrue(bridge.isBoundPeerAlive(commandID: "one", itemID: "item-one"))
        bridge.revoke()
        XCTAssertFalse(bridge.isBoundPeerAlive(commandID: "one", itemID: "item-one"))
    }
    func testPendingAndDeclinedApprovalRejectLivePeer() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getpid()
        let (task, _, _) = try launchHelper(bridge)
        defer { if task.isRunning { task.terminate() } }
        let peer = try XCTUnwrap(bridge.eligiblePeer(task.processIdentifier))
        let client = AppServerClient()
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
            turnID: "turn-one", direction: .right)
        var result: SpaceToolResult?
        client.handleSpaceToolRequest(.init(sessionID: bridge.sessionID, direction: "right"), peer: peer) {
            result = $0
        }
        XCTAssertEqual(result?.status, "rejected")
        client.spaceToolApproval?.state = .declined
        client.handleSpaceToolRequest(.init(sessionID: bridge.sessionID, direction: "right"), peer: peer) {
            result = $0
        }
        XCTAssertEqual(result?.status, "rejected")
        XCTAssertFalse(bridge.isBoundPeerAlive(commandID: "one", itemID: "item-one"))
    }

    func testColdPreflightRunsOffMainAndResolvesExecutable() {
        let preflight = DesktopToolPreflight()
        let responsive = expectation(description: "main queue remained responsive")
        let finished = expectation(description: "preflight completed")
        var resolved: String?
        preflight.start { outcome in
            if case .ready(let path) = outcome { resolved = path }
            finished.fulfill()
        }
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive, finished], timeout: 90)
        XCTAssertNotNil(resolved)
        XCTAssertTrue(resolved.map(FileManager.default.isExecutableFile(atPath:)) ?? false)
    }

    func testPreflightTimeoutAndCancellationFailClosed() {
        for (timeout, cancel) in [(0.05, false), (2.0, true)] {
            let preflight = DesktopToolPreflight(
                command: URL(fileURLWithPath: "/bin/sleep"), arguments: ["2"], timeout: timeout)
            let finished = expectation(description: "preflight failed closed")
            preflight.start { outcome in
                if case .failed = outcome { finished.fulfill() }
            }
            if cancel { preflight.cancel() }
            wait(for: [finished], timeout: 3)
        }
    }

    private func launchHelper(_ bridge: SpaceToolBridge) throws -> (Process, Pipe, Pipe) {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DesktopToolServer")
        let binary = package.appendingPathComponent(".build/debug/DesktopToolServer")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: binary.path))
        let task = Process()
        task.executableURL = binary
        let input = Pipe()
        let output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = Pipe()
        var environment = ProcessInfo.processInfo.environment
        environment["SPACE_SESSION_ID"] = bridge.sessionID
        environment["SPACE_BRIDGE_PATH"] = bridge.socketPath
        task.environment = environment
        try task.run()
        bridge.expectedExecutablePath = binary.resolvingSymlinksInPath().path
        return (task, input, output)
    }

    private func callTool(input: Pipe, output: Pipe) throws -> [String: Any] {
        let initialize = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"bridge-test","version":"1"}}}

            """
        try input.fileHandleForWriting.write(contentsOf: Data(initialize.utf8))
        let completion = expectation(description: "MCP helper completed")
        var call: [String: Any]?
        var outputData = Data()
        DispatchQueue.global().async {
            var buffer = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                outputData.append(data)
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer.prefix(upTo: newline))
                    buffer.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { continue }
                    if object["id"] as? Int == 1 {
                        let request = """
                            {"jsonrpc":"2.0","method":"notifications/initialized"}
                            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"switch_space","arguments":{"direction":"right"}}}

                            """
                        try? input.fileHandleForWriting.write(contentsOf: Data(request.utf8))
                    } else if object["id"] as? Int == 2 {
                        call = object
                        completion.fulfill()
                        return
                    }
                }
            }
            completion.fulfill()
        }
        wait(for: [completion], timeout: 10)
        try? input.fileHandleForWriting.close()
        let callResponse = try XCTUnwrap(call, String(decoding: outputData, as: UTF8.self))
        return callResponse
    }

    private func queryFromPython(_ bridge: SpaceToolBridge) throws -> [String: Any] {
        let script = """
            import json,socket,sys
            s=socket.socket(socket.AF_UNIX)
            s.connect(sys.argv[1])
            s.sendall((json.dumps({'sessionID':sys.argv[2],'direction':'right'})+'\\n').encode())
            print(s.recv(4096).decode())
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", script, bridge.socketPath, bridge.sessionID]
        let output = Pipe()
        task.standardOutput = output
        let completion = expectation(description: "Non-helper descendant answered")
        var data = Data()
        DispatchQueue.global().async {
            do {
                try task.run()
                data = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
            } catch { XCTFail(error.localizedDescription) }
            completion.fulfill()
        }
        wait(for: [completion], timeout: 5)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
