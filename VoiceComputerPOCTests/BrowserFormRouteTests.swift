import Foundation
import XCTest

@testable import VoiceComputerPOC

final class BrowserFormRouteTests: XCTestCase {
    func testRouteRequiresMatchingRunAndQuery() throws {
        let output = try JSONSerialization.data(withJSONObject: [
            "route": "browser", "directions": [], "target": "local_form",
        ])
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:49328/docs?run_id=fixture-1234"))
        let phrase = "Open \(url.absoluteString) and submit query test-fixture-1234."
        XCTAssertEqual(
            CommandRoute.parse(output, originalPhrase: phrase),
            .browserForm(url, "test-fixture-1234"))
        XCTAssertEqual(
            RouteHandoff.decide(output, phrase: phrase),
            .browserForm(url, "test-fixture-1234"))
        for unsafe in [
            "Open \(url.absoluteString) and submit query test-other-run.",
            "Open https://example.com/docs?run_id=fixture-1234 and submit query test-fixture-1234.",
            "Open \(url.absoluteString) and submit query private-data.",
            "Open \(url.absoluteString) and submit query test-fixture-1234 twice.",
            "Do not open \(url.absoluteString) and submit query test-fixture-1234.",
        ] {
            XCTAssertNil(CommandRoute.parse(output, originalPhrase: unsafe), unsafe)
        }
    }
}
