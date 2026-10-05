import AppKit
import CryptoKit
import Foundation

extension AppServerClient {
    static var safeSpaceProbe: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment["VOICE_COMPUTER_SAFE_MCP_PROBE"] == "1"
        #else
            return false
        #endif
    }

    static var liveBridgeProbe: Bool {
        #if DEBUG
            return ProcessInfo.processInfo.environment["VOICE_COMPUTER_LIVE_BRIDGE_PROBE"] == "1"
        #else
            return false
        #endif
    }
    func finishLiveBridgeProbe(
        _ request: SpaceToolRequest, reply: @escaping (SpaceToolResult) -> Void
    ) -> Bool {
        #if DEBUG
            guard Self.liveBridgeProbe, let activeCommandID else { return false }
            let response = SpaceToolResult.failure(
                "probe_no_action", commandID: activeCommandID,
                direction: request.direction, message: "Live bridge authenticated; no native action.")
            toolResult = response
            toolReply = nil
            record("mcp_bridge_accepted", details: ["direction": request.direction])
            record(
                "mcp_bridge_result",
                details: ["status": response.status, "verification": "unverified"])
            reply(response)
            return true
        #else
            return false
        #endif
    }
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
        spaceToolApproval = nil
        desktopStateApproval = nil
        desktopToolPreflight?.cancel()
        desktopToolPreflight = nil
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

    func rotateServerAfterCommand() {
        guard let process else { return }
        record("mcp_server_rotating", details: ["pid": String(process.processIdentifier)])
        if process.isRunning { process.terminate() }
        cleanupProcess()
    }

    func fail(_ message: String) {
        spaceToolApproval = nil
        desktopStateApproval = nil
        spaceToolBridge?.revoke()
        desktopToolPreflight?.cancel()
        desktopToolPreflight = nil
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
        requestedDesktopState = false
        activeStateToolItemID = nil
        activeStateToolTurnID = nil
        stateToolResult = nil
        stateToolCallCompleted = false
        queuedPhrase = nil
        spaceCountAtTurnStart = nil
        focusTargetBundleID = nil
        composedReportURL = nil
        composedBrowserVerified = false
        composedOriginSpace = nil
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
        recordLiveSpaceObservation("after_completion")
        spaceToolApproval = nil
        desktopStateApproval = nil
        spaceToolBridge?.revoke()
        desktopToolPreflight?.cancel()
        desktopToolPreflight = nil
        activeMCPToolItemID = nil
        activeMCPToolTurnID = nil
        activeMCPToolDirection = nil
        commandWatchdog?.invalidate()
        commandWatchdog = nil
        activeCommandID = nil
        commandStartedUptime = nil
        lastServerEventUptime = nil
        lastIdleWarningUptime = nil
    }
}

final class DesktopToolPreflight {
    enum Outcome {
        case ready(String)
        case failed(String)
    }

    static let helperRelativePath = "Contents/Helpers/DesktopToolServer"
    private let bundleURL: URL
    private let helperURL: URL
    private let timeout: TimeInterval
    private let validationDelay: TimeInterval
    private let lock = NSLock()
    private var completed = false
    private var callback: ((Outcome) -> Void)?

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        helperURL: URL? = nil,
        timeout: TimeInterval = 2,
        validationDelay: TimeInterval = 0
    ) {
        self.bundleURL = bundleURL
        self.helperURL = helperURL ?? bundleURL.appendingPathComponent(Self.helperRelativePath)
        self.timeout = timeout
        self.validationDelay = validationDelay
    }

    func start(_ completion: @escaping (Outcome) -> Void) {
        lock.lock()
        callback = completion
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if validationDelay > 0 { Thread.sleep(forTimeInterval: validationDelay) }
            finish(validate())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.cancel(reason: "validation_timeout")
        }
    }

    func cancel(reason: String = "validation_cancelled") {
        finish(.failed(reason))
    }

    private func validate() -> Outcome {
        let bundle = bundleURL.standardizedFileURL.path
        let resolvedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard bundle == resolvedBundle else { return .failed("bundle_path_mismatch") }
        let expected = bundleURL.appendingPathComponent(Self.helperRelativePath).standardizedFileURL.path
        guard helperURL.standardizedFileURL.path == expected,
            helperURL.resolvingSymlinksInPath().standardizedFileURL.path == expected
        else { return .failed("path_mismatch") }
        var info = stat()
        guard lstat(expected, &info) == 0 else { return .failed("binary_missing") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o111 != 0 else {
            return .failed("binary_not_executable")
        }
        let manifest = expected + ".sha256"
        guard lstat(manifest, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            let digest = try? String(contentsOfFile: manifest, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            digest.count == 64, digest.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
        else { return .failed("manifest_invalid") }
        guard let data = try? Data(contentsOf: helperURL) else { return .failed("binary_unreadable") }
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { return .failed("binary_mismatch") }
        return .ready(expected)
    }

    private func finish(_ outcome: Outcome) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let callback = self.callback
        self.callback = nil
        lock.unlock()
        DispatchQueue.main.async { callback?(outcome) }
    }
}
