import AppKit
import Foundation

extension AppServerClient {
    func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "item/started":
            if let item = params["item"] as? [String: Any] {
                handleItemStarted(item, eventTurnID: params["turnId"] as? String)
            }
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

    func handleItemStarted(_ item: [String: Any], eventTurnID: String? = nil) {
        guard item["type"] as? String == "mcpToolCall" else { return }
        let server = item["server"] as? String ?? "tool"
        let tool = item["tool"] as? String ?? "call"
        let direction = SpaceToolRequest.direction(fromArguments: item["arguments"])
        if server == "desktop_tool" && tool == "switch_space",
            direction == requestedToolDirection, isWorking, activeCommandID != nil,
            let turnID, let eventTurnID, eventTurnID == turnID,
            let itemID = item["id"] as? String, !itemID.isEmpty,
            activeMCPToolItemID == nil
        {
            toolCallObserved = true
            activeMCPToolItemID = itemID
            activeMCPToolTurnID = turnID
            activeMCPToolDirection = direction
        } else if server == "cua_repl" {
            generalToolObserved = true
        }
        append("Using \(server).\(tool)")
        record(
            "tool_started",
            details: [
                "item_id": item["id"] as? String ?? "unknown",
                "server": server, "tool": tool,
                "event_turn_id": eventTurnID ?? "missing",
                "turn_matches": String(eventTurnID != nil && eventTurnID == turnID),
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
        let typed = (content?.first?["text"] as? String)?.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(SpaceToolResult.self, from: $0) }
        let isSpaceTool =
            item["server"] as? String == "desktop_tool"
            && item["tool"] as? String == "switch_space"
        let isActiveSpaceTool = isSpaceTool && item["id"] as? String == activeMCPToolItemID
        if isActiveSpaceTool, let typed, !typed.verified, self.toolResult == nil {
            self.toolResult = typed
        }
        if isActiveSpaceTool,
            status == "completed", !resultIsError, let typed,
            typed == self.toolResult
        {
            toolCallCompleted = true
            record(
                "mcp_tool_result_correlated",
                details: [
                    "tool_command_id": typed.commandID,
                    "direction": typed.direction,
                    "space_before_id": typed.beforeID.map(String.init) ?? "unknown",
                ])
        }
        var fields = [
            "item_id": item["id"] as? String ?? "unknown",
            "server": item["server"] as? String ?? "tool",
            "tool": item["tool"] as? String ?? "call",
            "status": status,
            "result_is_error": String(resultIsError),
        ]
        if status == "failed" || resultIsError {
            if item["server"] as? String == "cua_repl", generalTurnFailure == nil {
                generalTurnFailure = .toolFailed
            }
            fields["error"] = detail ?? "Unknown tool error"
            let label = isSpaceTool ? "Space tool call failed" : "Computer Use tool call failed"
            append(
                detail.map { "\(label): \(String($0.prefix(500)))" }
                    ?? label)
        }
        if isSpaceTool, let typed {
            fields["typed_status"] = typed.status
            fields["typed_command_id"] = typed.commandID
            fields["typed_direction"] = typed.direction
            fields["typed_verified"] = String(typed.verified)
        }
        record("tool_completed", details: fields)
        if isSpaceTool, item["id"] as? String == activeMCPToolItemID {
            spaceToolApproval = nil
            activeMCPToolItemID = nil
            activeMCPToolTurnID = nil
            activeMCPToolDirection = nil
            spaceToolBridge?.revoke()
        }
    }

    func handleTurnCompleted(_ turn: [String: Any]) {
        guard isWorking else {
            record(
                "unexpected_turn_completed",
                details: ["turn_id": turn["id"] as? String ?? "unknown"])
            return
        }
        if requestCalculatorFocusAfterTool(turn) { return }
        finishTurnCompleted(turn)
    }

    func finishTurnCompleted(_ turn: [String: Any]) {
        let outcome = turn["status"] as? String ?? "completed"
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        status = outcome == "completed" ? "Ready" : "Turn \(outcome)"
        append("Turn \(outcome)")
        if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
            result = message
        }
        var verification = verifyTurnOutcome(outcome, frontmostBundleID: frontmostBundleID)
        verification = applyTurnResult(outcome, verification: verification)
        record(
            "turn_completed",
            details: [
                "turn_id": turnID ?? "unknown", "status": outcome,
                "frontmost_app": lastActivatedApp,
                "frontmost_bundle_id": frontmostBundleID ?? "unknown",
                "activated_bundle_ids": activatedBundleIDsThisTurn.sorted().joined(separator: ","),
                "space_change_count": String(spaceChangeCount),
                "verification": verification,
                "elapsed_ms": commandElapsedMilliseconds,
            ])
        if outcome == "completed", verification == "verified",
            !remainingRoutedDirections.isEmpty, let phrase = routedOriginalPhrase
        {
            let next = remainingRoutedDirections.removeFirst()
            record("router_step_finished", details: ["verification": verification])
            record("router_next_step", details: ["direction": next.rawValue])
            prepareNextSpaceStep(next, phrase: phrase)
            rotateServerAfterSpaceTool()
            beginActingTurn()
            return
        }
        record(
            "command_finished",
            details: [
                "status": outcome, "verification": verification,
                "elapsed_ms": commandElapsedMilliseconds,
            ])
        remainingRoutedDirections = []
        routedOriginalPhrase = nil
        focusTargetBundleID = nil
        let finishedSpaceTool = requestedToolDirection != nil
        requestedToolDirection = nil
        activatedBundleIDsThisTurn.removeAll()
        isWorking = false
        turnID = nil
        approval = nil
        queuedApprovals.removeAll()
        finishCommand()
        if finishedSpaceTool { rotateServerAfterSpaceTool() }
    }

