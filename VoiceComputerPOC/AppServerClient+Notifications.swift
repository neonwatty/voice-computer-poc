import AppKit
import Foundation

extension AppServerClient {
    func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "item/started":
            if let item = params["item"] as? [String: Any] { handleItemStarted(item) }
        case "item/completed":
            if let item = params["item"] as? [String: Any] { handleItemCompleted(item) }
        case "turn/completed":
            handleTurnCompleted(params["turn"] as? [String: Any] ?? [:])
        case "error":
            let error = params["error"] as? [String: Any] ?? [:]
            fail(error["message"] as? String ?? "Codex reported an error")
        default:
            break
        }
    }

    func handleItemStarted(_ item: [String: Any]) {
        guard item["type"] as? String == "mcpToolCall" else { return }
        let server = item["server"] as? String ?? "tool"
        let tool = item["tool"] as? String ?? "call"
        append("Using \(server).\(tool)")
        record(
            "tool_started",
            details: [
                "item_id": item["id"] as? String ?? "unknown",
                "server": server, "tool": tool,
            ])
    }

    func handleItemCompleted(_ item: [String: Any]) {
        if item["type"] as? String == "agentMessage", let text = item["text"] as? String,
            !text.isEmpty
        {
            result = text
        } else if item["type"] as? String == "mcpToolCall" {
            handleToolCompleted(item)
        }
    }

    func handleToolCompleted(_ item: [String: Any]) {
        let directError = (item["error"] as? [String: Any])?["message"] as? String
        let toolResult = item["result"] as? [String: Any]
        let content = toolResult?["content"] as? [[String: Any]]
        let resultError = content?.compactMap { $0["text"] as? String }.first
        let detail = directError ?? resultError
        let status = item["status"] as? String ?? "unknown"
        let resultIsError = toolResult?["isError"] as? Bool ?? false
        var fields = [
            "item_id": item["id"] as? String ?? "unknown",
            "server": item["server"] as? String ?? "tool",
            "tool": item["tool"] as? String ?? "call",
            "status": status,
            "result_is_error": String(resultIsError),
        ]
        if status == "failed" || resultIsError {
            fields["error"] = detail ?? "Unknown tool error"
            append(
                detail.map { "Computer Use tool call failed: \(String($0.prefix(500)))" }
                    ?? "Computer Use tool call failed")
        }
        record("tool_completed", details: fields)
    }

    func handleTurnCompleted(_ turn: [String: Any]) {
        guard isWorking else {
            record(
                "unexpected_turn_completed",
                details: ["turn_id": turn["id"] as? String ?? "unknown"])
            return
        }
        let outcome = turn["status"] as? String ?? "completed"
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        status = outcome == "completed" ? "Ready" : "Turn \(outcome)"
        append("Turn \(outcome)")
        if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
            result = message
        }
        let verification = verifyTurnOutcome(outcome, frontmostBundleID: frontmostBundleID)
        record(
            "turn_completed",
            details: [
                "turn_id": turnID ?? "unknown", "status": outcome, "result": result,
                "frontmost_app": lastActivatedApp,
                "frontmost_bundle_id": frontmostBundleID ?? "unknown",
                "activated_bundle_ids": activatedBundleIDsThisTurn.sorted().joined(separator: ","),
                "space_change_count": String(spaceChangeCount),
                "verification": verification,
                "elapsed_ms": commandElapsedMilliseconds,
            ])
        record(
            "command_finished",
            details: [
                "status": outcome, "verification": verification,
                "elapsed_ms": commandElapsedMilliseconds,
            ])
        focusTargetBundleID = nil
        activatedBundleIDsThisTurn.removeAll()
        isWorking = false
        turnID = nil
        approval = nil
        queuedApprovals.removeAll()
        finishCommand()
    }

    func verifyTurnOutcome(_ outcome: String, frontmostBundleID: String?) -> String {
        var verification = "model_report_only"
        if let baseline = spaceCountAtTurnStart {
            if spaceChangeCount > baseline {
                verification = "verified"
                append("Verified: macOS reported an active Space change during this command")
            } else {
                verification = "unverified"
                append("Unverified: macOS reported no active Space change during this command")
                if outcome == "completed" {
                    result =
                        "The shortcut was attempted, but macOS reported no active Space change. The Space switch is unverified."
                }
            }
        }
        spaceCountAtTurnStart = nil
        if let target = focusTargetBundleID {
            if frontmostBundleID == target {
                verification = "verified"
                append("Verified: requested app is frontmost")
            } else {
                verification = "unverified"
                append("Unverified: requested app is not frontmost")
                if outcome == "completed" {
                    result =
                        "Computer Use inspected the app window, but macOS does not report the requested app as frontmost. Foreground focus is unverified."
                }
            }
        }
        return verification
    }
}
