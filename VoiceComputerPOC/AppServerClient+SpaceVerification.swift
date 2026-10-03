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
