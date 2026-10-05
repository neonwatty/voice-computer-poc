import Foundation
import MCP

struct DesktopStateToolResult: Codable, Equatable, Sendable {
    let status: String
    let observedAt: String?
    let displayScope: String?
    let currentMainSpaceID: Int?
    let orderedMainSpaceIDs: [Int]?
    let frontmostBundleID: String?
    let message: String

    var verified: Bool {
        status == "observed" && observedAt != nil && displayScope == "Main"
            && currentMainSpaceID != nil && orderedMainSpaceIDs?.contains(currentMainSpaceID ?? -1) == true
            && frontmostBundleID?.isEmpty == false
    }

    static func failure(_ status: String, _ message: String) -> Self {
        .init(
            status: status, observedAt: nil, displayScope: nil,
            currentMainSpaceID: nil, orderedMainSpaceIDs: nil,
            frontmostBundleID: nil, message: message)
    }
}

enum StateToolServer {
    static let toolName = "get_desktop_state"

    static func definition() -> Tool {
        Tool(
            name: toolName,
            description: "Read the live Main desktop Space and foreground app without changing them.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:]),
                "additionalProperties": .bool(false),
            ]))
    }

    static func call(arguments: [String: Value]?, bridge: () -> DesktopStateToolResult)
        -> DesktopStateToolResult
    {
        guard arguments?.isEmpty ?? true else {
            return .failure("invalid_arguments", "This read-only tool takes no arguments.")
        }
        if Task.isCancelled {
            return .failure("interrupted", "The tool call was cancelled.")
        }
        let result = bridge()
        if result.status == "observed" && !result.verified {
            return .failure("unavailable", "Desktop observation was incomplete.")
        }
        return result
    }

    static func toolResponse(_ result: DesktopStateToolResult) -> CallTool.Result {
        let data = (try? JSONEncoder().encode(result)) ?? Data()
        return .init(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            isError: !result.verified)
    }
}
