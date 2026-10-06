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
            let message = error["message"] as? String ?? "Codex reported an error"
            if message.hasPrefix("Reconnecting...") {
                status = "Codex is reconnecting…"
                record("server_reconnecting")
            } else {
                fail(message)
            }
        default:
            break
        }
    }

    func handleItemStarted(_ item: [String: Any], eventTurnID: String? = nil) {
        guard item["type"] as? String == "mcpToolCall" else { return }
        let server = item["server"] as? String ?? "tool"
        let tool = item["tool"] as? String ?? "call"
        let direction = SpaceToolRequest.direction(fromArguments: item["arguments"])
        observeFixtureToolStarted(item, eventTurnID: eventTurnID)
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
        } else if server == "desktop_tool" && tool == "get_desktop_state",
            requestedDesktopState, isWorking, activeCommandID != nil,
            let turnID, eventTurnID == turnID,
            let itemID = item["id"] as? String, !itemID.isEmpty,
            activeStateToolItemID == nil
        {
            activeStateToolItemID = itemID
            activeStateToolTurnID = turnID
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
        if isWorking, item["type"] as? String == "agentMessage",
            let text = item["text"] as? String, !text.isEmpty
        {
            result = text
        } else if item["type"] as? String == "mcpToolCall" {
            let observedItem = observedFixtureItem(item)
            observeFixtureToolCompleted(observedItem)
            handleToolCompleted(observedItem)
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
        let isStateTool =
            item["server"] as? String == "desktop_tool"
            && item["tool"] as? String == "get_desktop_state"
        let isActiveStateTool = isStateTool && item["id"] as? String == activeStateToolItemID
        let stateTyped = (content?.first?["text"] as? String)?.data(using: .utf8)
            .flatMap { try? JSONDecoder().decode(DesktopStateToolResult.self, from: $0) }
        correlateCompletedTool(
            item, status: status, resultIsError: resultIsError,
            spaceResult: typed, stateResult: stateTyped)
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
            append(detail.map { "\(label): \(String($0.prefix(500)))" } ?? label)
        }
        if isSpaceTool, let typed {
            fields["typed_status"] = typed.status
            fields["typed_command_id"] = typed.commandID
            fields["typed_direction"] = typed.direction
            fields["typed_verified"] = String(typed.verified)
        }
        if isStateTool, let stateTyped {
            fields["typed_status"] = stateTyped.status
            fields["typed_verified"] = String(stateTyped.verified)
        }
        record("tool_completed", details: fields)
        if isSpaceTool, item["id"] as? String == activeMCPToolItemID {
            spaceToolApproval = nil
            activeMCPToolItemID = nil
            activeMCPToolTurnID = nil
            activeMCPToolDirection = nil
            spaceToolBridge?.revoke()
        }
        if isActiveStateTool {
            desktopStateApproval = nil
            spaceToolBridge?.revoke()
        }
    }

    private func correlateCompletedTool(
        _ item: [String: Any], status: String, resultIsError: Bool,
        spaceResult typed: SpaceToolResult?, stateResult stateTyped: DesktopStateToolResult?
    ) {
        let isActiveSpaceTool =
            item["server"] as? String == "desktop_tool"
            && item["tool"] as? String == "switch_space"
            && item["id"] as? String == activeMCPToolItemID
        let isActiveStateTool =
            item["server"] as? String == "desktop_tool"
            && item["tool"] as? String == "get_desktop_state"
            && item["id"] as? String == activeStateToolItemID
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
        if isActiveStateTool, status == "completed", !resultIsError,
            let stateTyped, stateTyped == stateToolResult, stateTyped.verified
        {
            stateToolCallCompleted = true
            record("mcp_state_result_correlated", details: ["item_id": activeStateToolItemID ?? "unknown"])
        }
    }

    func handleTurnCompleted(_ turn: [String: Any]) {
        guard isWorking else {
            record(
                "unexpected_turn_completed",
                details: ["turn_id": turn["id"] as? String ?? "unknown"])
            return
        }
        if rejectMismatchedFixtureTurn(turn) { return }
        if requestCalculatorFocusAfterTool(turn) { return }
        let outcome = turn["status"] as? String ?? "completed"
        if shouldRetryDesktopStateDiscovery(outcome: outcome) {
            desktopStateReadRetried = true
            record(
                "mcp_state_discovery_retry",
                details: ["reason": "no_tool_call", "previous_turn_id": turnID ?? "unknown"])
            queuedPhrase = "agent get desktop state"
            result = ""
            rotateServerAfterCommand()
            beginActingTurn()
            return
        }
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
        let fixture = fixtureTurnResult(outcome: outcome)
        if let fixture {
            verification = fixture.verification
            recordFixtureTurnResult(fixture)
        }
        verification = applyTurnResult(outcome, verification: verification)
        if let fixture { displayFixtureTurnResult(fixture, outcome: outcome) }
        verification = verifyComposedTurn(verification)
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
        if advanceComposedFixtureIfReady(outcome: outcome, verification: verification) { return }
        if outcome == "completed", verification == "verified",
            !remainingRoutedDirections.isEmpty, let phrase = routedOriginalPhrase
        {
            let next = remainingRoutedDirections.removeFirst()
            record("router_step_finished", details: ["verification": verification])
            record("router_next_step", details: ["direction": next.rawValue])
            prepareNextSpaceStep(next, phrase: phrase)
            rotateServerAfterCommand()
            beginActingTurn()
            return
        }
        record(
            "command_finished",
            details: [
                "status": outcome, "verification": verification,
                "elapsed_ms": commandElapsedMilliseconds,
            ])
        resetAfterCompletedCommand()
    }

    private func resetAfterCompletedCommand() {
        remainingRoutedDirections = []
        routedOriginalPhrase = nil
        focusTargetBundleID = nil
        browserDocsURL = nil
        browserFormURL = nil
        browserFormQuery = nil
        finderReportURL = nil
        textEditNoteURL = nil
        composedReportURL = nil
        composedBrowserVerified = false
        composedOriginSpace = nil
        let finishedStateTool = requestedDesktopState
        requestedDesktopState = false
        desktopStateReadRetried = false
        routerOutputRetried = false
        activeStateToolItemID = nil
        activeStateToolTurnID = nil
        stateToolResult = nil
        stateToolCallCompleted = false
        desktopStateApproval = nil
        let finishedSpaceTool = requestedToolDirection != nil
        let finishedComputerUse = generalToolObserved
        requestedToolDirection = nil
        activatedBundleIDsThisTurn.removeAll()
        isWorking = false
        turnID = nil
        approval = nil
        queuedApprovals.removeAll()
        finishCommand()
        if finishedSpaceTool || finishedStateTool || finishedComputerUse {
            rotateServerAfterCommand()
        }
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
}
