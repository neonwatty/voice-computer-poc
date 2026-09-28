import Foundation
import XCTest

@testable import VoiceComputerPOC

final class DiagnosticLogTests: XCTestCase {
    func testRecordsAreParseableLinesIncludingSpecialCharacters() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = try DiagnosticLog(directory: directory)
        let liveEntry = try log.record(
            "command_started", details: ["phrase": "Open \"Calculator\"\nnow"])
        try log.record("tool_completed", details: ["status": "completed"])

        let data = try Data(contentsOf: log.fileURL)
        let lines = data.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        let entries = try lines.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
        }
        XCTAssertEqual(entries[0]["event"] as? String, "command_started")
        XCTAssertEqual(liveEntry.timestamp, entries[0]["timestamp"] as? String)
        XCTAssertEqual(
            liveEntry.details["phrase"],
            (entries[0]["details"] as? [String: String])?["phrase"])
        XCTAssertEqual(
            (entries[0]["details"] as? [String: String])?["phrase"], "Open \"Calculator\"\nnow"
        )
        XCTAssertNotNil(entries[0]["timestamp"] as? String)
        XCTAssertEqual(entries[1]["event"] as? String, "tool_completed")
    }

    func testLogProtectsAndBoundsDetails() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = try DiagnosticLog(directory: directory)
        let entry = try log.record("tool_completed", details: ["error": String(repeating: "x", count: 5_000)])
        let attributes = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)

        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertEqual(entry.details["error"]?.count, 2_000)
        XCTAssertEqual(
            try Data(contentsOf: log.fileURL).split(separator: 0x0A).count,
            1
        )
    }
}
