import AppKit
import Foundation

extension AppServerClient {
    func applyTurnResult(_ outcome: String, verification: String) -> String {
        var updatedVerification = verification
        if requestedDesktopState {
            if outcome == "completed", stateToolCallCompleted,
                let observed = stateToolResult, observed.verified,
                let current = observed.currentMainSpaceID,
                let ordered = observed.orderedMainSpaceIDs,
                let frontmost = observed.frontmostBundleID,
                let observedAt = observed.observedAt
            {
                result =
                    "Main Space \(current) in \(ordered); foreground \(frontmost); observed \(observedAt)."
            } else {
                result = stateToolResult?.message ?? "The desktop-state read was not verified."
                status = "Desktop state unavailable"
            }
        } else if requestedToolDirection != nil {
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
        if requestedDesktopState {
            return outcome == "completed" && stateToolCallCompleted
                && stateToolResult?.verified == true ? "verified" : "unverified"
        }
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
