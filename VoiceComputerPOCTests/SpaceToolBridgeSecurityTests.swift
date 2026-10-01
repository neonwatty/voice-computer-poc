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
        bridge.onRequest = { request, reply in
            callbacks += 1
            reply(
                .failure("unexpected", commandID: "one", direction: request.direction, message: "No action"))
        }
        XCTAssertEqual(try queryFromPython(bridge)["status"] as? String, "unauthorized")
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
        client.isWorking = true
        var response: SpaceToolResult?
        client.handleSpaceToolRequest(.init(sessionID: bridge.sessionID, direction: "right")) {
            response = $0
        }
        XCTAssertEqual(response?.status, "rejected")
        XCTAssertNil(client.toolReply)
        client.handleItemStarted([
            "type": "mcpToolCall", "id": "item-one", "server": "desktop_tool",
            "tool": "switch_space",
        ])
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

    func testPinnedMCPHelperCanReturnTypedNoAction() throws {
        let bridge = try XCTUnwrap(SpaceToolBridge())
        defer { bridge.stop() }
        bridge.serverPID = getpid()
        var callbacks = 0
        bridge.onRequest = { request, reply in
            callbacks += 1
            reply(.failure("rejected", commandID: "one", direction: request.direction, message: "No action"))
        }
        let (task, input, output) = try launchHelper(bridge)
        defer { if task.isRunning { task.terminate() } }
        var pinned = false
        for _ in 0..<100 {
            if bridge.pinReadyHelper() {
                pinned = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(pinned)
        XCTAssertEqual(bridge.helperPID, task.processIdentifier)
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
