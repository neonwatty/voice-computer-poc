import Foundation

extension AppServerClient {
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
                guard let self, self.isWorking, self.activeCommandID == commandID else { return }
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
}
