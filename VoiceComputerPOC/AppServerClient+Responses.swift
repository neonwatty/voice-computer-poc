import AppKit
import Foundation

extension AppServerClient {
    func handleResponse(id: Int, message: [String: Any]) {
        guard let kind = pending.removeValue(forKey: id) else {
            record("unexpected_rpc_response", details: ["id": String(id)])
            return
        }
        if let error = message["error"] as? [String: Any] {
            record(
                "rpc_failed",
                details: [
                    "id": String(id), "method": kind.name,
                    "error": error["message"] as? String ?? "Unknown error",
                ])
            if kind == .mcpStatus, requestedToolDirection == nil {
                record("mcp_status_unavailable_for_general_turn")
                startThread()
                return
            }
            fail("Codex request failed: \(error["message"] as? String ?? "Unknown error")")
            return
        }
        record("rpc_completed", details: ["id": String(id), "method": kind.name])
        let payload = message["result"] as? [String: Any] ?? [:]
        switch kind {
        case .initialize:
            sendRaw(["method": "initialized", "params": [String: Any]()])
            _ = send("model/list", params: [:], pendingKind: .models)
        case .models:
            selectModelAndDiscoverTool(payload)
        case .thread:
            guard let thread = payload["thread"] as? [String: Any],
                let id = thread["id"] as? String
            else {
                fail("Codex did not return a thread ID.")
                return
            }
            threadID = id
            append("Connected to Codex")
            startTurn(threadID: id)
        case .mcpStatus:
            handleMCPStatus(payload)
        case .turn:
            if let turn = payload["turn"] as? [String: Any] {
                turnID = turn["id"] as? String
                record("turn_started", details: ["turn_id": turnID ?? "unknown"])
            }
        case .interrupt:
            append("Stop requested")
        }
    }

    private func selectModelAndDiscoverTool(_ payload: [String: Any]) {
        let models = payload["data"] as? [[String: Any]] ?? []
        let available = models.compactMap { $0["id"] as? String }
        guard let model = available.first(where: { $0 == "gpt-5.6-sol" }) ?? available.first else {
            fail("Codex reported no available models.")
            return
        }
        selectedModel = model
        append("Using model \(model)")
        _ = send(
            "mcpServerStatus/list", params: ["detail": "toolsAndAuthOnly"],
            pendingKind: .mcpStatus)
    }

    private func startThread() {
        guard let model = selectedModel else {
            fail("Codex model selection is unavailable.")
            return
        }
        guard let workingDirectory = serverDirectory?.path else {
            fail("Codex working directory is unavailable.")
            return
        }
        _ = send(
            "thread/start",
            params: [
                "model": model,
                "cwd": workingDirectory,
                "approvalPolicy": "on-request",
                "sandbox": "read-only",
            ], pendingKind: .thread)
    }

    private func handleMCPStatus(_ payload: [String: Any]) {
        let servers = payload["data"] as? [[String: Any]] ?? []
        let desktop = servers.first { $0["name"] as? String == "desktop_tool" }
        let tools = desktop?["tools"] as? [String: Any] ?? [:]
        guard tools["switch_space"] != nil else {
            if requestedToolDirection == nil {
                record("mcp_tool_unavailable_for_general_turn")
                startThread()
            } else {
                fail("The desktop_tool.switch_space MCP tool is unavailable.")
            }
            return
        }
        guard spaceToolBridge?.pinReadyHelper() == true else {
            if requestedToolDirection == nil {
                record("mcp_helper_unavailable_for_general_turn")
                startThread()
            } else {
                fail("The desktop_tool helper identity could not be confirmed.")
            }
            return
        }
        record("mcp_tool_ready", details: ["server": "desktop_tool", "tool": "switch_space"])
        record("mcp_helper_bound", details: ["pid": String(spaceToolBridge?.helperPID ?? -1)])
        startThread()
    }

    func handleServerRequest(method: String, id: Int, params: [String: Any]) {
        if method == "mcpServer/elicitation/request" {
            let schema = params["requestedSchema"] as? [String: Any] ?? [:]
            let properties = schema["properties"] as? [String: Any] ?? [:]
            let metadata = params["_meta"] as? [String: Any] ?? [:]
            record(
                "elicitation_envelope",
                details: [
                    "request_id": String(id),
                    "server_name": params["serverName"] as? String ?? "missing",
                    "mode": params["mode"] as? String ?? "missing",
                    "property_count": String(properties.count),
                    "property_names": properties.keys.sorted().joined(separator: ","),
                    "meta_keys": metadata.keys.sorted().joined(separator: ","),
                    "connector_id": metadata["connector_id"] as? String ?? "missing",
                ])
        }
        if let request = ApprovalRequest.parse(method: method, id: id, params: params) {
            if approval == nil { approval = request } else { queuedApprovals.append(request) }
            status = "Waiting for your approval"
            append("Approval needed for \(request.serverName)")
            record(
                "approval_requested",
                details: [
                    "request_id": String(id), "server_name": request.serverName,
                    "session_grant_available": String(request.supportsSessionGrant),
                ])
        } else {
            if method == "mcpServer/elicitation/request", requestedToolDirection == nil {
                generalTurnFailure = .approvalUnavailable
            }
            sendRaw(["id": id, "error": ["code": -32601, "message": "Unsupported request in prototype"]])
            append("Unsupported server request: \(method)")
            record("unsupported_server_request", details: ["method": method])
        }
    }

}
