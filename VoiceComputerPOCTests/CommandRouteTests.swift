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

    func testRouterLaunchDisablesDesktopTools() {
        let arguments = RouterAgent.isolatedArguments ?? []
        XCTAssertTrue(arguments.contains("--ignore-user-config"))
        XCTAssertTrue(arguments.contains("shell_tool"))
        XCTAssertTrue(arguments.contains("plugins"))
        XCTAssertTrue(arguments.contains("apps._default.enabled=false"))
        XCTAssertTrue(arguments.contains("--json"))
    }

    private func data(_ route: String, _ directions: [String], _ target: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "route": route, "directions": directions, "target": target,
        ])
    }
}
