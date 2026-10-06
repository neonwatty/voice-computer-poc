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
        if retryUnavailableRouterOutput(data, phrase: phrase) { return }
        switch RouteHandoff.decide(data, phrase: phrase) {
        case .invalid:
            completeRouteWithoutAction("Router output was unavailable or unsafe.")
        case .clarification:
            completeClarificationRoute()
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
        case .browserDocs(let url):
            record(
                "router_decided",
                details: ["route": "browser", "action": "follow_docs", "target": "loopback_fixture"])
            browserDocsURL = url
            queuedPhrase = "Open \(url.absoluteString) and follow the Docs link."
            beginActingTurn()
        case .browserForm(let url, let query):
            record(
                "router_decided",
                details: ["route": "browser", "action": "submit_form", "target": "loopback_fixture"])
            browserFormURL = url
            browserFormQuery = query
            queuedPhrase = "Open \(url.absoluteString) and submit query \(query)."
            beginActingTurn()
        case .finderReveal(let url):
            record(
                "router_decided",
                details: ["route": "finder", "action": "reveal_file", "target": "fixture_report"])
            finderReportURL = url
            queuedPhrase = "Reveal the test report at \(url.path) in Finder."
            beginActingTurn()
        case .textEditSave(let url):
            record(
                "router_decided",
                details: ["route": "textedit", "action": "save_note", "target": "fixture_note"])
            textEditNoteURL = url
            queuedPhrase = phrase
            beginActingTurn()
        case .browserThenFinder(let home, let report):
            guard let snapshot = SpaceNavigator.snapshot() else {
                fail("Could not read the starting desktop Space for the composed request.")
                return
            }
            record(
                "router_decided",
                details: ["route": "browser_finder", "target": "matched_loopback_fixtures"])
            composedReportURL = report
            composedOriginSpace = snapshot
            browserDocsURL = home
            queuedPhrase = "Open \(home.absoluteString) and follow the Docs link."
            beginActingTurn()
        }
    }

    private func retryUnavailableRouterOutput(_ data: Data?, phrase: String) -> Bool {
        guard data == nil, !routerOutputRetried else { return false }
        routerOutputRetried = true
        record("router_output_retry", details: ["reason": "unavailable", "attempt": "2"])
        routePhrase(phrase)
        return true
    }

    private func completeClarificationRoute() {
        record("router_decided", details: ["route": "clarification"])
        completeRouteWithoutAction("Please clarify the requested desktop action.")
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
        if expectedToolDirection != nil || requestedDesktopState, process != nil {
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
