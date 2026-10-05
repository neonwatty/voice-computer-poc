import Foundation
import XCTest

@testable import VoiceComputerPOC

final class BrowserFinderRouteTests: XCTestCase {
    func testBrowserThenFinderRequiresOneMatchedFixture() throws {
        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceComputerPOC/TestFixtures/\(runID)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("report.txt")
        try Data("report".utf8).write(to: report)
        let home = try XCTUnwrap(URL(string: "http://127.0.0.1:49328/home?run_id=\(runID)"))
        let phrase =
            "Open \(home.absoluteString) and follow the Docs link, then reveal the test report at \(report.path) in Finder."
        let output = try data("browser_finder", [], "local_docs_fixture_report")
        XCTAssertEqual(
            CommandRoute.parse(output, originalPhrase: phrase),
            .browserThenFinder(home, report))
        XCTAssertEqual(
            RouteHandoff.decide(output, phrase: phrase),
            .browserThenFinder(home, report))
        let wrongID = phrase.replacingOccurrences(
            of: "run_id=\(runID)", with: "run_id=00000000000000000000000000000000")
        for unsafe in [
            wrongID,
            "Do not \(phrase)",
            phrase + " Delete the file.",
            phrase.replacingOccurrences(of: "link, then", with: "link or then"),
            phrase.replacingOccurrences(of: " in Finder.", with: " in Finder, then open Calculator."),
        ] {
            XCTAssertNil(CommandRoute.parse(output, originalPhrase: unsafe), unsafe)
        }
        try FileManager.default.removeItem(at: report)
        XCTAssertNil(CommandRoute.parse(output, originalPhrase: phrase))
    }

    private func data(_ route: String, _ directions: [String], _ target: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "route": route, "directions": directions, "target": target,
        ])
    }
}
