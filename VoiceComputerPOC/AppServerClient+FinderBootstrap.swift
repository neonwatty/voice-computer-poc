import Foundation

extension AppServerClient {
    func prepareFinderAndBeginActingTurn() {
        guard let reportURL = finderReportURL, let commandID = activeCommandID else { return }
        #if DEBUG
            let outcome =
                finderBootstrapOverride?(reportURL)
                ?? FinderWindowBootstrap.prepare(reportURL: reportURL)
        #else
            let outcome = FinderWindowBootstrap.prepare(reportURL: reportURL)
        #endif
        switch outcome {
        case .existingWindow:
            record("finder_window_bootstrap", details: ["result": "existing_window"])
            beginActingTurn()
        case .openedWindow:
            record("finder_window_bootstrap", details: ["result": "opened_window"])
            awaitFinderWindow(commandID: commandID, reportURL: reportURL, attempts: 20)
        case .unavailable:
            record("finder_window_bootstrap", details: ["result": "unavailable"])
            fail("Finder window access or fixture bootstrap was unavailable.")
        }
    }

    private func awaitFinderWindow(commandID: String, reportURL: URL, attempts: Int) {
        guard isWorking, activeCommandID == commandID, finderReportURL == reportURL else { return }
        #if DEBUG
            if finderBootstrapOverride != nil {
                beginActingTurn()
                return
            }
        #endif
        if let count = FinderWindowBootstrap.windowCount(), count > 0 {
            record("finder_window_bootstrap_ready")
            beginActingTurn()
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.awaitFinderWindow(
                    commandID: commandID, reportURL: reportURL, attempts: attempts - 1)
            }
        } else {
            record("finder_window_bootstrap", details: ["result": "window_not_observed"])
            fail("Finder did not expose the fixture window after opening it.")
        }
    }
}
