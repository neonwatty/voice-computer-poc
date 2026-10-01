import Foundation
import XCTest

@testable import VoiceComputerPOC

final class AppServerClientRoutingTests: XCTestCase {
    func testSessionJSONLOmitsCommandText() throws {
        let client = makeClient()
        let phrase = "private_phrase_7E329 open something"
        client.routingOverride = { _ in }
        client.run(phrase)
        let logURL = try XCTUnwrap(client.logURL)
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertFalse(log.contains(phrase))
        XCTAssertFalse(log.contains("private_phrase_7E329"))
        XCTAssertTrue(log.contains("command_started"))
        XCTAssertTrue(client.events.contains { $0.contains(phrase) })
    }

    func testReviewedVoiceWaitsForRunAndSharesOneCommandID() throws {
        let client = makeClient()
        var actorStarts = 0
        var routedPhrase: String?
        client.actingTurnOverride = { actorStarts += 1 }
        client.routingOverride = { routedPhrase = $0 }
        client.prepareVoiceCapture()
        let captureID = client.voiceCaptureCommandID
        client.voiceInput.onEvent?("voice_transcription_completed", ["character_count": "28"])

        XCTAssertNotNil(captureID)
        XCTAssertFalse(client.isWorking)
        XCTAssertEqual(actorStarts, 0)
        XCTAssertNil(client.diagnosticEntries.last { $0.event == "command_started" })
        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "voice_transcription_completed" }?
                .details["command_id"], captureID)
        XCTAssertFalse(
            client.diagnosticEntries.contains { entry in
                entry.details.values.contains { $0.contains("Switch to the next desktop Space") }
            })

        client.run("Switch to the next desktop Space", source: .reviewedVoice, transcriptEdited: true)
        XCTAssertEqual(routedPhrase, "Switch to the next desktop Space")
        XCTAssertEqual(actorStarts, 0)
        XCTAssertEqual(client.activeCommandID, captureID)
        let started = client.diagnosticEntries.last { $0.event == "command_started" }
        XCTAssertEqual(started?.details["command_id"], captureID)
        XCTAssertEqual(started?.details["input_source"], "reviewed_voice")
        XCTAssertEqual(started?.details["transcript_edited"], "true")
        XCTAssertEqual(started?.details["user_action"], "run")
        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "router_requested" }?.details["command_id"],
            captureID)
        client.processRouterOutput(
            try data("space", ["right"], ""), phrase: "Switch to the next desktop Space")
        XCTAssertEqual(actorStarts, 1)
        XCTAssertEqual(
            client.diagnosticEntries.last { $0.event == "router_decided" }?.details["command_id"],
            captureID)
    }

    func testUnsafeAndUnavailableRouterOutputsStartNoActor() throws {
        let cases: [(String, Data?)] = [
            ("Go left one desktop space, then back right", nil),
            ("Go left one desktop space, then back right", Data("not json".utf8)),
            (
                "Go left one desktop space, then back right",
                Data(#"{"route":"space","directions":["right","left"],"target":"","extra":1}"#.utf8)
            ),
            ("Go left one desktop space, then back right", try data("space", ["right", "left"], "")),
            ("Do not move right one desktop Space", try data("space", ["right"], "")),
            ("Maybe move right one Space", try data("space", ["right"], "")),
            ("Go left or right", try data("space", ["right"], "")),
            ("Open Calculator or switch Space", try data("computer_use", [], "calculator")),
            ("Go left one desktop space, then back right", try data("clarification", [], "")),
        ]
        for (phrase, output) in cases {
            let client = makeClient()
            var actorStarts = 0
            client.actingTurnOverride = { actorStarts += 1 }
            client.isWorking = true
            client.activeCommandID = "test-command"
            client.queuedPhrase = phrase
            client.processRouterOutput(output, phrase: phrase)
            XCTAssertEqual(actorStarts, 0)
            XCTAssertFalse(client.isWorking)
            XCTAssertNil(client.requestedToolDirection)
            XCTAssertNil(client.focusTargetBundleID)
            XCTAssertEqual(
                client.diagnosticEntries.last { $0.event == "command_finished" }?
                    .details["verification"], "no_action")
        }
    }

    func testCoordinatorSelectsOnlyRequestedActor() throws {
        let space = makeClient()
        var spaceStarts = 0
        space.actingTurnOverride = { spaceStarts += 1 }
        space.isWorking = true
        space.processRouterOutput(
            try data("space", ["right"], ""), phrase: "Go to the next desktop Space")
        XCTAssertEqual(spaceStarts, 1)
        XCTAssertEqual(space.requestedToolDirection, .right)
        XCTAssertNil(space.focusTargetBundleID)

        let calculator = makeClient()
        var calculatorStarts = 0
        calculator.actingTurnOverride = { calculatorStarts += 1 }
        calculator.isWorking = true
        calculator.processRouterOutput(
            try data("computer_use", [], "calculator"), phrase: "Please open Calculator")
        XCTAssertEqual(calculatorStarts, 1)
        XCTAssertNil(calculator.requestedToolDirection)
        XCTAssertEqual(calculator.focusTargetBundleID, "com.apple.calculator")
        XCTAssertEqual(calculator.queuedPhrase, "Open Calculator")
    }

    func testUnverifiedFirstStepCannotStartSecondActor() {
        let client = roundTripClient()
        var actorStarts = 0
        client.actingTurnOverride = { actorStarts += 1 }
        client.toolResult = .failure(
            "unverified", commandID: "test-command", direction: "right", message: "No event")
        client.handleTurnCompleted(["id": "first", "status": "completed"])
        XCTAssertEqual(actorStarts, 0)
        XCTAssertFalse(client.isWorking)
        XCTAssertTrue(client.remainingRoutedDirections.isEmpty)
    }

    func testVerifiedFirstStepStartsExactlyOneLeftActor() {
        let client = roundTripClient()
        var actorStarts = 0
        client.actingTurnOverride = { actorStarts += 1 }
        client.toolResult = SpaceToolResult(
            commandID: "test-command", status: "verified", direction: "right",
            beforeID: 100, expectedID: 101, afterID: 101,
            notificationObserved: true, message: "Verified")
        client.handleTurnCompleted(["id": "first", "status": "completed"])
        XCTAssertEqual(actorStarts, 1)
        XCTAssertTrue(client.isWorking)
        XCTAssertEqual(client.requestedToolDirection, .left)
    }

    private func roundTripClient() -> AppServerClient {
        let client = makeClient()
        client.isWorking = true
        client.activeCommandID = "test-command"
        client.requestedToolDirection = .right
        client.remainingRoutedDirections = [.left]
        client.routedOriginalPhrase = "Go right one desktop Space, then back left"
        client.toolCallObserved = true
        client.toolCallCompleted = true
        return client
    }

    private func makeClient() -> AppServerClient {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        return AppServerClient(logDirectory: directory)
    }

    private func data(_ route: String, _ directions: [String], _ target: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "route": route, "directions": directions, "target": target,
        ])
    }
}
