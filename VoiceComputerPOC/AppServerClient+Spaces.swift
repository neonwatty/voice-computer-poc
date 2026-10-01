import AppKit
import Foundation

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
        guard isWorking, activeCommandID == commandID, toolReply != nil else { return }
        record("mcp_native_callback_timeout")
        fail("The native Space callback timed out.")
    }

    func runNativeSpaceStep(
        _ direction: SpaceDirection, remaining: [SpaceDirection], roundTripOrigin: Int?
    ) {
        guard isWorking else { return }
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
        record(
            "native_space_requested",
            details: [
                "direction": direction.rawValue, "space_before_id": String(before.current),
                "space_target_id": String(expected),
            ])
        let baseline = spaceChangeCount
        let commandID = activeCommandID
        let targetNumber = (before.ordered.firstIndex(of: expected) ?? 0) + 1
        status = "Opening Mission Control…"
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let self, self.isWorking, self.activeCommandID == commandID else { return }
                self.pressNativeSpace(
                    direction, before: before, expected: expected, baseline: baseline,
                    targetNumber: targetNumber, remaining: remaining,
                    roundTripOrigin: roundTripOrigin, launchError: error)
            }
        }
    }

    func pressNativeSpace(
        _ direction: SpaceDirection, before: SpaceSnapshot, expected: Int, baseline: Int,
        targetNumber: Int, remaining: [SpaceDirection], roundTripOrigin: Int?, launchError: Error?
    ) {
        do {
            if let launchError { throw launchError }
            try MissionControlAXProbe.pressDesktop(
                number: targetNumber, expectedCount: before.ordered.count)
            record(
                "native_space_ax_pressed",
                details: ["direction": direction.rawValue, "desktop_number": String(targetNumber)])
            append("Pressed Desktop \(targetNumber) in Mission Control")
            startNativeSpaceVerification(
                direction, before: before, expected: expected, baseline: baseline,
                remaining: remaining, roundTripOrigin: roundTripOrigin)
        } catch {
            let visible = MissionControlAXProbe.inspectDock().nodes
                .filter { $0.title.hasPrefix("Desktop ") }
                .map { "\($0.path):\($0.title):\($0.description)" }
            record(
                "mission_control_ax_available", details: ["desktop_controls": visible.joined(separator: "; ")]
            )
            if case MissionControlAXError.permissionRequired = error {
                record("native_space_permission_missing")
            }
            completeNativeSpace(
                status: "failed", verification: "unverified",
                message: error.localizedDescription,
                details: [
                    "direction": direction.rawValue,
                    "space_before_id": String(before.current),
                    "space_target_id": String(expected),
                ])
        }
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
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.isWorking, self.activeCommandID == commandID else {
                timer.invalidate()
                self.nativeSpacePollTimer = nil
                return
            }
            let after = SpaceNavigator.snapshot()
            let eventObserved = self.spaceChangeCount > baseline
            let check = SpaceToolSafety.verification(
                expected: expected, after: after?.current, eventObserved: eventObserved,
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
            record(
                "mcp_bridge_result",
                details: [
                    "status": response.status,
                    "verification": response.verified ? "verified" : "unverified",
                ])
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let self, self.isWorking, self.activeCommandID == commandID else { return }
                if let error {
                    self.record(
                        "mission_control_launch_failed",
                        details: ["error": error.localizedDescription])
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let probe = MissionControlAXProbe.inspectDock()
                    DispatchQueue.main.async {
                        guard self.isWorking, self.activeCommandID == commandID else { return }
                        self.record(
                            "mission_control_ax_summary",
                            details: [
                                "trusted": String(probe.trusted),
                                "dock_found": String(probe.dockFound),
                                "node_count": String(probe.nodes.count),
                            ])
                        for node in probe.nodes {
                            self.record(
                                "mission_control_ax_node",
                                details: [
                                    "path": node.path, "role": node.role, "title": node.title,
                                    "description": node.description, "actions": node.actions,
                                ])
                        }
                        self.status = "Ready"
                        self.result =
                            "Inspected \(probe.nodes.count) Dock accessibility elements. See Diagnostic Log."
                        self.record(
                            "command_finished", details: ["elapsed_ms": self.commandElapsedMilliseconds])
                        self.queuedPhrase = nil
                        self.isWorking = false
                        self.finishCommand()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
    }

}
