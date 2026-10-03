import AppKit
import Foundation

extension AppServerClient {
    func nativeSpaceActionActive(commandID: String?) -> Bool {
        guard let commandID else { return false }
        return isWorking && activeCommandID == commandID
            && cancelledNativeSpaceCommandID != commandID
    }

    static func controlsAbsent(_ error: Error) -> Bool {
        if case MissionControlAXError.dockUnavailable = error { return true }
        if case MissionControlAXError.scanUnavailable("missing_controls", 0, _) = error {
            return true
        }
        return false
    }

    @discardableResult
    func recordLiveSpaceObservation(_ phase: String) -> Int? {
        let liveID = SpaceNavigator.liveSpaceID()
        record(
            "live_space_observed",
            details: ["phase": phase, "live_space_id": liveID.map(String.init) ?? "unknown"])
        return liveID
    }

    func observeSystemSpaceNotification() {
        spaceChangeCount += 1
        let liveID = recordLiveSpaceObservation("system_notification")
        append("macOS reported an active Space change")
        record(
            "space_changed",
            details: [
                "count": String(spaceChangeCount),
                "live_space_id": liveID.map(String.init) ?? "unknown",
                "causality": "system_observation",
            ])
    }

    func completeVerifiedNativeSpaceStep(
        _ direction: SpaceDirection, before: SpaceSnapshot, after: SpaceSnapshot?, baseline: Int,
        remaining: [SpaceDirection], roundTripOrigin: Int?, commandID: String?, expected: Int
    ) {
        let fields = [
            "direction": direction.rawValue,
            "space_before_id": String(before.current),
            "space_target_id": String(expected),
            "space_after_id": String(after?.current ?? -1),
            "space_change_events": String(spaceChangeCount - baseline),
        ]
        record("native_space_step_verified", details: fields)
        if let next = SpaceToolSafety.nextStep(after: .verified, remaining: remaining) {
            nativeSpacePollTimer = Timer.scheduledTimer(
                withTimeInterval: 0.5, repeats: false
            ) { [weak self] _ in
                guard let self, self.nativeSpaceActionActive(commandID: commandID) else { return }
                self.nativeSpacePollTimer = nil
                self.runNativeSpaceStep(
                    next, remaining: Array(remaining.dropFirst()),
                    roundTripOrigin: roundTripOrigin ?? before.current)
            }
        } else {
            let returned = roundTripOrigin == after?.current
            completeNativeSpace(
                status: "completed", verification: "verified",
                message: returned
                    ? "Switched right one desktop Space and returned left to the original Space."
                    : "Switched one desktop Space to the \(direction.rawValue).",
                details: fields)
        }
    }

    func runMissionControlProbe() {
        status = "Inspecting Mission Control…"
        record("mission_control_probe_started")
        guard let commandID = activeCommandID else { return }
        let started = ProcessInfo.processInfo.systemUptime
        NSApp.activate()
        pollMissionControlProbeForeground(commandID: commandID, started: started)
    }

    private func pollMissionControlProbeForeground(commandID: String, started: TimeInterval) {
        guard isWorking, activeCommandID == commandID else { return }
        let active = NSApp.isActive
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if active && frontmost == "com.neonwatty.VoiceComputerPOC" {
            record("mission_control_probe_foreground_observed")
            launchMissionControlProbe(commandID: commandID)
            return
        }
        if ProcessInfo.processInfo.systemUptime - started >= 0.8 {
            record(
                "mission_control_probe_failed",
                details: ["reason": active ? "frontmost_mismatch" : "voice_inactive"])
            status = "Ready"
            result = "Could not verify Voice Computer in the foreground for inspection."
            record(
                "command_finished",
                details: ["status": "failed", "elapsed_ms": commandElapsedMilliseconds])
            queuedPhrase = nil
            isWorking = false
            finishCommand()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pollMissionControlProbeForeground(commandID: commandID, started: started)
        }
    }

    private func launchMissionControlProbe(commandID: String) {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) {
            [weak self] application, error in
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.8) {
                let probe = MissionControlAXProbe.inspectDock()
                DispatchQueue.main.async {
                    guard let self, self.isWorking, self.activeCommandID == commandID else { return }
                    if error != nil { self.record("mission_control_launch_failed") }
                    let summary = [
                        "trusted": String(probe.trusted), "dock_found": String(probe.dockFound),
                        "visited": String(probe.visited),
                        "limit_reached": String(probe.limitReached),
                        "mission_present": String(application != nil),
                        "mission_active": String(application?.isActive ?? false),
                        "frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                            ?? "unknown",
                        "controls": probe.nodes.map { "\($0.title):\($0.description):\($0.actions)" }
                            .joined(separator: "; "),
                    ]
                    self.record("mission_control_ax_summary", details: summary)
                    self.status = "Ready"
                    self.result = "Inspected Dock desktop controls. See Diagnostic Log."
                    self.record(
                        "command_finished",
                        details: ["status": "completed", "elapsed_ms": self.commandElapsedMilliseconds])
                    self.queuedPhrase = nil
                    self.isWorking = false
                    self.finishCommand()
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
    }
}
