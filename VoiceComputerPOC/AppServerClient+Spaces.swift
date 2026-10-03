import AppKit
extension AppServerClient {
    func handleSpaceToolRequest(
        _ request: SpaceToolRequest, peer: SpaceToolBridge.PeerIdentity,
        reply: @escaping (SpaceToolResult) -> Void
    ) {
        guard let bridge = spaceToolBridge, request.sessionID == bridge.sessionID,
            let expectedToolDirection,
            request.direction == expectedToolDirection.rawValue,
            isWorking, toolReply == nil, toolCallObserved,
            let activeCommandID, let itemID = activeMCPToolItemID,
            activeMCPToolTurnID == turnID, turnID != nil,
            activeMCPToolDirection == expectedToolDirection,
            hasAcceptedSpaceApproval(commandID: activeCommandID, itemID: itemID),
            bridge.bind(peer, commandID: activeCommandID, itemID: itemID),
            bridge.isBoundPeerAlive(commandID: activeCommandID, itemID: itemID)
        else {
            reply(
                .failure(
                    "rejected", commandID: activeCommandID ?? "unknown", direction: request.direction,
                    message: "No matching one-step command is active."))
            return
        }
        consumeSpaceApproval()
        toolReply = reply
        record("mcp_helper_bound", details: bridge.helperIdentityDetails)
        if finishLiveBridgeProbe(request, reply: reply) { return }
        activeToolDirection = expectedToolDirection
        self.expectedToolDirection = nil
        let commandID = activeCommandID
        toolCallTimeoutTimer?.invalidate()
        toolCallTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) {
            [weak self] _ in
            self?.handleSpaceToolTimeout(commandID: commandID)
        }
        record("mcp_bridge_accepted", details: ["direction": request.direction])
        runNativeSpaceStep(expectedToolDirection, remaining: [], roundTripOrigin: nil)
    }
    func handleSpaceToolTimeout(commandID: String?) {
        guard nativeSpaceActionActive(commandID: commandID), toolReply != nil else { return }
        record("mcp_native_callback_timeout")
        fail("The native Space callback timed out.")
    }
    func runNativeSpaceStep(
        _ direction: SpaceDirection, remaining: [SpaceDirection], roundTripOrigin: Int?
    ) {
        guard nativeSpaceActionActive(commandID: activeCommandID) else { return }
        let trusted = MissionControlAXProbe.isTrusted
        let before = trusted ? SpaceNavigator.snapshot() : nil
        let preflight = SpaceToolSafety.preflight(
            trusted: trusted, snapshot: before, direction: direction)
        if preflight == .permissionMissing {
            record("native_space_permission_missing")
            completeNativeSpace(
                status: "failed", verification: "unverified",
                message: MissionControlAXError.permissionRequired.localizedDescription,
                details: ["direction": direction.rawValue])
            return
        }
        guard let before else {
            completeNativeSpace(
                status: "failed", verification: "unverified",
                message: "Could not read the current desktop Space.",
                details: ["direction": direction.rawValue])
            return
        }
        guard case .ready(let expected) = preflight else {
            completeNativeSpace(
                status: "no_adjacent_space", verification: "no_action",
                message: "There is no desktop Space to the \(direction.rawValue).",
                details: [
                    "direction": direction.rawValue,
                    "space_before_id": String(before.current),
                ])
            return
        }
        let requestDetails = [
            "direction": direction.rawValue, "space_before_id": String(before.current),
            "space_target_id": String(expected),
        ]
        record("native_space_requested", details: requestDetails)
        let commandID = activeCommandID
        status = "Checking Mission Control controls…"
        let readiness = NativeSpaceReadiness(
            direction: direction, before: before, expected: expected, baseline: spaceChangeCount,
            targetNumber: (before.ordered.firstIndex(of: expected) ?? 0) + 1,
            remaining: remaining, roundTripOrigin: roundTripOrigin,
            commandID: commandID, deadline: ProcessInfo.processInfo.systemUptime + 4)
        discoverAndPressNativeSpace(
            readiness, launchError: nil, attempts: 0,
            openOnAbsent: { [weak self] in
                self?.requestVoiceForeground(readiness) { [weak self] in
                    self?.launchNativeSpaceDiscovery(readiness)
                }
            })
    }
    func handleMissionControlLaunchResult(
        _ readiness: NativeSpaceReadiness, applicationPresent: Bool, error: Error?,
        onReady: () -> Void
    ) {
        guard nativeSpaceActionActive(commandID: readiness.commandID) else { return }
        let elapsed = Int((ProcessInfo.processInfo.systemUptime - readiness.deadline + 4) * 1000)
        record(
            error == nil && applicationPresent
                ? "mission_control_launch_completed" : "mission_control_launch_failed",
            details: ["elapsed_ms": String(elapsed), "application_returned": String(applicationPresent)])
        if let error {
            handleNativeSpaceReadinessError(error, readiness: readiness, attempts: 0)
        } else if !applicationPresent {
            handleNativeSpaceReadinessError(
                MissionControlAXError.desktopNotFound("launch_no_application"),
                readiness: readiness, attempts: 0)
        } else {
            onReady()
        }
    }
    func handleNativeSpaceReadinessError(
        _ error: Error, readiness: NativeSpaceReadiness, attempts: Int,
        retry: (() -> Void)? = nil
    ) {
        guard nativeSpaceActionActive(commandID: readiness.commandID) else { return }
        let reason: String
        var desktopCount = 0
        var visited = 0
        switch error {
        case MissionControlAXError.permissionRequired: reason = "ax_trust_lost"
        case MissionControlAXError.dockUnavailable: reason = "dock_unavailable"
        case MissionControlAXError.desktopNotFound(let detail): reason = detail
        case MissionControlAXError.scanUnavailable(let detail, let count, let nodes):
            reason = detail
            (desktopCount, visited) = (count, nodes)
        case MissionControlAXError.pressFailed: reason = "ax_press_failed"
        default: reason = "launch_error"
        }
        record(
            "mission_control_ax_readiness",
            details: [
                "attempts": String(attempts), "reason": reason,
                "desktops": String(min(120, desktopCount)), "nodes": String(min(120, visited)),
                "dock_count": reason == "dock_unavailable" ? "0" : (visited > 0 ? "1" : "unknown"),
            ])
        if let retry,
            ["dock_unavailable", "missing_controls", "incomplete_controls", "mismatched_controls"]
                .contains(reason), ProcessInfo.processInfo.systemUptime < readiness.deadline
        {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard self?.nativeSpaceActionActive(commandID: readiness.commandID) == true else {
                    return
                }
                retry()
            }
            return
        }
        if case MissionControlAXError.permissionRequired = error {
            record("native_space_permission_missing")
        }
        let message =
            ["voice_inactive", "frontmost_mismatch"].contains(reason)
            ? "Voice Computer POC did not become the active app before opening Mission Control."
            : error.localizedDescription
        completeNativeSpace(
            status: "failed", verification: "unverified",
            message: message,
            details: [
                "direction": readiness.direction.rawValue,
                "space_before_id": String(readiness.before.current),
                "space_target_id": String(readiness.expected),
            ])
    }
    func startNativeSpaceVerification(
        _ direction: SpaceDirection, before: SpaceSnapshot, expected: Int, baseline: Int,
        remaining: [SpaceDirection], roundTripOrigin: Int?
    ) {
        status = "Switching Space…"
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let commandID = activeCommandID
        nativeSpacePollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] timer in
            guard let self, self.nativeSpaceActionActive(commandID: commandID) else {
                timer.invalidate()
                self?.nativeSpacePollTimer = nil
                return
            }
            let after = SpaceNavigator.snapshot()
            let check = SpaceToolSafety.verification(
                expected: expected, after: after?.current,
                eventObserved: self.spaceChangeCount > baseline,
                deadlineReached: ProcessInfo.processInfo.systemUptime >= deadline)
            if check == .verified {
                timer.invalidate()
                self.nativeSpacePollTimer = nil
                self.completeVerifiedNativeSpaceStep(
                    direction, before: before, after: after, baseline: baseline,
                    remaining: remaining, roundTripOrigin: roundTripOrigin,
                    commandID: commandID, expected: expected)
            } else if check == .timedOut {
                timer.invalidate()
                self.nativeSpacePollTimer = nil
                self.completeNativeSpace(
                    status: "unverified", verification: "unverified",
                    message:
                        "The Mission Control desktop was pressed, but macOS did not verify the requested Space change.",
                    details: [
                        "direction": direction.rawValue,
                        "space_before_id": String(before.current),
                        "space_target_id": String(expected),
                        "space_after_id": after.map { String($0.current) } ?? "unknown",
                        "space_change_events": String(self.spaceChangeCount - baseline),
                    ])
            }
        }
    }
    func completeNativeSpace(
        status outcome: String, verification: String, message: String, details: [String: String]
    ) {
        if outcome != "stopped", let activeCommandID,
            activeCommandID == cancelledNativeSpaceCommandID
        {
            record("late_native_result_ignored", details: ["status": outcome])
            return
        }
        guard isWorking else {
            record("late_native_result_ignored", details: ["status": outcome])
            return
        }
        status = outcome == "completed" ? "Ready" : "Space \(outcome)"
        result = message
        append(message)
        var fields = details
        fields["status"] = outcome
        fields["verification"] = verification
        fields["elapsed_ms"] = commandElapsedMilliseconds
        record("native_space_finished", details: fields)
        let finishingTool = toolReply != nil
        if let toolReply {
            toolCallTimeoutTimer?.invalidate()
            toolCallTimeoutTimer = nil
            let expectedID = details["space_target_id"].flatMap(Int.init)
            let afterID = details["space_after_id"].flatMap(Int.init)
            let notificationObserved =
                (details["space_change_events"].flatMap(Int.init) ?? 0) > 0
            let response = SpaceToolResult(
                commandID: activeCommandID ?? "unknown",
                status: verification == "verified" && expectedID != nil
                    && afterID == expectedID && notificationObserved ? "verified" : outcome,
                direction: details["direction"] ?? activeToolDirection?.rawValue ?? "unknown",
                beforeID: details["space_before_id"].flatMap(Int.init),
                expectedID: expectedID,
                afterID: afterID,
                notificationObserved: notificationObserved,
                message: message)
            self.toolResult = response
            self.toolReply = nil
            let bridgeDetails = [
                "status": response.status,
                "verification": response.verified ? "verified" : "unverified",
            ]
            record("mcp_bridge_result", details: bridgeDetails)
            toolReply(response)
        }
        if finishingTool {
            activeToolDirection = nil
            status = "Codex is working…"
            return
        }
        record("command_finished", details: fields)
        queuedPhrase = nil
        spaceCountAtTurnStart = nil
        isWorking = false
        finishCommand()
    }
    func runMissionControlProbe() {
        status = "Inspecting Mission Control…"
        record("mission_control_probe_started")
        let commandID = activeCommandID
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                let probe = MissionControlAXProbe.inspectDock()
                DispatchQueue.main.async {
                    guard let self, self.isWorking, self.activeCommandID == commandID else { return }
                    if error != nil { self.record("mission_control_launch_failed") }
                    let summary = [
                        "trusted": String(probe.trusted), "dock_found": String(probe.dockFound),
                        "controls": probe.nodes.map { "\($0.title):\($0.description):\($0.actions)" }
                            .joined(separator: "; "),
                    ]
                    self.record("mission_control_ax_summary", details: summary)
                    self.status = "Ready"
                    self.result = "Inspected Dock desktop controls. See Diagnostic Log."
                    self.record("command_finished", details: ["elapsed_ms": self.commandElapsedMilliseconds])
                    self.queuedPhrase = nil
                    self.isWorking = false
                    self.finishCommand()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}
