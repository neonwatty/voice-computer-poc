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
            let models = payload["data"] as? [[String: Any]] ?? []
            let available = models.compactMap { $0["id"] as? String }
            guard let model = available.first(where: { $0 == "gpt-5.6-sol" }) ?? available.first else {
                fail("Codex reported no available models.")
                return
            }
            append("Using model \(model)")
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
        case .turn:
            if let turn = payload["turn"] as? [String: Any] {
                turnID = turn["id"] as? String
                record("turn_started", details: ["turn_id": turnID ?? "unknown"])
            }
        case .interrupt:
            append("Stop requested")
        }
    }

    func handleServerRequest(method: String, id: Int, params: [String: Any]) {
        if let request = ApprovalRequest.parse(method: method, id: id, params: params) {
            if approval == nil { approval = request } else { queuedApprovals.append(request) }
            status = "Waiting for your approval"
            append("Approval needed: \(request.detail)")
            record(
                "approval_requested",
                details: [
                    "request_id": String(id), "detail": request.detail,
                    "session_grant_available": String(request.supportsSessionGrant),
                ])
        } else {
            sendRaw(["id": id, "error": ["code": -32601, "message": "Unsupported request in prototype"]])
            append("Unsupported server request: \(method)")
            record("unsupported_server_request", details: ["method": method])
        }
    }

}
