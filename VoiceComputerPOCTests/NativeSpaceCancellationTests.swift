import ApplicationServices
import XCTest

@testable import VoiceComputerPOC

final class NativeSpaceCancellationTests: XCTestCase {
    func testToolStopDuringDiscoveryCannotPressWhileTurnRemainsActive() {
        let client = AppServerClient()
        client.activeCommandID = "tool-stop"
        client.activeToolDirection = .right
        client.isWorking = true
        let context = NativeSpaceReadiness(
            direction: .right, before: .init(current: 3, ordered: [3, 4]), expected: 4,
            baseline: 0, targetNumber: 2, remaining: [], roundTripOrigin: nil,
            commandID: "tool-stop", deadline: ProcessInfo.processInfo.systemUptime + 1)
        let discoveryStarted = expectation(description: "discovery started")
        let lateCallback = expectation(description: "late discovery callback")
        let releaseDiscovery = DispatchSemaphore(value: 0)
        var replies: [SpaceToolResult] = []
        var presses = 0
        var revalidations = 0
        client.toolReply = { replies.append($0) }
        client.discoverAndPressNativeSpace(
            context, launchError: nil, attempts: 1,
            discover: {
                discoveryStarted.fulfill()
                _ = releaseDiscovery.wait(timeout: .now() + 1)
                let element = AXUIElementCreateSystemWide()
                return .init(list: element, target: element)
            }, revalidate: { _ in revalidations += 1 },
            press: { _ in presses += 1 }, liveSpaceID: { 3 })
        wait(for: [discoveryStarted], timeout: 1)

        client.stop()
        XCTAssertEqual(replies.map(\.status), ["stopped"])
        XCTAssertTrue(client.isWorking)
        releaseDiscovery.signal()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            lateCallback.fulfill()
        }
        wait(for: [lateCallback], timeout: 1)
        XCTAssertEqual(revalidations, 0)
        XCTAssertEqual(presses, 0)
        XCTAssertFalse(context.pressGate.attempted)
        XCTAssertEqual(replies.map(\.status), ["stopped"])
        XCTAssertEqual(client.toolResult?.status, "stopped")
    }
}
