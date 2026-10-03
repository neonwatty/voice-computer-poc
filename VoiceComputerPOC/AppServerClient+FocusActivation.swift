import AppKit

extension AppServerClient {
    /// Complete an explicit Open Calculator request only after macOS reports focus.
    func requestCalculatorFocusAfterTool(
        _ turn: [String: Any],
        frontmostBundleID: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    ) -> Bool {
        let target = "com.apple.calculator"
        guard turn["status"] as? String == "completed",
            focusTargetBundleID == target,
            frontmostBundleID != target,
            generalTurnFailure == nil,
            let commandID = activeCommandID,
            let turnID, turn["id"] as? String == turnID,
            diagnosticEntries.contains(where: {
                $0.event == "tool_completed" && $0.details["command_id"] == commandID
                    && $0.details["server"] == "cua_repl"
                    && $0.details["status"] == "completed"
                    && $0.details["result_is_error"] == "false"
            })
        else { return false }

        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: target)
            .filter { !$0.isTerminated }
        guard applications.count == 1, let bundleURL = applications[0].bundleURL else { return false }
        record("focus_activation_requested", details: ["target": target, "method": "launch_services"])
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) {
            [weak self] application, error in
            DispatchQueue.main.async {
                guard let self, self.isWorking, self.activeCommandID == commandID,
                    self.turnID == turnID
                else { return }
                self.record(
                    "focus_activation_result",
                    details: ["target": target, "accepted": String(application != nil && error == nil)])
                self.observeCalculatorFocus(
                    turn, commandID: commandID, turnID: turnID, remaining: 10)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, self.isWorking, self.activeCommandID == commandID,
                self.turnID == turnID
            else { return }
            self.record("focus_activation_timeout", details: ["target": target])
            self.finishTurnCompleted(turn)
        }
        return true
    }

    private func observeCalculatorFocus(
        _ turn: [String: Any], commandID: String, turnID: String, remaining: Int
    ) {
        guard isWorking, activeCommandID == commandID, self.turnID == turnID else { return }
        let focused =
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            == "com.apple.calculator"
        if focused || remaining == 0 {
            record(
                "focus_activation_observed",
                details: ["target": "com.apple.calculator", "frontmost_matches": String(focused)])
            finishTurnCompleted(turn)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.observeCalculatorFocus(
                turn, commandID: commandID, turnID: turnID, remaining: remaining - 1)
        }
    }
}
