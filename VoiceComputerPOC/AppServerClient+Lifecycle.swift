import AppKit
import Foundation

extension AppServerClient {
    func serverEnded(process ended: Process) {
        guard process === ended else { return }
        let exitCode = ended.terminationStatus
        let details =
            String(data: errorBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !errorLineBuffer.isEmpty && errorLinesLogged < 200 {
            record("server_stderr", details: ["line": String(decoding: errorLineBuffer, as: UTF8.self)])
        }
        record("server_exited", details: ["exit_code": String(exitCode), "stderr_tail": details])
        cleanupProcess()
        if isWorking {
            fail("Codex app-server exited (\(exitCode)). \(details.suffix(500))")
        } else {
            status = "Disconnected"
            append("Codex app-server stopped")
        }
    }

    func cleanupProcess() {
        spaceToolBridge?.stop()
        spaceToolBridge = nil
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        threadID = nil
        selectedModel = nil
        turnID = nil
        pending.removeAll()
        approval = nil
        queuedApprovals.removeAll()
        outputBuffer.removeAll()
        errorBuffer.removeAll()
        errorLineBuffer.removeAll()
        errorLinesLogged = 0
    }

    func fail(_ message: String) {
        nativeSpacePollTimer?.invalidate()
        nativeSpacePollTimer = nil
        toolCallTimeoutTimer?.invalidate()
        toolCallTimeoutTimer = nil
        if let toolReply {
            self.toolReply = nil
            toolReply(
                .failure(
                    "failed", commandID: activeCommandID ?? "unknown",
                    direction: activeToolDirection?.rawValue ?? "unknown", message: message))
        }
        record("app_error", details: ["message": message])
        if activeCommandID != nil {
            record(
                "command_failed",
                details: ["message": message, "elapsed_ms": commandElapsedMilliseconds])
        }
        status = "Error"
        result = message
        append(message)
        isWorking = false
        toolResult = nil
        activeMCPToolItemID = nil
        expectedToolDirection = nil
        activeToolDirection = nil
        requestedToolDirection = nil
        queuedPhrase = nil
        spaceCountAtTurnStart = nil
        focusTargetBundleID = nil
        activatedBundleIDsThisTurn.removeAll()
        if process != nil {
            record("server_reset_after_error")
            if process?.isRunning == true { process?.terminate() }
            cleanupProcess()
        }
        finishCommand()
    }

    func append(_ event: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        events.append("\(stamp)  \(event)")
        record("activity")
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    func revealLog() {
        guard let logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    func record(_ event: String, details: [String: String] = [:]) {
        guard let diagnosticLog else { return }
        do {
            var fields = details
            if let activeCommandID { fields["command_id"] = activeCommandID }
            diagnosticEntries.append(try diagnosticLog.record(event, details: fields))
        } catch {
            logError = "Could not write diagnostic log: \(error.localizedDescription)"
        }
    }

    var commandElapsedMilliseconds: String {
        guard let commandStartedUptime else { return "unknown" }
        return String(Int((ProcessInfo.processInfo.systemUptime - commandStartedUptime) * 1_000))
    }

    func checkCommandProgress() {
        guard isWorking, approval == nil, let lastServerEventUptime else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastServerEventUptime >= 90,
            lastIdleWarningUptime.map({ now - $0 >= 90 }) ?? true
        else { return }
        lastIdleWarningUptime = now
        append("Still waiting for Codex; no server event for over 90 seconds")
        record(
            "command_idle",
            details: [
                "idle_ms": String(Int((now - lastServerEventUptime) * 1_000)),
                "elapsed_ms": commandElapsedMilliseconds,
                "status": status,
            ])
    }

    func finishCommand() {
        activeMCPToolItemID = nil
        commandWatchdog?.invalidate()
        commandWatchdog = nil
        activeCommandID = nil
        commandStartedUptime = nil
        lastServerEventUptime = nil
        lastIdleWarningUptime = nil
    }
}
