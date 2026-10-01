import AppKit
import Foundation

extension AppServerClient {
    func runNativeSpaceStep(
        _ direction: SpaceDirection, remaining: [SpaceDirection], roundTripOrigin: Int?
    ) {
        guard MissionControlAXProbe.isTrusted else {
            record("native_space_permission_missing")
            completeNativeSpace(
                status: "failed", verification: "unverified",
                message: MissionControlAXError.permissionRequired.localizedDescription,
                details: ["direction": direction.rawValue])
            return
        }
        guard let before = SpaceNavigator.snapshot() else {
            completeNativeSpace(
                status: "failed", verification: "unverified",
                message: "Could not read the current desktop Space.", details: [:])
            return
        }
        guard let expected = before.adjacent(direction) else {
            completeNativeSpace(
                status: "no_adjacent_space", verification: "no_action",
                message: "There is no desktop Space to the \(direction.rawValue).",
                details: ["space_before_id": String(before.current)])
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
        nativeSpacePollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let after = SpaceNavigator.snapshot()
            let eventObserved = self.spaceChangeCount > baseline
            if after?.current == expected && eventObserved {
                timer.invalidate()
                self.nativeSpacePollTimer = nil
                let fields = [
                    "direction": direction.rawValue,
                    "space_before_id": String(before.current),
                    "space_target_id": String(expected),
                    "space_after_id": String(after?.current ?? -1),
                    "space_change_events": String(self.spaceChangeCount - baseline),
                ]
                self.record("native_space_step_verified", details: fields)
                if let next = remaining.first {
                    self.nativeSpacePollTimer = Timer.scheduledTimer(
                        withTimeInterval: 0.5, repeats: false
                    ) { [weak self] _ in
                        self?.nativeSpacePollTimer = nil
                        self?.runNativeSpaceStep(
                            next, remaining: Array(remaining.dropFirst()),
                            roundTripOrigin: roundTripOrigin ?? before.current)
                    }
                } else {
                    let returned = roundTripOrigin == after?.current
                    self.completeNativeSpace(
                        status: "completed", verification: "verified",
                        message: returned
                            ? "Switched right one desktop Space and returned left to the original Space."
                            : "Switched one desktop Space to the \(direction.rawValue).",
                        details: fields)
                }
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
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
        status = outcome == "completed" ? "Ready" : "Space \(outcome)"
        result = message
        append(message)
        var fields = details
        fields["status"] = outcome
        fields["verification"] = verification
        fields["elapsed_ms"] = commandElapsedMilliseconds
        record("native_space_finished", details: fields)
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
