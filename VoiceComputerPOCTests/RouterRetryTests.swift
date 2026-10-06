import Foundation
import XCTest

@testable import VoiceComputerPOC

final class RouterRetryTests: XCTestCase {
    #if DEBUG
        func testUnavailableRouterOutputGetsOneReadOnlyRetry() {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = AppServerClient(logDirectory: directory)
            client.isWorking = true
            client.activeCommandID = "router-command"
            var attempts = 0
            client.routingOverride = { phrase in
                attempts += 1
                client.processRouterOutput(nil, phrase: phrase)
            }
            client.routePhrase("Open Safari")
            XCTAssertEqual(attempts, 2)
            XCTAssertFalse(client.isWorking)
            XCTAssertEqual(client.diagnosticEntries.filter { $0.event == "router_output_retry" }.count, 1)

            client.isWorking = true
            client.activeCommandID = "invalid-command"
            attempts = 0
            client.routerOutputRetried = false
            client.routingOverride = { phrase in
                attempts += 1
                client.processRouterOutput(Data("invalid".utf8), phrase: phrase)
            }
            client.routePhrase("Open Safari")
            XCTAssertEqual(attempts, 1)
            XCTAssertFalse(client.isWorking)
        }
    #endif
}
