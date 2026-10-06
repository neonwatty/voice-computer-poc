import Foundation

struct FixtureTurnResult {
    let kind: String
    let observation: FixtureAXObservation

    var verification: String { observation.verified ? "verified" : "unverified" }
}

extension AppServerClient {
    func handleCUAToolFailure() {
        guard generalTurnFailure == nil else { return }
        generalTurnFailure = .toolFailed
        guard isWorking,
            browserDocsURL != nil || browserFormURL != nil || finderReportURL != nil
                || textEditNoteURL != nil,
            let threadID, let turnID
        else { return }
        record("fixture_tool_failure_interrupt_requested", details: ["turn_id": turnID])
        _ = send(
            "turn/interrupt", params: ["threadId": threadID, "turnId": turnID],
            pendingKind: .interrupt)
    }

    func observedFixtureItem(_ item: [String: Any]) -> [String: Any] {
        #if DEBUG
            injectFixtureCUAFailureIfRequested(item)
        #else
            item
        #endif
    }

    #if DEBUG
        func injectFixtureCUAFailureIfRequested(_ item: [String: Any]) -> [String: Any] {
            guard isWorking, !fixtureCUAFailureInjected,
                item["server"] as? String == "cua_repl",
                item["status"] as? String == "completed",
                (item["error"] as? [String: Any])?["message"] as? String == nil,
                (item["result"] as? [String: Any])?["isError"] as? Bool != true,
                let itemID = item["id"] as? String,
                fixtureCUAToolStartedIDs.contains(itemID),
                let (runID, target) = fixtureFailureTarget()
            else { return item }
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let marker = support.appendingPathComponent(
                "VoiceComputerPOC/TestFixtures/\(runID)/inject_cua_failure", isDirectory: false)
            guard marker.resolvingSymlinksInPath() == marker,
                (try? String(contentsOf: marker, encoding: .utf8)) == "\(target):\(runID)\n"
            else { return item }
            fixtureCUAFailureInjected = true
            record(
                "test_cua_failure_injected",
                details: [
                    "target": target, "run_id": runID, "item_id": itemID,
                    "source": "synthetic_debug_event",
                ])
            var failed = item
            failed["status"] = "failed"
            failed["error"] = ["message": "Synthetic Debug CUA failure for fixture test"]
            return failed
        }

        private func fixtureFailureTarget() -> (String, String)? {
            if let browserDocsURL,
                let runID = URLComponents(url: browserDocsURL, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "run_id" })?.value,
                runID.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil
            {
                return (runID, "browser")
            }
            if let finderReportURL {
                let runID = finderReportURL.deletingLastPathComponent().lastPathComponent
                if runID.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil {
                    return (runID, "finder")
                }
            }
            if let textEditNoteURL {
                let runID = textEditNoteURL.deletingLastPathComponent().lastPathComponent
                if runID.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil {
                    return (runID, "textedit")
                }
            }
            return nil
        }
    #endif

    func observeFixtureToolStarted(_ item: [String: Any], eventTurnID: String?) {
        guard
            browserDocsURL != nil || browserFormURL != nil || finderReportURL != nil
                || textEditNoteURL != nil,
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
        guard
            browserDocsURL != nil || browserFormURL != nil || finderReportURL != nil
                || textEditNoteURL != nil
        else {
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
            : browserFormURL != nil
                ? "browser_form"
                : finderReportURL != nil ? "finder" : textEditNoteURL != nil ? "textedit" : nil
        guard let kind else { return nil }
        let observation: FixtureAXObservation
        if generalTurnFailure != nil {
            observation = .reject("tool_failure")
        } else if outcome != "completed" {
            observation = .reject("turn_incomplete")
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
        } else if let textEditNoteURL {
            observation = FixtureAXVerifier.verifyTextEdit(noteURL: textEditNoteURL)
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
            case "textedit": result = "Verified: TextEdit saved the exact test note."
            default: result = "Verified: Finder selected the exact test report."
            }
        } else {
            status = "Unverified"
            switch fixture.kind {
            case "browser": result = "Safari did not expose the expected Docs URL and heading."
            case "browser_form": result = "Safari did not expose the exact form result."
            case "textedit": result = "TextEdit did not expose the exact saved test note."
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