    private func prepareNextSpaceStep(_ direction: SpaceDirection, phrase: String) {
        spaceToolApproval = nil
        requestedToolDirection = direction
        expectedToolDirection = direction
        toolCallObserved = false
        toolCallCompleted = false
        toolResult = nil
        activeToolDirection = nil
        activeMCPToolItemID = nil
        activeMCPToolTurnID = nil
        activeMCPToolDirection = nil
        spaceToolBridge?.revoke()
        queuedPhrase = phrase
        threadID = nil
        turnID = nil
    }

    func applyTurnResult(_ outcome: String, verification: String) -> String {
        var updatedVerification = verification
        if requestedToolDirection != nil {
            if outcome == "completed", toolCallObserved, toolCallCompleted,
                let toolResult, toolResult.verified,
                toolResult.commandID == activeCommandID,
                toolResult.direction == requestedToolDirection?.rawValue
            {
                result = toolResult.message
            } else {
                result =
                    outcome == "completed"
                    ? (toolResult?.message
                        ?? "The acting turn did not complete a verified switch_space tool call.")
                    : "The acting turn \(outcome); the Space move is unverified."
                status = "Space unverified"
            }
        } else if let generalTurnFailure {
            status = generalTurnFailure.rawValue
            updatedVerification = generalTurnFailure.rawValue
            switch generalTurnFailure {
            case .approvalUnavailable:
                result =
                    "The app could not present the Computer Use approval request. No access decision was made."
            case .accessDeclined:
                result = "Computer Use access was declined in the app. The requested action was not verified."
            case .toolFailed:
                result = "Computer Use failed after the request. The requested action was not verified."
            }
        } else if generalToolObserved && updatedVerification != "verified" {
            status = "Unverified"
            result = "The Computer Use action did not have independent macOS verification."
        }
        return updatedVerification
    }

    func verifyTurnOutcome(_ outcome: String, frontmostBundleID: String?) -> String {
        if requestedToolDirection != nil {
            return outcome == "completed" && toolCallObserved && toolCallCompleted
                && toolResult?.verified == true
                && toolResult?.commandID == activeCommandID
                && toolResult?.direction == requestedToolDirection?.rawValue
                ? "verified" : "unverified"
        }
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
