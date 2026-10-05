import Foundation

struct FixtureTurnResult {
    let kind: String
    let observation: FixtureAXObservation

    var verification: String { observation.verified ? "verified" : "unverified" }
}

extension AppServerClient {
    func observeFixtureToolStarted(_ item: [String: Any], eventTurnID: String?) {
        guard browserDocsURL != nil || browserFormURL != nil || finderReportURL != nil,
            item["server"] as? String == "cua_repl",
            let turnID, eventTurnID == turnID,
            let itemID = item["id"] as? String, !itemID.isEmpty
        else { return }
        fixtureCUAToolStartedIDs.insert(itemID)
    }

    func observeFixtureToolCompleted(_ item: [String: Any]) {
        let status = item["status"] as? String ?? "unknown"
        let directError = (item["error"] as? [String: Any])?["message"] as? String
        let result = item["result"] as? [String: Any]
        observeFixtureToolCompleted(
            item, status: status, failed: directError != nil || result?["isError"] as? Bool == true)
    }

    func observeFixtureToolCompleted(_ item: [String: Any], status: String, failed: Bool) {
        guard item["server"] as? String == "cua_repl",
            let itemID = item["id"] as? String,
            fixtureCUAToolStartedIDs.contains(itemID), status == "completed", !failed
        else { return }
        fixtureCUAToolCompletedIDs.insert(itemID)
    }

    func rejectMismatchedFixtureTurn(_ turn: [String: Any]) -> Bool {
        guard browserDocsURL != nil || browserFormURL != nil || finderReportURL != nil else {
            return false
        }
        guard let turnID, turn["id"] as? String == turnID else {
            record("fixture_turn_mismatch")
            fail("The acting turn did not match this fixture command.")
            return true
        }
        return false
    }

    func fixtureTurnResult(outcome: String) -> FixtureTurnResult? {
        let kind =
            browserDocsURL != nil
            ? "browser"
            : browserFormURL != nil ? "browser_form" : finderReportURL != nil ? "finder" : nil
        guard let kind else { return nil }
        let observation: FixtureAXObservation
        if outcome != "completed" {
            observation = .reject("turn_incomplete")
        } else if generalTurnFailure != nil {
            observation = .reject("tool_failure")
        } else if fixtureCUAToolStartedIDs.isEmpty
            || fixtureCUAToolStartedIDs != fixtureCUAToolCompletedIDs
        {
            observation = .reject("tool_not_completed")
        } else if let browserDocsURL {
            observation = FixtureAXVerifier.verifyBrowser(homeURL: browserDocsURL)
        } else if let browserFormURL, let browserFormQuery {
            observation = FixtureAXVerifier.verifyBrowserForm(
                docsURL: browserFormURL, query: browserFormQuery)
        } else if let finderReportURL {
            observation = FixtureAXVerifier.verifyFinder(reportURL: finderReportURL)
        } else {
            observation = .reject("missing_target")
        }
        return FixtureTurnResult(kind: kind, observation: observation)
    }

    func recordFixtureTurnResult(_ fixture: FixtureTurnResult) {
        record(
            "fixture_ax_verification",
            details: [
                "target": fixture.kind,
                "verified": String(fixture.observation.verified),
                "reason": fixture.observation.reason,
                "visited": String(fixture.observation.visited),
            ])
    }

    func displayFixtureTurnResult(_ fixture: FixtureTurnResult, outcome: String) {
        guard outcome == "completed", generalTurnFailure == nil else { return }
        if fixture.observation.verified {
            switch fixture.kind {
            case "browser": result = "Verified: Safari displays the exact Docs URL and heading."
            case "browser_form": result = "Verified: Safari displays the exact form result."
            default: result = "Verified: Finder selected the exact test report."
            }
        } else {
            status = "Unverified"
            switch fixture.kind {
            case "browser": result = "Safari did not expose the expected Docs URL and heading."
            case "browser_form": result = "Safari did not expose the exact form result."
            default: result = "Finder did not expose the exact selected test report."
            }
        }
        append(result)
    }

    func verifyComposedTurn(_ verification: String) -> String {
        guard composedReportURL != nil else { return verification }
        guard let origin = composedOriginSpace, SpaceNavigator.snapshot() == origin else {
            status = "Unverified"
            result = "The desktop Space changed or could not be verified during the composed request."
            return "unverified"
        }
        if finderReportURL != nil && !composedBrowserVerified {
            status = "Unverified"
            result = "The Finder step has no verified Safari prerequisite."
            return "unverified"
        }
        return verification
    }

    func advanceComposedFixtureIfReady(outcome: String, verification: String) -> Bool {
        guard let report = composedReportURL else { return false }
        if browserDocsURL != nil {
            guard outcome == "completed", verification == "verified", isWorking,
                cancelledNativeSpaceCommandID != activeCommandID
            else {
                record("browser_step_failed", details: ["verification": verification])
                return false
            }
            composedBrowserVerified = true
            record("browser_step_verified", details: ["turn_id": turnID ?? "unknown"])
            browserDocsURL = nil
            finderReportURL = report
            fixtureCUAToolStartedIDs.removeAll()
            fixtureCUAToolCompletedIDs.removeAll()
            generalToolObserved = false
            generalTurnFailure = nil
            activatedBundleIDsThisTurn.removeAll()
            turnID = nil
            queuedPhrase = "Reveal the test report at \(report.path) in Finder."
            record("finder_step_queued")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isWorking,
                    self.cancelledNativeSpaceCommandID != self.activeCommandID,
                    self.finderReportURL == report
                else { return }
                self.beginActingTurn()
            }
            return true
        }
        if finderReportURL != nil, outcome == "completed", verification == "verified" {
            record("finder_step_verified", details: ["turn_id": turnID ?? "unknown"])
            result = "Verified: Safari displayed Docs, then Finder selected the exact test report."
            append(result)
        } else {
            record("finder_step_failed", details: ["verification": verification])
        }
        return false
    }
}
