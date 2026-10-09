import Foundation
import XCTest

@testable import VoiceComputerPOC

final class TextEditRouteTests: XCTestCase {
    func testStopRejectsPendingComputerUseApproval() throws {
        let request = try XCTUnwrap(
            ApprovalRequest.parse(
                method: "mcpServer/elicitation/request", id: 42,
                params: [
                    "serverName": "cua_repl", "mode": "form",
                    "message": "Allow Computer Use to use TextEdit?",
                    "requestedSchema": ["properties": [String: Any]()],
                    "_meta": [
                        "codex_approval_kind": "mcp_tool_call",
                        "connector_id": "computer-use",
                        "connector_name": "Computer Use",
                        "riskLevel": "low",
                        "tool_name": "js",
                        "tool_params": ["app": "TextEdit"],
                        "tool_params_display": [["value": "TextEdit"]],
                        "persist": ["session"],
                        "x-codex-turn-metadata": [String: Any](),
                    ],
                ]))
        let client = AppServerClient()
        client.isWorking = true
        client.activeCommandID = "stop-test"
        client.input = Pipe()
        client.approval = request
        client.stop()
        XCTAssertNil(client.approval)
        XCTAssertNil(client.generalTurnFailure)
        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "approval_decided" }?
                .details["decision"], "Declined on Stop")
    }

    #if DEBUG
        func testSyntheticAccessibilityFailureCannotReportVerified() throws {
            let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceComputerPOC/TestFixtures/\(runID)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let note = root.appendingPathComponent("note.txt")
            try "Voice Computer saved \(runID)".write(
                to: note, atomically: true, encoding: .utf8)
            let marker = root.appendingPathComponent("inject_ax_failure")
            try "textedit:\(runID)\n".write(to: marker, atomically: true, encoding: .utf8)
            let observation = FixtureAXVerifier.verifyTextEdit(noteURL: note)
            XCTAssertFalse(observation.verified)
            XCTAssertEqual(observation.reason, "synthetic_accessibility_failure")
        }
    #endif

    func testOnlyRunOwnedDraftAndExactPhraseCanRoute() throws {
        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceComputerPOC/TestFixtures/\(runID)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        try "Voice Computer draft \(runID)".write(to: note, atomically: true, encoding: .utf8)
        let phrase = phraseFor(note, runID: runID)
        let output = Data(#"{"route":"textedit","directions":[],"target":"fixture_note"}"#.utf8)
        XCTAssertEqual(CommandRoute.parse(output, originalPhrase: phrase), .textEditSave(note))
        XCTAssertEqual(RouteHandoff.decide(output, phrase: phrase), .textEditSave(note))
        for unsafe in [
            phrase.replacingOccurrences(of: "saved", with: "deleted"),
            phrase.replacingOccurrences(of: runID, with: String(repeating: "b", count: 32)),
            phrase + " Then remove the file.",
            "Do not \(phrase)",
            phraseFor(root.appendingPathComponent("other.txt"), runID: runID),
        ] {
            XCTAssertNil(CommandRoute.parse(output, originalPhrase: unsafe), unsafe)
        }
        try "other contents".write(to: note, atomically: true, encoding: .utf8)
        XCTAssertNil(CommandRoute.parse(output, originalPhrase: phrase))
        XCTAssertEqual(FixtureAXVerifier.verifyTextEdit(noteURL: note).reason, "file_bytes_mismatch")
    }

    func testSymlinkAndWrongRouterTargetCannotAct() throws {
        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceComputerPOC/TestFixtures/\(runID)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "Voice Computer draft \(runID)".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("note.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let phrase = phraseFor(link, runID: runID)
        let validOutput = Data(#"{"route":"textedit","directions":[],"target":"fixture_note"}"#.utf8)
        XCTAssertNil(CommandRoute.parse(validOutput, originalPhrase: phrase))
        XCTAssertNil(
            CommandRoute.parse(
                Data(#"{"route":"textedit","directions":[],"target":"fixture_report"}"#.utf8),
                originalPhrase: phrase))
    }

    func testCreateRequiresAbsentRunOwnedNoteAndExactPhrase() throws {
        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceComputerPOC/TestFixtures/\(runID)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let note = root.appendingPathComponent("note.txt")
        let phrase =
            "In TextEdit, create the test note at \(note.path) with "
            + "\"Voice Computer saved \(runID)\" and save it."
        let output = Data(
            #"{"route":"textedit","directions":[],"target":"fixture_new_note"}"#.utf8)
        XCTAssertEqual(CommandRoute.parse(output, originalPhrase: phrase), .textEditCreate(note))
        XCTAssertEqual(RouteHandoff.decide(output, phrase: phrase), .textEditCreate(note))
        let unsafe = [
            phrase + " Delete another document.",
            phrase.replacingOccurrences(of: "saved", with: "deleted"),
            phrase.replacingOccurrences(of: "create", with: "replace"),
            phrase.replacingOccurrences(of: "note.txt", with: "other.txt"),
            "Do not \(phrase)",
        ]
        for request in unsafe {
            XCTAssertNil(CommandRoute.parse(output, originalPhrase: request), request)
        }
        try "existing user content".write(to: note, atomically: true, encoding: .utf8)
        XCTAssertNil(CommandRoute.parse(output, originalPhrase: phrase))
        try FileManager.default.removeItem(at: note)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: note, withDestinationURL: outside)
        XCTAssertNil(CommandRoute.parse(output, originalPhrase: phrase))
        try FileManager.default.removeItem(at: note)
        try FileManager.default.removeItem(at: outside)
        try FileManager.default.createSymbolicLink(at: note, withDestinationURL: outside)
        XCTAssertNil(CommandRoute.parse(output, originalPhrase: phrase))
    }

    #if DEBUG
        func testHandoffQueuesBoundedTextEditTurn() throws {
            let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let root = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("VoiceComputerPOC/TestFixtures/\(runID)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let note = root.appendingPathComponent("note.txt")
            try "Voice Computer draft \(runID)".write(to: note, atomically: true, encoding: .utf8)
            let client = AppServerClient(
                logDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString))
            client.isWorking = true
            client.activeCommandID = "textedit-test"
            var actorStarts = 0
            client.actingTurnOverride = { actorStarts += 1 }
            let phrase = phraseFor(note, runID: runID)
            let output = Data(#"{"route":"textedit","directions":[],"target":"fixture_note"}"#.utf8)
            client.processRouterOutput(output, phrase: phrase)
            XCTAssertEqual(actorStarts, 1)
            XCTAssertEqual(client.textEditNoteURL, note)
            let instruction = client.turnInstruction(for: phrase)
            XCTAssertTrue(instruction.contains("cua.getApp('com.apple.TextEdit')"))
            XCTAssertTrue(instruction.contains(note.path))
            XCTAssertTrue(instruction.contains("Voice Computer saved \(runID)"))
        }
    #endif

    private func phraseFor(_ url: URL, runID: String) -> String {
        "In TextEdit, replace the test note at \(url.path) with \"Voice Computer saved \(runID)\" and save it."
    }
}
