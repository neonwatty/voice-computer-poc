import AppKit
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

    func fail(_ message: String) {
        spaceToolApproval = nil
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
        recordLiveSpaceObservation("after_completion")
        spaceToolApproval = nil
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

    static var packageURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DesktopToolServer")
    }

    private let command: URL
    private let arguments: [String]
    private let binaryURL: URL
    private let buildRoot: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var process: Process?
    private var completed = false
    private var callback: ((Outcome) -> Void)?

    init(
        command: URL = URL(fileURLWithPath: "/usr/bin/swift"),
        arguments: [String]? = nil,
        binaryURL: URL? = nil,
        buildRoot: String? = nil,
        timeout: TimeInterval = 90
    ) {
        let package = Self.packageURL
        self.command = command
        self.arguments =
            arguments ?? [
                "build", "--package-path", package.path, "--product", "DesktopToolServer",
            ]
        self.binaryURL = binaryURL ?? package.appendingPathComponent(".build/debug/DesktopToolServer")
        self.buildRoot =
            buildRoot ?? package.appendingPathComponent(".build")
            .resolvingSymlinksInPath().path + "/"
        self.timeout = timeout
    }

    func start(_ completion: @escaping (Outcome) -> Void) {
        lock.lock()
        callback = completion
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let task = Process()
            task.executableURL = command
            task.arguments = arguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            lock.lock()
            if completed {
                lock.unlock()
                return
            }
            process = task
            let launched: Bool
            do {
                try task.run()
                launched = true
            } catch {
                launched = false
            }
            lock.unlock()
            if launched {
                task.waitUntilExit()
                guard task.terminationStatus == 0 else {
                    finish(.failed("build_failed"))
                    return
                }
                let resolved = binaryURL.resolvingSymlinksInPath().path
                guard FileManager.default.isExecutableFile(atPath: resolved) else {
                    finish(.failed("binary_missing"))
                    return
                }
                guard resolved.hasPrefix(buildRoot),
                    URL(fileURLWithPath: resolved).lastPathComponent == "DesktopToolServer"
                else {
                    finish(.failed("path_mismatch"))
                    return
                }
                finish(.ready(resolved))
            } else {
                finish(.failed("build_failed"))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.cancel(reason: "build_timeout")
        }
    }

    func cancel(reason: String = "build_cancelled") {
        lock.lock()
        let task = process
        lock.unlock()
        if task?.isRunning == true { task?.terminate() }
        finish(.failed(reason))
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
