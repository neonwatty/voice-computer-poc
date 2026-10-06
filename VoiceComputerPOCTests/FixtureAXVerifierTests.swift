import Foundation
import XCTest

@testable import VoiceComputerPOC

final class FixtureAXVerifierTests: XCTestCase {
    func testBrowserNeedsOneExactWebAreaURLAndHeading() throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:61732/docs?run_id=fixture-1234"))
        let heading = "Voice Computer Docs fixture-1234"
        let good = FixtureAXVerifier.WebAreaEvidence(url: url, headings: [heading])
        XCTAssertTrue(
            FixtureAXVerifier.browserMatches(
                [good], expectedURL: url, expectedHeading: heading))
        XCTAssertFalse(
            FixtureAXVerifier.browserMatches(
                [good, good], expectedURL: url, expectedHeading: heading))
        XCTAssertFalse(
            FixtureAXVerifier.browserMatches(
                [.init(url: url, headings: ["Voice Computer Home fixture-1234"])],
                expectedURL: url, expectedHeading: heading))
        XCTAssertFalse(
            FixtureAXVerifier.browserMatches(
                [
                    .init(
                        url: URL(string: "http://127.0.0.1:61732/error?run_id=fixture-1234"),
                        headings: [heading])
                ], expectedURL: url, expectedHeading: heading))
    }

    func testFinderNeedsOneSelectedReportAndVisibleDecoy() {
        let report = URL(fileURLWithPath: "/tmp/fixture-1234/report.txt")
        let decoy = URL(fileURLWithPath: "/tmp/fixture-1234/report-copy.txt")
        let good = FixtureAXVerifier.FinderWindowEvidence(
            selectedRowURLs: [[report]], visibleURLs: [report, decoy])
        XCTAssertTrue(FixtureAXVerifier.finderMatches([good], reportURL: report))
        XCTAssertFalse(FixtureAXVerifier.finderMatches([good, good], reportURL: report))
        XCTAssertFalse(
            FixtureAXVerifier.finderMatches(
                [.init(selectedRowURLs: [[decoy]], visibleURLs: [report, decoy])], reportURL: report))
        XCTAssertFalse(
            FixtureAXVerifier.finderMatches(
                [.init(selectedRowURLs: [[report], [decoy]], visibleURLs: [report, decoy])],
                reportURL: report))
        XCTAssertFalse(
            FixtureAXVerifier.finderMatches(
                [.init(selectedRowURLs: [[report]], visibleURLs: [report])], reportURL: report))
    }

    func testFormVerificationRejectsQueryThatDoesNotMatchRun() throws {
        let docs = try XCTUnwrap(URL(string: "http://127.0.0.1:61732/docs?run_id=fixture-1234"))
        let observation = FixtureAXVerifier.verifyBrowserForm(docsURL: docs, query: "test-other")
        XCTAssertFalse(observation.verified)
        XCTAssertEqual(observation.reason, "invalid_target")
    }

    func testAppCannotVerifyFixtureFromAgentSentenceWithoutCompletedTool() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppServerClient(logDirectory: directory)
        client.browserDocsURL = try XCTUnwrap(
            URL(
                string: "http://127.0.0.1:61732/home?run_id=fixture-1234"))
        client.isWorking = true
        client.activeCommandID = "fixture-command"
        client.turnID = "fixture-turn"
        client.result = "I successfully opened Docs."
        client.handleTurnCompleted(["id": "fixture-turn", "status": "completed"])
        XCTAssertFalse(client.isWorking)
        XCTAssertEqual(client.status, "Unverified")
        XCTAssertFalse(client.result.contains("successfully"))
        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "fixture_ax_verification" }?
                .details["reason"], "tool_not_completed")
        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "command_finished" }?
                .details["verification"], "unverified")
        client.handleItemCompleted(["type": "agentMessage", "text": "I successfully opened Docs."])
        XCTAssertFalse(client.result.contains("successfully"))
    }

    func testFixtureToolCompletionRequiresSameTurnAndItemID() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = AppServerClient(logDirectory: directory)
        client.browserDocsURL = try XCTUnwrap(
            URL(
                string: "http://127.0.0.1:61732/home?run_id=fixture-1234"))
        client.turnID = "fixture-turn"
        let item: [String: Any] = ["server": "cua_repl", "id": "tool-one"]
        client.observeFixtureToolStarted(item, eventTurnID: "other-turn")
        XCTAssertTrue(client.fixtureCUAToolStartedIDs.isEmpty)
        client.observeFixtureToolStarted(item, eventTurnID: "fixture-turn")
        client.observeFixtureToolCompleted(
            ["server": "cua_repl", "id": "tool-two"], status: "completed", failed: false)
        XCTAssertEqual(client.fixtureCUAToolStartedIDs, ["tool-one"])
        XCTAssertTrue(client.fixtureCUAToolCompletedIDs.isEmpty)
        client.observeFixtureToolCompleted(item, status: "completed", failed: true)
        XCTAssertTrue(client.fixtureCUAToolCompletedIDs.isEmpty)
        client.observeFixtureToolCompleted(item, status: "completed", failed: false)
        XCTAssertEqual(client.fixtureCUAToolCompletedIDs, ["tool-one"])
    }

    #if DEBUG
        func testSyntheticCUAFailureUsesRealFixtureRejectionPath() throws {
            for target in ["browser", "finder", "textedit"] {
                let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                let root = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("VoiceComputerPOC/TestFixtures/\(runID)")
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                try "\(target):\(runID)\n".write(
                    to: root.appendingPathComponent("inject_cua_failure"),
                    atomically: true, encoding: .utf8)
                let client = AppServerClient(
                    logDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString))
                client.isWorking = true
                client.activeCommandID = "command-\(target)"
                client.threadID = "thread-\(target)"
                client.turnID = "turn-\(target)"
                client.input = Pipe()
                if target == "browser" {
                    client.browserDocsURL = try XCTUnwrap(
                        URL(string: "http://127.0.0.1:61234/home?run_id=\(runID)"))
                } else if target == "finder" {
                    client.finderReportURL = root.appendingPathComponent("report.txt")
                } else {
                    client.textEditNoteURL = root.appendingPathComponent("note.txt")
                }
                let item: [String: Any] = [
                    "type": "mcpToolCall", "server": "cua_repl", "tool": "js",
                    "id": "tool-\(target)", "status": "completed",
                    "error": NSNull(),
                    "result": ["isError": false],
                ]
                client.handleItemStarted(item, eventTurnID: client.turnID)
                client.handleItemCompleted(item)
                XCTAssertTrue(client.fixtureCUAFailureInjected)
                XCTAssertEqual(
                    client.fixtureTurnResult(outcome: "completed")?.observation.reason,
                    "tool_failure")
                XCTAssertEqual(
                    client.diagnosticEntries.filter {
                        $0.event == "test_cua_failure_injected"
                    }.count, 1)
                XCTAssertEqual(
                    client.diagnosticEntries.filter {
                        $0.event == "fixture_tool_failure_interrupt_requested"
                    }.count, 1)
                client.handleItemCompleted(item)
                XCTAssertEqual(
                    client.diagnosticEntries.filter {
                        $0.event == "test_cua_failure_injected"
                    }.count, 1)
                XCTAssertEqual(
                    client.diagnosticEntries.filter {
                        $0.event == "fixture_tool_failure_interrupt_requested"
                    }.count, 1)
            }
        }
    #endif
}
