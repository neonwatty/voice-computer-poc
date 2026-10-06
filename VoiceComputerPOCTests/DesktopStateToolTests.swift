import Foundation
import XCTest

@testable import VoiceComputerPOC

final class DesktopStateToolTests: XCTestCase {
    func testSupportedModelSelectionRejectsStaleCatalog() {
        XCTAssertEqual(
            AppServerClient.preferredAvailableModel(["gpt-5.4", "gpt-6.1-sol"]), "gpt-6.1-sol")
        XCTAssertNil(AppServerClient.preferredAvailableModel(["gpt-5.4", "gpt-5.3-codex"]))
    }

    func testExactReadPhraseAndCoherentObservation() {
        XCTAssertTrue(DesktopStateToolRequest.matches("agent get desktop state"))
        XCTAssertFalse(DesktopStateToolRequest.matches("agent get desktop state and switch right"))
        let first = SpaceSnapshot(current: 5, ordered: [5, 6])
        var reads = 0
        let observed = DesktopStateToolResult.observe(
            snapshot: {
                reads += 1
                return first
            }, frontmost: { "com.apple.finder" })
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(observed.verified)
        XCTAssertEqual(observed.currentMainSpaceID, 5)
        XCTAssertEqual(observed.orderedMainSpaceIDs, [5, 6])
        XCTAssertEqual(observed.displayScope, "Main")
        let changed = DesktopStateToolResult.observe(
            snapshot: {
                reads += 1
                return reads.isMultiple(of: 2)
                    ? SpaceSnapshot(current: 6, ordered: [5, 6]) : first
            }, frontmost: { "com.apple.finder" })
        XCTAssertFalse(changed.verified)
        XCTAssertNil(changed.currentMainSpaceID)
        let ambiguous = DesktopStateToolResult.observe(
            snapshot: { nil }, frontmost: { "com.apple.finder" },
            ambiguousDisplay: { true })
        XCTAssertEqual(ambiguous.status, "ambiguous_display")
        XCTAssertNil(ambiguous.orderedMainSpaceIDs)
    }

    func testReadApprovalRequiresOneActiveCorrelatedTool() throws {
        let params: [String: Any] = [
            "serverName": "desktop_tool", "mode": "form",
            "requestedSchema": ["properties": [String: Any]()],
            "_meta": [
                "codex_approval_kind": "mcp_tool_call",
                "tool_params": [String: Any](),
            ],
        ]
        let request = try XCTUnwrap(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: 17, params: params))
        XCTAssertTrue(request.desktopStateRead)
        XCTAssertNil(request.spaceDirection)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppServerClient(logDirectory: directory)
        client.isWorking = true
        client.activeCommandID = "one-command"
        client.requestedDesktopState = true
        client.turnID = "one-turn"
        XCTAssertFalse(client.stageDesktopStateApproval(request))
        client.activeStateToolItemID = "one-item"
        client.activeStateToolTurnID = "one-turn"
        XCTAssertTrue(client.stageDesktopStateApproval(request))
        XCTAssertFalse(client.decideDesktopStateApproval(request, allow: true, forSession: true))
        XCTAssertFalse(
            client.hasAcceptedDesktopStateApproval(
                commandID: "one-command", itemID: "one-item"))
        client.desktopStateApproval = nil
        XCTAssertTrue(client.stageDesktopStateApproval(request))
        XCTAssertTrue(client.decideDesktopStateApproval(request, allow: true, forSession: false))
        XCTAssertTrue(
            client.hasAcceptedDesktopStateApproval(
                commandID: "one-command", itemID: "one-item"))
        client.activeStateToolItemID = "stale-item"
        XCTAssertFalse(
            client.hasAcceptedDesktopStateApproval(
                commandID: "one-command", itemID: "one-item"))
    }

    func testReadOnlyDiscoveryRetryIsBoundedBeforeAnyToolCall() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppServerClient(logDirectory: directory)
        client.requestedDesktopState = true
        XCTAssertTrue(client.shouldRetryDesktopStateDiscovery(outcome: "completed"))
        XCTAssertFalse(client.shouldRetryDesktopStateDiscovery(outcome: "interrupted"))
        client.activeStateToolItemID = "observed-tool"
        XCTAssertFalse(client.shouldRetryDesktopStateDiscovery(outcome: "completed"))
        client.activeStateToolItemID = nil
        client.desktopStateReadRetried = true
        XCTAssertFalse(client.shouldRetryDesktopStateDiscovery(outcome: "completed"))
        client.desktopStateReadRetried = false
        client.requestedDesktopState = false
        XCTAssertFalse(client.shouldRetryDesktopStateDiscovery(outcome: "completed"))
    }

    #if DEBUG
        func testMissingReadToolRestartsOneTurnWithinSameCommand() {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = AppServerClient(logDirectory: directory)
            client.isWorking = true
            client.activeCommandID = "read-command"
            client.requestedDesktopState = true
            client.turnID = "first-turn"
            var starts = 0
            client.actingTurnOverride = { starts += 1 }
            client.handleTurnCompleted(["id": "first-turn", "status": "completed"])
            XCTAssertEqual(starts, 1)
            XCTAssertTrue(client.desktopStateReadRetried)
            XCTAssertTrue(client.isWorking)
            XCTAssertEqual(client.queuedPhrase, "agent get desktop state")
            XCTAssertEqual(
                client.diagnosticEntries.filter { $0.event == "mcp_state_discovery_retry" }.count, 1)
            client.handleTurnCompleted(["id": "second-turn", "status": "completed"])
            XCTAssertEqual(starts, 1)
            XCTAssertFalse(client.isWorking)
        }
    #endif
}
