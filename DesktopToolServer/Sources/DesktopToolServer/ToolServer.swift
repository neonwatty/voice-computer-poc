import Foundation
import MCP

struct ToolResult: Codable, Equatable, Sendable {
    let commandID: String
    let status: String
    let direction: String
    let beforeID: Int?
    let expectedID: Int?
    let afterID: Int?
    let notificationObserved: Bool
    let message: String

    var verified: Bool {
        status == "verified" && expectedID != nil && afterID == expectedID
            && notificationObserved
    }

    static func failure(_ status: String, _ direction: String, _ message: String) -> Self {
        .init(
            commandID: "unknown", status: status, direction: direction,
            beforeID: nil, expectedID: nil, afterID: nil,
            notificationObserved: false, message: message)
    }
}

enum ToolServer {
    static let toolName = "switch_space"

    static func definition() -> Tool {
        Tool(
            name: toolName,
            description: "Move one adjacent macOS desktop Space and verify the result.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "direction": .object([
                        "type": .string("string"),
                        "enum": .array([.string("left"), .string("right")]),
                    ])
                ]),
                "required": .array([.string("direction")]),
                "additionalProperties": .bool(false),
            ]))
    }

    static func call(arguments: [String: Value]?, bridge: (String) -> ToolResult) -> ToolResult {
        guard let arguments, arguments.count == 1,
            let direction = arguments["direction"]?.stringValue,
            direction == "left" || direction == "right"
        else { return .failure("invalid_direction", "unknown", "Use exactly left or right.") }
        if Task.isCancelled {
            return .failure("interrupted", direction, "The tool call was cancelled.")
        }
        let result = bridge(direction)
        if result.status == "verified" && !result.verified {
            return .failure("unverified", direction, "App verification was incomplete.")
        }
        return result
    }

    static func toolResponse(_ result: ToolResult) -> CallTool.Result {
        let data = (try? JSONEncoder().encode(result)) ?? Data()
        return .init(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            isError: !result.verified)
    }

    static func stage(_ marker: String) {
        FileHandle.standardError.write(Data("mcp_stage=\(marker)\n".utf8))
    }
}
