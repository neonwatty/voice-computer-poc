import XCTest

@testable import VoiceComputerPOC

final class SpaceNavigatorTests: XCTestCase {
    func testOnlyExplicitSpacePhrasesSelectNativeAction() {
        XCTAssertEqual(SpaceDirection(phrase: "Switch to the next desktop Space"), .right)
        XCTAssertEqual(SpaceDirection(phrase: " Switch one desktop Space to the left "), .left)
        XCTAssertEqual(SpaceDirection(phrase: "Switch to the next desktop Space."), .right)
        XCTAssertNil(SpaceDirection(phrase: "Explain how desktop Spaces work"))
        XCTAssertNil(SpaceDirection(phrase: "Switch to the next desktop Space?"))
        XCTAssertNil(SpaceDirection(phrase: "Switch to the next desktop Space and delete a file"))
        XCTAssertEqual(
            SpaceCommand(phrase: "Switch one desktop Space right and then back left"),
            .rightThenLeft)
        XCTAssertEqual(
            SpaceCommand(phrase: "Switch one desktop Space right and then back left!"),
            .rightThenLeft)
        XCTAssertNil(SpaceCommand(phrase: "Switch right, then open a private document"))
    }

    func testAdjacentSpaceRespectsBothBoundaries() {
        let first = SpaceSnapshot(current: 3, ordered: [3, 4])
        let second = SpaceSnapshot(current: 4, ordered: [3, 4])
        XCTAssertEqual(first.adjacent(.right), 4)
        XCTAssertNil(first.adjacent(.left))
        XCTAssertEqual(second.adjacent(.left), 3)
        XCTAssertNil(second.adjacent(.right))
    }

    func testParserAcceptsSingleMainAndEightEmptyStaleDisplaysInAnyOrder() {
        let main = monitor("Main", ids: [3, 4])
        let stale = (1...8).map { monitor("stale-\($0)", ids: []) }
        XCTAssertEqual(SpaceNavigator.parseMonitors([main], current: 3)?.ordered, [3, 4])
        for split in 0...8 {
            let monitors = Array(stale.prefix(split)) + [main] + Array(stale.dropFirst(split))
            let first = SpaceNavigator.parseMonitors(monitors, current: 3)
            XCTAssertEqual(first?.adjacent(.right), 4)
            XCTAssertNil(first?.adjacent(.left))
            let second = SpaceNavigator.parseMonitors(monitors, current: 4)
            XCTAssertEqual(second?.adjacent(.left), 3)
            XCTAssertNil(second?.adjacent(.right))
        }
    }

    func testParserAcceptsAirCollapsedStaleMonitorShape() {
        let main = monitor("Main", ids: [3, 4])
        let stale = (1...8).map { index in
            collapsedMonitor(index: index, id: index == 1 ? 4 : index * 117)
        }
        for split in 0...8 {
            let monitors = Array(stale.prefix(split)) + [main] + Array(stale.dropFirst(split))
            XCTAssertEqual(
                SpaceNavigator.parseMonitors(monitors, current: 3),
                SpaceSnapshot(current: 3, ordered: [3, 4]))
        }
    }

    func testParserRejectsMalformedCollapsedStaleAndPopulatedSecondary() {
        let main = monitor("Main", ids: [3, 4])
        let valid = collapsedMonitor(index: 1, id: 4)
        guard let originalFields = valid["Collapsed Space"] as? [String: Any] else {
            return XCTFail("Test fixture must contain Collapsed Space")
        }
        var missingID = valid
        var fields = originalFields
        fields.removeValue(forKey: "id64")
        missingID["Collapsed Space"] = fields
        var mismatchedID = valid
        fields["id64"] = 5
        mismatchedID["Collapsed Space"] = fields
        var invalidUUID = valid
        fields = originalFields
        fields["uuid"] = "invalid"
        invalidUUID["Collapsed Space"] = fields
        var invalidAutoCreated = valid
        fields = originalFields
        fields["AutoCreated"] = "yes"
        invalidAutoCreated["Collapsed Space"] = fields
        var unexpectedField = valid
        unexpectedField["Extra"] = true
        var populated = valid
        populated["Spaces"] = [["id64": 5]]
        let malformed = [
            missingID, mismatchedID, invalidUUID, invalidAutoCreated,
            unexpectedField, populated,
            ["Display Identifier": "stale", "Collapsed Space": fields],
            ["Display Identifier": "stale"],
        ]
        for record in malformed {
            XCTAssertNil(SpaceNavigator.parseMonitors([main, record], current: 3))
        }
        XCTAssertNil(SpaceNavigator.parseMonitors([valid], current: 3))
        XCTAssertNil(SpaceNavigator.parseMonitors([main, main, valid], current: 3))
        XCTAssertNil(SpaceNavigator.parseMonitors([main, valid, valid], current: 3))
    }

    func testParserRejectsMissingEmptyDuplicateOrAmbiguousMain() {
        let main = monitor("Main", ids: [3, 4])
        let empty = monitor("stale", ids: [])
        XCTAssertNil(SpaceNavigator.parseMonitors([empty], current: 3))
        XCTAssertNil(SpaceNavigator.parseMonitors([monitor("Main", ids: [])], current: 3))
        XCTAssertNil(SpaceNavigator.parseMonitors([main, main], current: 3))
        XCTAssertNil(SpaceNavigator.parseMonitors([main, monitor("external", ids: [5])], current: 3))
        XCTAssertNil(SpaceNavigator.parseMonitors([main, empty, empty], current: 3))
        XCTAssertNil(SpaceNavigator.parseMonitors([main], current: 5))
        XCTAssertNil(SpaceNavigator.parseMonitors([main], current: 0))
    }

