import Foundation

struct ApprovalRequest: Identifiable {
    let id: Int
    let serverName: String
    let message: String
    let detail: String
    let supportsSessionGrant: Bool
    let spaceDirection: SpaceDirection?
    let desktopStateRead: Bool

    static func parse(method: String, id: Int, params: [String: Any]) -> ApprovalRequest? {
        let metadata = params["_meta"] as? [String: Any] ?? [:]
        let schema = params["requestedSchema"] as? [String: Any] ?? [:]
        let properties = schema["properties"] as? [String: Any] ?? [:]
        guard method == "mcpServer/elicitation/request",
            params["mode"] as? String == "form", properties.isEmpty
        else { return nil }

        guard metadata["codex_approval_kind"] as? String == "mcp_tool_call" else { return nil }
        if params["serverName"] as? String == "desktop_tool" {
            guard let arguments = metadata["tool_params"] as? [String: Any] else { return nil }
            if arguments.isEmpty {
                return ApprovalRequest(
                    id: id, serverName: "desktop_tool",
                    message: params["message"] as? String ?? "Allow desktop state read?",
                    detail: "Desktop tool · get_desktop_state · read only",
                    supportsSessionGrant: false, spaceDirection: nil,
                    desktopStateRead: true)
            }
            guard arguments.count == 1,
                let direction = arguments["direction"] as? String,
                direction == "left" || direction == "right"
            else { return nil }
            return ApprovalRequest(
                id: id,
                serverName: "desktop_tool",
                message: params["message"] as? String ?? "Allow the Space tool to continue?",
                detail: "Space tool · switch_space · \(direction)",
                supportsSessionGrant: false,
                spaceDirection: SpaceDirection(rawValue: direction), desktopStateRead: false)
        }

        guard params["serverName"] as? String == "cua_repl",
            metadata["connector_id"] as? String == "computer-use"
        else { return nil }

        let connector = metadata["connector_name"] as? String ?? "Computer Use"
        let app = (metadata["tool_params_display"] as? [[String: Any]])?.first?["value"] as? String
        let action = metadata["tool_name"] as? String ?? "app access"
        let detail = [connector, app, action].compactMap { $0 }.joined(separator: " · ")
        let scopes = metadata["persist"] as? [String] ?? []
        return ApprovalRequest(
            id: id,
            serverName: "cua_repl",
            message: params["message"] as? String ?? "Allow \(connector) to continue?",
            detail: detail,
            supportsSessionGrant: scopes.contains("session"), spaceDirection: nil,
            desktopStateRead: false
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

struct SpaceToolApproval {
    enum State: Equatable { case pending, accepted, declined, consumed }

    let requestID: Int
    let commandID: String
    let itemID: String
    let turnID: String
    let direction: SpaceDirection
    var state: State = .pending
}

struct DesktopStateApproval {
    let requestID: Int
    let commandID: String
    let itemID: String
    let turnID: String
    var state: SpaceToolApproval.State = .pending
}

extension AppServerClient {
    func stageSpaceApproval(_ request: ApprovalRequest) -> Bool {
        guard let direction = request.spaceDirection, spaceToolApproval == nil,
            isWorking, let activeCommandID, let itemID = activeMCPToolItemID,
            let turnID, activeMCPToolTurnID == turnID,
            activeMCPToolDirection == direction, requestedToolDirection == direction
        else { return false }
        spaceToolApproval = SpaceToolApproval(
            requestID: request.id, commandID: activeCommandID, itemID: itemID,
            turnID: turnID, direction: direction)
        return true
    }

    func spaceApprovalMatchesCurrent(_ grant: SpaceToolApproval) -> Bool {
        grant.commandID == activeCommandID && grant.itemID == activeMCPToolItemID
            && grant.turnID == turnID && grant.turnID == activeMCPToolTurnID
            && grant.direction == activeMCPToolDirection
            && grant.direction == requestedToolDirection
    }

    func decideSpaceApproval(_ request: ApprovalRequest, allow: Bool, forSession: Bool) -> Bool {
        recordLiveSpaceObservation("approval_decided")
        guard var grant = spaceToolApproval, grant.requestID == request.id,
            grant.state == .pending, spaceApprovalMatchesCurrent(grant), !forSession
        else {
            spaceToolApproval = nil
            return false
        }
        grant.state = allow ? .accepted : .declined
        spaceToolApproval = grant
        return allow
    }

    func hasAcceptedSpaceApproval(commandID: String, itemID: String) -> Bool {
        guard let grant = spaceToolApproval, grant.state == .accepted,
            grant.commandID == commandID, grant.itemID == itemID
        else { return false }
        return spaceApprovalMatchesCurrent(grant)
    }

    func consumeSpaceApproval() {
        spaceToolApproval?.state = .consumed
    }

    func stageDesktopStateApproval(_ request: ApprovalRequest) -> Bool {
        guard request.desktopStateRead, desktopStateApproval == nil,
            requestedDesktopState, isWorking, let activeCommandID,
            let itemID = activeStateToolItemID, let turnID,
            activeStateToolTurnID == turnID
        else { return false }
        desktopStateApproval = DesktopStateApproval(
            requestID: request.id, commandID: activeCommandID,
            itemID: itemID, turnID: turnID)
        return true
    }

    func desktopStateApprovalMatchesCurrent(_ grant: DesktopStateApproval) -> Bool {
        requestedDesktopState && grant.commandID == activeCommandID
            && grant.itemID == activeStateToolItemID
            && grant.turnID == turnID && grant.turnID == activeStateToolTurnID
    }

    func decideDesktopStateApproval(
        _ request: ApprovalRequest, allow: Bool,
        forSession: Bool
    ) -> Bool {
        guard var grant = desktopStateApproval, grant.requestID == request.id,
            grant.state == .pending, desktopStateApprovalMatchesCurrent(grant), !forSession
        else {
            desktopStateApproval = nil
            return false
        }
        grant.state = allow ? .accepted : .declined
        desktopStateApproval = grant
        return allow
    }

    func hasAcceptedDesktopStateApproval(commandID: String, itemID: String) -> Bool {
        guard let grant = desktopStateApproval, grant.state == .accepted,
            grant.commandID == commandID, grant.itemID == itemID
        else { return false }
        return desktopStateApprovalMatchesCurrent(grant)
    }
}
