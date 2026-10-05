import CryptoKit
import Foundation
import XCTest

@testable import VoiceComputerPOC

final class CommandRouteTests: XCTestCase {
    func testStrictSchemaRejectsExtraKeysAndWrongDirection() throws {
        let wrong = try data("space", ["left"], "")
        XCTAssertNil(CommandRoute.parse(wrong, originalPhrase: "Move right one desktop Space"))
        let extra = Data(
            #"{"route":"space","directions":["right"],"target":"","extra":true}"#.utf8)
        XCTAssertNil(CommandRoute.parse(extra, originalPhrase: "Move right one desktop Space"))
    }

    func testClarificationCasesNeverProduceAction() throws {
        let cases = [
            "Switch two desktops left", "Go left or right", "Calculator or the next desktop",
            "Switch to the rite space", "Open Safari",
        ]
        for phrase in cases {
            XCTAssertNil(CommandRoute.parse(try data("space", ["left"], ""), originalPhrase: phrase))
            XCTAssertNil(
                CommandRoute.parse(
                    try data("computer_use", [], "calculator"), originalPhrase: phrase))
            XCTAssertEqual(
                CommandRoute.parse(try data("clarification", [], ""), originalPhrase: phrase),
                .clarification)
        }
    }

    func testValidatedHandoffDirections() throws {
        XCTAssertEqual(
            CommandRoute.parse(
                try data("space", ["right", "left"], ""),
                originalPhrase: "Go right one desktop space, then back left"),
            .space([.right, .left]))
        XCTAssertNil(
            CommandRoute.parse(
                try data("space", ["left", "right"], ""),
                originalPhrase: "Go right one desktop space, then back left"))
        XCTAssertEqual(
            CommandRoute.parse(
                try data("computer_use", [], "calculator"), originalPhrase: "Open Calculator"),
            .computerUse("calculator"))
    }

    func testBrowserFixtureRouteRequiresExactLocalWorkflow() throws {
        let output = try data("browser", [], "local_docs")
        let phrase = "Open http://127.0.0.1:49328/home?run_id=fixture-1234 and follow the Docs link."
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:49328/home?run_id=fixture-1234"))
        XCTAssertEqual(CommandRoute.parse(output, originalPhrase: phrase), .browserDocs(url))
        XCTAssertEqual(RouteHandoff.decide(output, phrase: phrase), .browserDocs(url))
        for unsafe in [
            "Open https://example.com/home?run_id=fixture-1234 and follow the Docs link.",
            "Open file:///home?run_id=fixture-1234 and follow the Docs link.",
            "Open http://127.0.0.1:49328/home and follow the Docs link.",
            "Open http://127.0.0.1:49328/home?run_id=fixture-1234 and follow the Docs link, then delete it.",
            "Open http://127.0.0.1:99999/home?run_id=fixture-1234 and follow the Docs link.",
            "Do not open http://127.0.0.1:49328/home?run_id=fixture-1234 and follow the Docs link.",
        ] {
            XCTAssertNil(CommandRoute.parse(output, originalPhrase: unsafe), unsafe)
        }
        XCTAssertNil(CommandRoute.parse(try data("browser", ["left"], "local_docs"), originalPhrase: phrase))
        XCTAssertNil(CommandRoute.parse(try data("browser", [], "calculator"), originalPhrase: phrase))
    }

    func testFinderRouteRequiresCanonicalExistingFixtureReport() throws {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceComputerPOC/TestFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let report = root.appendingPathComponent("report.txt")
        try Data("test report".utf8).write(to: report)
        let decoy = root.appendingPathComponent("report-copy.txt")
        try Data("decoy".utf8).write(to: decoy)
        let output = try data("finder", [], "fixture_report")
        let phrase = "Reveal the test report at \(report.path) in Finder."
        XCTAssertEqual(CommandRoute.parse(output, originalPhrase: phrase), .finderReveal(report))
        XCTAssertEqual(RouteHandoff.decide(output, phrase: phrase), .finderReveal(report))
        for unsafe in [
            "Reveal the test report at \(decoy.path) in Finder.",
            "Reveal the test report at \(root.appendingPathComponent("missing.txt").path) in Finder.",
            "Delete the test report at \(report.path) in Finder.",
            "Reveal the test report at \(report.path) in Finder, then open it.",
        ] {
            XCTAssertNil(CommandRoute.parse(output, originalPhrase: unsafe), unsafe)
        }
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Data("outside".utf8).write(to: outside.appendingPathComponent("report.txt"))
        let linkedDirectory = root.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: linkedDirectory) }
        XCTAssertNil(
            CommandRoute.parse(
                output,
                originalPhrase:
                    "Reveal the test report at \(linkedDirectory.appendingPathComponent("report.txt").path) in Finder."
            ))
    }

    func testReversedNegatedAndUncertainDirectionsAreRejected() throws {
        let roundTrip = try data("space", ["right", "left"], "")
        for phrase in [
            "Go left one desktop space, then back right",
            "Do not go right one desktop space, then back left",
            "Maybe go right one desktop space, then back left",
            "Go right one desktop space, or maybe back left",
        ] {
            XCTAssertNil(CommandRoute.parse(roundTrip, originalPhrase: phrase), phrase)
        }
        let right = try data("space", ["right"], "")
        for phrase in [
            "Do not move right one desktop Space",
            "Never switch to the next desktop",
            "Maybe move right one Space",
            "Switch two desktop Spaces right",
        ] {
            XCTAssertNil(CommandRoute.parse(right, originalPhrase: phrase), phrase)
        }
    }

    func testToolFreeTraceRejectsToolEvents() {
        let good = Data(
            """
            {"type":"thread.started"}
            {"type":"item.completed","item":{"type":"agent_message"}}
            {"type":"turn.completed"}

            """.utf8)
        XCTAssertTrue(RouterAgent.toolFreeTrace(good))
        let tool = Data(
            """
            {"type":"item.started","item":{"type":"mcp_tool_call"}}
            {"type":"turn.completed"}

            """.utf8)
        XCTAssertFalse(RouterAgent.toolFreeTrace(tool))
        XCTAssertFalse(RouterAgent.toolFreeTrace(Data("invalid".utf8)))
    }

    func testRouterLaunchDisablesDesktopTools() throws {
        let resources = try XCTUnwrap(RouterAgent.loadResources(from: Bundle.main.resourceURL))
        XCTAssertEqual(resources.arguments, RouterAgent.requiredArguments)
        XCTAssertTrue(resources.arguments.contains("--ignore-user-config"))
        XCTAssertTrue(resources.arguments.contains("read-only"))
        for name in ["shell_tool", "plugins", "multi_agent"] {
            XCTAssertTrue(resources.arguments.contains(name))
        }
        XCTAssertTrue(resources.arguments.contains("apps._default.enabled=false"))
        XCTAssertTrue(resources.arguments.contains("--json"))
    }

    func testPackagedRouterResourcesMatchCanonicalBytes() throws {
        let directory = try XCTUnwrap(Bundle.main.resourceURL)
        let expectedHashes = [
            "router-instruction.txt": "483ebf0f0a1507490df35caacbc98c8f89cfba3a26e0baa728a51cf6760170a4",
            "router-cli-args.json": "8284e45d79194b0fc3660c0bda624b87cc6885781813d785d420abacc586014a",
            "router-output.schema.json": "75dcbb226160c498ef5fa9f329bc49dd76ea240299c7710977f159ff332054ac",
        ]
        for (name, expected) in expectedHashes {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, expected, name)
        }
    }

    func testMissingOrInvalidRouterResourcesStartNoActor() throws {
        let packaged = try XCTUnwrap(Bundle.main.resourceURL)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("router-resource-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let names = [
            "router-instruction.txt", "router-cli-args.json", "router-output.schema.json",
        ]
        for name in names {
            let data = try Data(contentsOf: packaged.appendingPathComponent(name))
            try data.write(to: temporary.appendingPathComponent(name))
        }
        XCTAssertNotNil(RouterAgent.loadResources(from: temporary))
        for (name, replacement) in [
            ("router-instruction.txt", Data(" ".utf8)),
            ("router-cli-args.json", Data("[]".utf8)),
            ("router-cli-args.json", Data("not json".utf8)),
            ("router-output.schema.json", Data("{}".utf8)),
        ] {
            let url = temporary.appendingPathComponent(name)
            let original = try Data(contentsOf: url)
            try replacement.write(to: url)
            XCTAssertNil(RouterAgent.loadResources(from: temporary), name)
            var returned = false
            RouterAgent.classify("Open Calculator", resourceDirectory: temporary) { result in
                returned = true
                XCTAssertNil(result)
            }
            XCTAssertTrue(returned, name)
            try original.write(to: url)
        }
        try FileManager.default.removeItem(at: temporary.appendingPathComponent("router-cli-args.json"))
        XCTAssertNil(RouterAgent.loadResources(from: temporary))
        XCTAssertNil(RouterAgent.loadResources(from: nil))
    }

    private func data(_ route: String, _ directions: [String], _ target: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "route": route, "directions": directions, "target": target,
        ])
    }
}

