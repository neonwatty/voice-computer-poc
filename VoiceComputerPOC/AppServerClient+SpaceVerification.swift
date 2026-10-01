import Foundation

extension AppServerClient {
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
