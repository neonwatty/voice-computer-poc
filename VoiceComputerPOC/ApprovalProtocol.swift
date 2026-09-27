import Foundation

struct ApprovalRequest: Identifiable {
    let id: Int
    let message: String
    let detail: String
    let supportsSessionGrant: Bool

    static func parse(method: String, id: Int, params: [String: Any]) -> ApprovalRequest? {
        let metadata = params["_meta"] as? [String: Any] ?? [:]
        let schema = params["requestedSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        guard method == "mcpServer/elicitation/request",
            params["mode"] as? String == "form",
            metadata["connector_id"] as? String == "computer-use",
            properties.isEmpty
        else { return nil }

        let connector = metadata["connector_name"] as? String ?? "Computer Use"
        let app = (metadata["tool_params_display"] as? [[String: Any]])?.first?["value"] as? String
        let action = metadata["tool_name"] as? String ?? "app access"
        let detail = [connector, app, action].compactMap { $0 }.joined(separator: " · ")
        let scopes = metadata["persist"] as? [String] ?? []
        return ApprovalRequest(
            id: id,
            message: params["message"] as? String ?? "Allow \(connector) to continue?",
            detail: detail,
            supportsSessionGrant: scopes.contains("session")
        )
    }

    func response(allow: Bool, forSession: Bool) -> [String: Any] {
        var result: [String: Any] =
            allow
            ? ["action": "accept", "content": [String: Any]()]
            : ["action": "decline", "content": NSNull()]
        if allow && forSession && supportsSessionGrant {
            result["_meta"] = ["persist": "session"]
        }
        return ["id": id, "result": result]
    }
}
