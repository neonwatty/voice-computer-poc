import AppKit
import Foundation

extension AppServerClient {
    func routePhrase(_ phrase: String) {
        let commandID = activeCommandID
        status = "Routing command…"
        record("router_requested", details: ["mode": "isolated_codex_exec"])
        #if DEBUG
            if let routingOverride {
                routingOverride(phrase)
                return
            }
        #endif
        RouterAgent.classify(phrase) { [weak self] data in
            guard let self, self.isWorking, self.activeCommandID == commandID else { return }
            self.processRouterOutput(data, phrase: phrase)
        }
    }

    func processRouterOutput(_ data: Data?, phrase: String) {
        guard isWorking else { return }
        switch RouteHandoff.decide(data, phrase: phrase) {
        case .invalid:
            completeRouteWithoutAction("Router output was unavailable or unsafe.")
        case .clarification:
            record("router_decided", details: ["route": "clarification"])
            completeRouteWithoutAction("Please clarify the requested desktop action.")
        case .space(let direction, let remaining):
            record(
                "router_decided",
                details: [
                    "route": "space",
                    "directions": ([direction] + remaining).map(\.rawValue).joined(separator: ","),
                ])
            requestedToolDirection = direction
            expectedToolDirection = direction
            remainingRoutedDirections = remaining
            routedOriginalPhrase = phrase
            beginActingTurn()
        case .calculator:
            record("router_decided", details: ["route": "computer_use"])
            focusTargetBundleID = "com.apple.calculator"
            queuedPhrase = "Open Calculator"
            beginActingTurn()
        }
    }

    func completeRouteWithoutAction(_ message: String) {
        status = "Needs clarification"
        result = message
        append(message)
        record(
            "command_finished",
            details: [
                "status": "clarification", "verification": "no_action",
                "elapsed_ms": commandElapsedMilliseconds,
            ])
        isWorking = false
        queuedPhrase = nil
        finishCommand()
    }

    func beginActingTurn() {
        #if DEBUG
            if let actingTurnOverride {
                actingTurnOverride()
                return
            }
        #endif
        if expectedToolDirection != nil, process != nil {
            threadID = nil
            _ = send(
                "mcpServerStatus/list", params: ["detail": "toolsAndAuthOnly"],
                pendingKind: .mcpStatus)
        } else if let threadID {
            startTurn(threadID: threadID)
        } else if process == nil {
            startServer()
        } else {
            status = "Connecting to Codex…"
        }
    }

}
