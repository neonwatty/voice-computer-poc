import ApplicationServices
import XCTest

@testable import VoiceComputerPOC

final class WindowManagerAXExecutionTests: XCTestCase {
    func testMacOS27UsesWindowManagerAndRejectsStaleControls() {
        XCTAssertEqual(NativeSpaceAXExecution.source(forMajorVersion: 26), .dock)
        XCTAssertEqual(NativeSpaceAXExecution.source(forMajorVersion: 27), .windowManager)
        let element = AXUIElementCreateSystemWide()
        let discovery = MissionControlAXDiscovery(
            list: element, target: element, source: .windowManager)
        XCTAssertThrowsError(try NativeSpaceAXExecution.revalidate(discovery, number: 2, expectedCount: 2))
    }
}