    func testParserRejectsMalformedMonitorAndSpaceRecords() {
        let main = monitor("Main", ids: [3, 4])
        let invalidStale: [[String: Any]] = [
            ["Display Identifier": "stale"],
            ["Display Identifier": "stale", "Spaces": "none"],
            ["Display Identifier": "", "Spaces": [[String: Any]()]],
            ["Spaces": [[String: Any]()]],
        ]
        for record in invalidStale {
            XCTAssertNil(SpaceNavigator.parseMonitors([main, record], current: 3))
        }
        let invalidMain: [[String: Any]] = [
            ["Display Identifier": "Main"],
            ["Display Identifier": "Main", "Spaces": "two"],
            ["Display Identifier": "Main", "Spaces": [[String: Any]()]],
            ["Display Identifier": "Main", "Spaces": [["id64": "3"]]],
            ["Display Identifier": "Main", "Spaces": [["id64": true]]],
            ["Display Identifier": "Main", "Spaces": [["id64": 3.0]]],
            monitor("Main", ids: [0, 4]),
            monitor("Main", ids: [3, 3]),
        ]
        for record in invalidMain {
            XCTAssertNil(SpaceNavigator.parseMonitors([record], current: 3))
        }
    }

    func testDelayedStrictControlsPermitOneSyntheticPress() {
        let client = AppServerClient()
        client.activeCommandID = "ready-command"
        client.isWorking = true
        let context = readiness(commandID: "ready-command", after: 4, seconds: 1.5)
        var attempts = 0
        client.pressNativeSpace(context, launchError: nil, attempts: 1) {
            attempts += 1
            if attempts < 3 { throw MissionControlAXError.desktopNotFound("missing_controls") }
        }
        let completed = expectation(description: "One synthetic press")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            XCTAssertEqual(attempts, 3)
            XCTAssertEqual(
                client.diagnosticEntries.filter { $0.event == "native_space_ax_pressed" }.count, 1)
            client.stop()
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
    }

    func testMissingIncompleteAndMismatchedControlsNeverPress() {
        for reason in ["missing_controls", "incomplete_controls", "mismatched_controls"] {
            let client = AppServerClient()
            client.activeCommandID = reason
            client.isWorking = true
            let context = readiness(commandID: reason, after: 4, seconds: 0.2)
            client.pressNativeSpace(context, launchError: nil, attempts: 1) {
                throw MissionControlAXError.desktopNotFound(reason)
            }
            let failed = expectation(description: "Readiness failure: \(reason)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                XCTAssertEqual(client.status, "Space failed")
                XCTAssertFalse(client.isWorking)
                XCTAssertFalse(client.diagnosticEntries.contains { $0.event == "native_space_ax_pressed" })
                XCTAssertTrue(
                    client.diagnosticEntries.contains { $0.event == "mission_control_ax_readiness" })
                failed.fulfill()
            }
            wait(for: [failed], timeout: 1)
        }
    }

    func testCancelledOrStaleReadinessCannotPress() {
        for active in [false, true] {
            let client = AppServerClient()
            client.activeCommandID = active ? "other" : "command"
            client.isWorking = active
            var presses = 0
            client.pressNativeSpace(
                readiness(commandID: "command", after: 4, seconds: 1),
                launchError: nil, attempts: 1
            ) { presses += 1 }
            XCTAssertEqual(presses, 0)
            XCTAssertFalse(client.diagnosticEntries.contains { $0.event == "native_space_ax_pressed" })
        }
    }

    func testReadinessDeadlinePrecedesToolTimeout() {
        XCTAssertLessThan(4.0 + 3.0, 10.0)
        let client = AppServerClient()
        client.activeCommandID = "expired"
        client.isWorking = true
        var presses = 0
        client.pressNativeSpace(
            readiness(commandID: "expired", after: 4, seconds: -1),
            launchError: nil, attempts: 1
        ) { presses += 1 }
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(client.status, "Space failed")
    }

    private func readiness(
        commandID: String, after: Int, seconds: TimeInterval
    ) -> NativeSpaceReadiness {
        .init(
            direction: .right, before: SpaceSnapshot(current: 3, ordered: [3, 4]),
            expected: after, baseline: 0, targetNumber: 2, remaining: [],
            roundTripOrigin: nil, commandID: commandID,
            deadline: ProcessInfo.processInfo.systemUptime + seconds)
    }

    private func monitor(_ identifier: String, ids: [Int]) -> [String: Any] {
        ["Display Identifier": identifier, "Spaces": ids.map { ["id64": $0] }]
    }

    private func collapsedMonitor(index: Int, id: Int) -> [String: Any] {
        let identifier = String(format: "00000000-0000-4000-8000-%012d", index)
        var collapsed: [String: Any] = [
            "ManagedSpaceID": id,
            "id64": id,
            "type": 0,
            "uuid": String(format: "10000000-0000-4000-8000-%012d", index),
        ]
        if index == 3 || index == 8 { collapsed["AutoCreated"] = true }
        return ["Display Identifier": identifier, "Collapsed Space": collapsed]
    }
}
