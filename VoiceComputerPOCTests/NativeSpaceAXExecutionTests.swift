import ApplicationServices
import XCTest

@testable import VoiceComputerPOC

final class NativeSpaceAXExecutionTests: XCTestCase {
    func testMissingActivationOrWrongFrontmostAppNeverLaunches() {
        for scenario in ["inactive", "frontmost_mismatch"] {
            let client = activeClient(scenario)
            let context = readiness(scenario)
            let settled = expectation(description: scenario)
            var activationRequests = 0
            var launches = 0
            client.requestVoiceForeground(
                context, activate: { activationRequests += 1 },
                isActive: { scenario != "inactive" },
                frontmostBundleID: {
                    scenario == "inactive" ? nil : "com.example.OtherApp"
                }, launch: { launches += 1 })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) {
                XCTAssertEqual(activationRequests, 1)
                XCTAssertEqual(launches, 0)
                XCTAssertEqual(client.status, "Space failed")
                XCTAssertTrue(client.result.contains("did not become the active app"))
                XCTAssertFalse(context.pressGate.attempted)
                XCTAssertTrue(
                    client.diagnosticEntries.contains {
                        $0.event == "voice_foreground_observed"
                            && $0.details["frontmost_matches"] == "false"
                    })
                settled.fulfill()
            }
            wait(for: [settled], timeout: 1.5)
        }
    }

    func testForegroundSuccessStillRequiresStrictDiscoveryAndMainChecks() {
        for scenario in ["missing_controls", "changed_space"] {
            let client = activeClient(scenario)
            let context = readiness(scenario, seconds: 0.25)
            let settled = expectation(description: scenario)
            var launches = 0
            var presses = 0
            client.requestVoiceForeground(
                context, activate: {}, isActive: { true },
                frontmostBundleID: { "com.neonwatty.VoiceComputerPOC" },
                launch: {
                    launches += 1
                    client.discoverAndPressNativeSpace(
                        context, launchError: nil, attempts: 1,
                        discover: {
                            if scenario == "missing_controls" {
                                throw MissionControlAXError.scanUnavailable("missing_controls", 0, 5)
                            }
                            return self.discovery()
                        }, revalidate: { _ in }, press: { _ in presses += 1 },
                        liveSpaceID: { scenario == "changed_space" ? 4 : 3 })
                })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                XCTAssertEqual(launches, 1)
                XCTAssertEqual(presses, 0)
                XCTAssertFalse(context.pressGate.attempted)
                XCTAssertEqual(client.status, "Space failed")
                settled.fulfill()
            }
            wait(for: [settled], timeout: 1)
        }
    }

    func testLaunchErrorAndNilApplicationFailBeforeDiscovery() {
        for scenario in ["error", "nil_application"] {
            let client = activeClient(scenario)
            var readyCalls = 0
            client.handleMissionControlLaunchResult(
                readiness(scenario), applicationPresent: scenario == "error",
                error: scenario == "error" ? NSError(domain: "synthetic", code: 1) : nil,
                onReady: { readyCalls += 1 })
            XCTAssertEqual(readyCalls, 0)
            XCTAssertEqual(client.status, "Space failed")
            XCTAssertTrue(
                client.diagnosticEntries.contains {
                    $0.event == "mission_control_launch_failed"
                })
        }
        let client = activeClient("success")
        var readyCalls = 0
        client.handleMissionControlLaunchResult(
            readiness("success"), applicationPresent: true, error: nil,
            onReady: { readyCalls += 1 })
        XCTAssertEqual(readyCalls, 1)
        XCTAssertFalse(client.diagnosticEntries.contains { $0.event == "native_space_ax_pressed" })
        client.stop()
    }

    func testStopChangedCommandAndExpiredDeadlinePreventHandoffLaunch() {
        for scenario in ["stop", "command", "expired"] {
            let client = activeClient(scenario)
            let context = readiness(scenario, seconds: scenario == "expired" ? -1 : 1)
            var activations = 0
            var launches = 0
            let settled = expectation(description: scenario)
            client.requestVoiceForeground(
                context, activate: { activations += 1 }, isActive: { false },
                frontmostBundleID: { nil }, launch: { launches += 1 })
            if scenario == "stop" { client.stop() }
            if scenario == "command" { client.activeCommandID = "different" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                XCTAssertEqual(launches, 0)
                XCTAssertFalse(context.pressGate.attempted)
                XCTAssertEqual(activations, scenario == "expired" ? 0 : 1)
                settled.fulfill()
            }
            wait(for: [settled], timeout: 1)
        }
    }

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
        for reason in ["missing_controls", "incomplete_controls", "mismatched_controls", "changed_live_id"] {
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

    func testAXFirstExactControlsSkipOpenAndRequireVerification() {
        let client = activeClient("ax-first-exact")
        let context = readiness("ax-first-exact")
        let pressed = expectation(description: "exact controls pressed")
        var opens = 0
        client.discoverAndPressNativeSpace(
            context, launchError: nil, attempts: 0,
            discover: { self.discovery() },
            revalidate: { _ in
                XCTAssertTrue(Thread.isMainThread)
            }, press: { _ in pressed.fulfill() }, liveSpaceID: { 3 },
            openOnAbsent: { opens += 1 })
        wait(for: [pressed], timeout: 1)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(client.diagnosticEntries.filter { $0.event == "native_space_ax_pressed" }.count, 1)
        XCTAssertFalse(client.result.contains("verified"))
        XCTAssertEqual(
            SpaceToolSafety.verification(expected: 4, after: 4, eventObserved: false, deadlineReached: false),
            .pending)
        XCTAssertEqual(
            SpaceToolSafety.verification(expected: 4, after: 3, eventObserved: true, deadlineReached: false),
            .pending)
        client.stop()
    }

    func testAXFirstOpensOnlyForAbsentControls() {
        for reason in ["missing_controls", "incomplete_controls", "mismatched_controls"] {
            let client = activeClient(reason)
            let context = readiness(reason)
            let settled = expectation(description: reason)
            var opens = 0
            var presses = 0
            client.discoverAndPressNativeSpace(
                context, launchError: nil, attempts: 0,
                discover: {
                    throw MissionControlAXError.scanUnavailable(
                        reason == "changed_live_id" ? "missing_controls" : reason, 0, 5)
                },
                revalidate: { _ in XCTFail("unexpected revalidation") },
                press: { _ in presses += 1 },
                liveSpaceID: { reason == "changed_live_id" ? 4 : 3 },
                openOnAbsent: { opens += 1 })
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                XCTAssertEqual(opens, reason == "missing_controls" ? 1 : 0)
                XCTAssertEqual(presses, 0)
                XCTAssertFalse(context.pressGate.attempted)
                if opens == 0 { XCTAssertEqual(client.status, "Space failed") }
                client.stop()
                settled.fulfill()
            }
            wait(for: [settled], timeout: 1)
        }
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