final class DesktopToolPreflightTests: XCTestCase {
    func testBundledPreflightRunsOffMainAndResolvesExecutable() {
        let preflight = DesktopToolPreflight()
        let responsive = expectation(description: "main queue remained responsive")
        let finished = expectation(description: "preflight completed")
        var resolved: String?
        var failure: String?
        preflight.start { outcome in
            if case .ready(let path) = outcome { resolved = path }
            if case .failed(let reason) = outcome { failure = reason }
            finished.fulfill()
        }
        DispatchQueue.main.async { responsive.fulfill() }
        wait(for: [responsive, finished], timeout: 3)
        XCTAssertNotNil(resolved, failure ?? "no callback")
        XCTAssertTrue(resolved.map(FileManager.default.isExecutableFile(atPath:)) ?? false)
    }

    func testBundledPreflightRejectsInvalidArtifacts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Fixture.app")
        let binary = bundle.appendingPathComponent(DesktopToolPreflight.helperRelativePath)
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        assertPreflightFailure(DesktopToolPreflight(bundleURL: bundle), "binary_missing")
        let data = Data("helper fixture".utf8)
        try data.write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: binary.path)
        assertPreflightFailure(DesktopToolPreflight(bundleURL: bundle), "binary_not_executable")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let manifest = URL(fileURLWithPath: binary.path + ".sha256")
        try "0".padding(toLength: 64, withPad: "0", startingAt: 0).write(
            to: manifest,
            atomically: true, encoding: .utf8)
        assertPreflightFailure(DesktopToolPreflight(bundleURL: bundle), "binary_mismatch")
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        try digest.write(to: manifest, atomically: true, encoding: .utf8)
        assertPreflightFailure(
            DesktopToolPreflight(
                bundleURL: bundle,
                helperURL: root.appendingPathComponent("escaped")), "path_mismatch")
        let real = root.appendingPathComponent("real-helper")
        try FileManager.default.moveItem(at: binary, to: real)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: real)
        assertPreflightFailure(DesktopToolPreflight(bundleURL: bundle), "path_mismatch")
    }

    func testPreflightTimeoutAndCancellationFailClosed() {
        assertPreflightFailure(
            DesktopToolPreflight(timeout: 0.01, validationDelay: 0.2),
            "validation_timeout")
        let preflight = DesktopToolPreflight(validationDelay: 0.2)
        let finished = expectation(description: "cancelled preflight")
        preflight.start { outcome in
            if case .failed(let reason) = outcome {
                XCTAssertEqual(reason, "validation_cancelled")
            } else {
                XCTFail("Cancellation admitted a helper")
            }
            finished.fulfill()
        }
        preflight.cancel()
        wait(for: [finished], timeout: 3)
    }

    private func assertPreflightFailure(_ preflight: DesktopToolPreflight, _ reason: String) {
        let finished = expectation(description: "preflight rejected \(reason)")
        preflight.start { outcome in
            if case .failed(let actual) = outcome {
                XCTAssertEqual(actual, reason)
            } else {
                XCTFail("Invalid helper was admitted")
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 3)
    }
}
