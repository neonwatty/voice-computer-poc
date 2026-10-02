import ApplicationServices
import XCTest

@testable import VoiceComputerPOC

final class NativeSpaceAXExecutionTests: XCTestCase {
    func testDelayedDiscoveryRevalidatesOnMainAndPressesOnce() {
        let client = activeClient("delayed")
        let context = readiness("delayed")
        let completed = expectation(description: "press")
        var calls = 0
        client.discoverAndPressNativeSpace(
            context, launchError: nil, attempts: 1,
            discover: {
                Thread.sleep(forTimeInterval: 0.08)
                XCTAssertFalse(Thread.isMainThread)
                return self.discovery()
            }, revalidate: { _ in XCTAssertTrue(Thread.isMainThread) },
            press: { _ in
                calls += 1
                completed.fulfill()
            }, liveSpaceID: { 3 })
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(context.pressGate.attempted, true)
        XCTAssertEqual(client.diagnosticEntries.filter { $0.event == "native_space_ax_pressed" }.count, 1)
        client.stop()
    }

    func testDiscoveryFailuresNeverPress() {
        for reason in ["missing_controls", "incomplete_controls", "mismatched_controls"] {
            let client = activeClient(reason)
            let context = readiness(reason, seconds: 0.2)
            let failed = expectation(description: reason)
            var presses = 0
            client.discoverAndPressNativeSpace(
                context, launchError: nil, attempts: 1,
                discover: { throw MissionControlAXError.scanUnavailable(reason, 0, 7) },
                revalidate: { _ in XCTFail("unexpected revalidation") },
                press: { _ in presses += 1 }, liveSpaceID: { 3 })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                XCTAssertEqual(presses, 0)
                XCTAssertFalse(context.pressGate.attempted)
                XCTAssertEqual(client.status, "Space failed")
                XCTAssertTrue(
                    client.diagnosticEntries.contains {
                        $0.event == "mission_control_ax_readiness" && $0.details["reason"] == reason
                    })
                failed.fulfill()
            }
            wait(for: [failed], timeout: 1)
        }
    }

    func testStopChangedCommandDeadlineLiveIDAndRevalidationBlockPress() {
        for scenario in ["stop", "command", "deadline", "live", "revalidate"] {
            let client = activeClient(scenario)
            let context = readiness(scenario, seconds: scenario == "deadline" ? 0.03 : 1)
            let settled = expectation(description: scenario)
            var presses = 0
            client.discoverAndPressNativeSpace(
                context, launchError: nil, attempts: 1,
                discover: {
                    Thread.sleep(forTimeInterval: 0.07)
                    return self.discovery()
                },
                revalidate: { _ in
                    if scenario == "revalidate" {
                        throw MissionControlAXError.desktopNotFound("stale_controls")
                    }
                }, press: { _ in presses += 1 },
                liveSpaceID: { scenario == "live" ? 4 : 3 })
            if scenario == "stop" { client.stop() }
            if scenario == "command" { client.activeCommandID = "other" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                XCTAssertEqual(presses, 0)
                XCTAssertFalse(context.pressGate.attempted)
                if !["stop", "command"].contains(scenario) {
                    XCTAssertEqual(client.status, "Space failed")
                }
                settled.fulfill()
            }
            wait(for: [settled], timeout: 1)
        }
    }

    func testOnePressGateRejectsDuplicateAndMainCheckRejectsLaunchError() {
        let client = activeClient("duplicate")
        let context = readiness("duplicate")
        XCTAssertTrue(context.pressGate.claim())
        var presses = 0
        let settled = expectation(description: "duplicate")
        client.discoverAndPressNativeSpace(
            context, launchError: nil, attempts: 1,
            discover: { self.discovery() }, revalidate: { _ in },
            press: { _ in presses += 1 }, liveSpaceID: { 3 })
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            XCTAssertEqual(presses, 0)
            XCTAssertEqual(client.status, "Space failed")
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1)

        let launch = activeClient("launch")
        launch.discoverAndPressNativeSpace(
            readiness("launch"), launchError: NSError(domain: "synthetic", code: 1),
            attempts: 1,
            discover: {
                XCTFail("unexpected discovery")
                return self.discovery()
            },
            revalidate: { _ in }, press: { _ in XCTFail("unexpected press") })
        XCTAssertEqual(launch.status, "Space failed")
    }

    private func activeClient(_ command: String) -> AppServerClient {
        let client = AppServerClient()
        client.activeCommandID = command
        client.isWorking = true
        return client
    }
    private func readiness(_ command: String, seconds: TimeInterval = 1) -> NativeSpaceReadiness {
        .init(
            direction: .right, before: .init(current: 3, ordered: [3, 4]), expected: 4,
            baseline: 0, targetNumber: 2, remaining: [], roundTripOrigin: nil,
            commandID: command, deadline: ProcessInfo.processInfo.systemUptime + seconds)
    }
    private func discovery() -> MissionControlAXDiscovery {
        let element = AXUIElementCreateSystemWide()
        return .init(list: element, target: element)
    }
}
