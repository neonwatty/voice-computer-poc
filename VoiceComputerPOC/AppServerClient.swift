import AppKit
import Combine
import Foundation

final class AppServerClient: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var isWorking = false
    @Published private(set) var result = ""
    @Published private(set) var events: [String] = []
    @Published private(set) var diagnosticEntries: [DiagnosticLog.Entry] = []
    @Published private(set) var spaceChangeCount = 0
    @Published private(set) var lastActivatedApp = "Unknown"
    @Published private(set) var logError = ""
    @Published var approval: ApprovalRequest?

    private enum Pending {
        case initialize, models, thread, turn, interrupt

        var name: String { String(describing: self) }
    }

    private var process: Process?
    private var serverDirectory: URL?
    private var input: Pipe?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var errorLineBuffer = Data()
    private var errorLinesLogged = 0
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var threadID: String?
    private var turnID: String?
    private var queuedPhrase: String?
    private var queuedApprovals: [ApprovalRequest] = []
    private var spaceObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var spaceCountAtTurnStart: Int?
    private var focusTargetBundleID: String?
    private var activatedBundleIDsThisTurn: Set<String> = []
    private var activeCommandID: String?
    private var commandStartedUptime: TimeInterval?
    private var lastServerEventUptime: TimeInterval?
    private var lastIdleWarningUptime: TimeInterval?
    private var commandWatchdog: Timer?
    private var nativeSpacePollTimer: Timer?
    private let diagnosticLog: DiagnosticLog?

    var logURL: URL? { diagnosticLog?.fileURL }

    var canStop: Bool { isWorking }

    init() {
        let logDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("VoiceComputerPOC/Logs", isDirectory: true)
        do {
            diagnosticLog = try DiagnosticLog(directory: logDirectory)
        } catch {
            diagnosticLog = nil
            logError = "Could not create diagnostic log: \(error.localizedDescription)"
        }
        record("app_started")
        let center = NSWorkspace.shared.notificationCenter
        lastActivatedApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.spaceChangeCount += 1
            self?.append("macOS reported an active Space change")
            self?.record("space_changed", details: ["count": String(self?.spaceChangeCount ?? 0)])
        }
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let frontmost = NSWorkspace.shared.frontmostApplication
            self?.lastActivatedApp = frontmost?.localizedName ?? "Unknown"
            if let bundleID = frontmost?.bundleIdentifier {
                self?.activatedBundleIDsThisTurn.insert(bundleID)
                if self?.isWorking == true {
                    self?.record("app_activated", details: ["bundle_id": bundleID])
                }
            }
        }
    }

    deinit {
        commandWatchdog?.invalidate()
        nativeSpacePollTimer?.invalidate()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    func run(_ phrase: String) {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !isWorking else { return }
        result = ""
        isWorking = true
        activeCommandID = UUID().uuidString
        commandStartedUptime = ProcessInfo.processInfo.systemUptime
        lastServerEventUptime = commandStartedUptime
        lastIdleWarningUptime = nil
        commandWatchdog?.invalidate()
        commandWatchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkCommandProgress()
        }
        queuedPhrase = phrase
        spaceCountAtTurnStart =
            phrase.localizedCaseInsensitiveContains("desktop Space")
            ? spaceChangeCount : nil
        activatedBundleIDsThisTurn.removeAll()
        if phrase.localizedCaseInsensitiveContains("foreground")
            || phrase.localizedCaseInsensitiveContains("active app")
        {
            if phrase.localizedCaseInsensitiveContains("chrome") {
                focusTargetBundleID = "com.google.Chrome"
            } else if phrase.localizedCaseInsensitiveContains("calculator") {
                focusTargetBundleID = "com.apple.calculator"
            } else {
                focusTargetBundleID = nil
            }
        } else {
            focusTargetBundleID = nil
        }
        append("Requested: \(phrase)")
        record(
            "command_started",
            details: [
                "phrase": phrase,
                "frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                "frontmost_app": lastActivatedApp,
                "space_change_count": String(spaceChangeCount),
            ])
        if let spaceCommand = SpaceCommand(phrase: phrase) {
            runNativeSpaceStep(
                spaceCommand.directions[0], remaining: Array(spaceCommand.directions.dropFirst()),
                roundTripOrigin: nil)
            return
        }
        if phrase.lowercased() == "inspect mission control desktop controls" {
            runMissionControlProbe()
            return
        }
        if let threadID {
            startTurn(threadID: threadID)
        } else if process == nil {
            startServer()
        } else {
            status = "Connecting to Codex…"
        }
    }

    func stop() {
        guard isWorking else { return }
        record("stop_requested")
        if nativeSpacePollTimer != nil || queuedPhrase.flatMap({ SpaceCommand(phrase: $0) }) != nil {
            nativeSpacePollTimer?.invalidate()
            nativeSpacePollTimer = nil
            completeNativeSpace(
                status: "stopped", verification: "unverified",
                message: "Stopped the desktop Space command.", details: [:])
            return
        }
        if let threadID, let turnID {
            _ = send(
                "turn/interrupt", params: ["threadId": threadID, "turnId": turnID], pendingKind: .interrupt)
            status = "Stopping…"
        } else {
            queuedPhrase = nil
            isWorking = false
            status = "Stopped"
            record("command_stopped", details: ["elapsed_ms": commandElapsedMilliseconds])
            finishCommand()
            process?.terminate()
        }
    }

    private func runNativeSpaceStep(
        _ direction: SpaceDirection, remaining: [SpaceDirection], roundTripOrigin: Int?
    ) {
        guard let before = SpaceNavigator.snapshot() else {
            completeNativeSpace(
                status: "failed", verification: "unverified",
                message: "Could not read the current desktop Space.", details: [:])
            return
        }
        guard let expected = before.adjacent(direction) else {
            completeNativeSpace(
                status: "no_adjacent_space", verification: "no_action",
                message: "There is no desktop Space to the \(direction.rawValue).",
                details: ["space_before_id": String(before.current)])
            return
        }
        record(
            "native_space_requested",
            details: [
                "direction": direction.rawValue, "space_before_id": String(before.current),
                "space_target_id": String(expected),
            ])
        let baseline = spaceChangeCount
        let commandID = activeCommandID
        let targetNumber = (before.ordered.firstIndex(of: expected) ?? 0) + 1
        status = "Opening Mission Control…"
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let self, self.isWorking, self.activeCommandID == commandID else { return }
                do {
                    if let error { throw error }
                    try MissionControlAXProbe.pressDesktop(
                        number: targetNumber, expectedCount: before.ordered.count)
                    self.record(
                        "native_space_ax_pressed",
                        details: [
                            "direction": direction.rawValue, "desktop_number": String(targetNumber),
                        ])
                    self.append("Pressed Desktop \(targetNumber) in Mission Control")
                    self.startNativeSpaceVerification(
                        direction, before: before, expected: expected, baseline: baseline,
                        remaining: remaining, roundTripOrigin: roundTripOrigin)
                } catch {
                    let visible = MissionControlAXProbe.inspectDock().nodes
                        .filter { $0.title.hasPrefix("Desktop ") }
                        .map { "\($0.path):\($0.title):\($0.description)" }
                    self.record(
                        "mission_control_ax_available",
                        details: ["desktop_controls": visible.joined(separator: "; ")])
                    if case MissionControlAXError.permissionRequired = error {
                        self.record("native_space_permission_missing")
                    }
                    self.completeNativeSpace(
                        status: "failed", verification: "unverified",
                        message: error.localizedDescription,
                        details: [
                            "direction": direction.rawValue,
                            "space_before_id": String(before.current),
                            "space_target_id": String(expected),
                        ])
                }
            }
        }
    }

    private func startNativeSpaceVerification(
        _ direction: SpaceDirection, before: SpaceSnapshot, expected: Int, baseline: Int,
        remaining: [SpaceDirection], roundTripOrigin: Int?
    ) {
        status = "Switching Space…"
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        nativeSpacePollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) {
            [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let after = SpaceNavigator.snapshot()
            let eventObserved = self.spaceChangeCount > baseline
            if after?.current == expected && eventObserved {
                timer.invalidate()
                self.nativeSpacePollTimer = nil
                let fields = [
                    "direction": direction.rawValue,
                    "space_before_id": String(before.current),
                    "space_target_id": String(expected),
                    "space_after_id": String(after?.current ?? -1),
                    "space_change_events": String(self.spaceChangeCount - baseline),
                ]
                self.record("native_space_step_verified", details: fields)
                if let next = remaining.first {
                    self.nativeSpacePollTimer = Timer.scheduledTimer(
                        withTimeInterval: 0.5, repeats: false
                    ) { [weak self] _ in
                        self?.nativeSpacePollTimer = nil
                        self?.runNativeSpaceStep(
                            next, remaining: Array(remaining.dropFirst()),
                            roundTripOrigin: roundTripOrigin ?? before.current)
                    }
                } else {
                    let returned = roundTripOrigin == after?.current
                    self.completeNativeSpace(
                        status: "completed", verification: "verified",
                        message: returned
                            ? "Switched right one desktop Space and returned left to the original Space."
                            : "Switched one desktop Space to the \(direction.rawValue).",
                        details: fields)
                }
            } else if ProcessInfo.processInfo.systemUptime >= deadline {
                timer.invalidate()
                self.nativeSpacePollTimer = nil
                self.completeNativeSpace(
                    status: "unverified", verification: "unverified",
                    message:
                        "The Mission Control desktop was pressed, but macOS did not verify the requested Space change.",
                    details: [
                        "direction": direction.rawValue,
                        "space_before_id": String(before.current),
                        "space_target_id": String(expected),
                        "space_after_id": after.map { String($0.current) } ?? "unknown",
                        "space_change_events": String(self.spaceChangeCount - baseline),
                    ])
            }
        }
    }

    private func completeNativeSpace(
        status outcome: String, verification: String, message: String, details: [String: String]
    ) {
        status = outcome == "completed" ? "Ready" : "Space \(outcome)"
        result = message
        append(message)
        var fields = details
        fields["status"] = outcome
        fields["verification"] = verification
        fields["elapsed_ms"] = commandElapsedMilliseconds
        record("native_space_finished", details: fields)
        record("command_finished", details: fields)
        queuedPhrase = nil
        spaceCountAtTurnStart = nil
        isWorking = false
        finishCommand()
    }

    private func runMissionControlProbe() {
        status = "Inspecting Mission Control…"
        record("mission_control_probe_started")
        let commandID = activeCommandID
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let self, self.isWorking, self.activeCommandID == commandID else { return }
                if let error {
                    self.record(
                        "mission_control_launch_failed",
                        details: ["error": error.localizedDescription])
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let probe = MissionControlAXProbe.inspectDock()
                    DispatchQueue.main.async {
                        guard self.isWorking, self.activeCommandID == commandID else { return }
                        self.record(
                            "mission_control_ax_summary",
                            details: [
                                "trusted": String(probe.trusted),
                                "dock_found": String(probe.dockFound),
                                "node_count": String(probe.nodes.count),
                            ])
                        for node in probe.nodes {
                            self.record(
                                "mission_control_ax_node",
                                details: [
                                    "path": node.path, "role": node.role, "title": node.title,
                                    "description": node.description, "actions": node.actions,
                                ])
                        }
                        self.status = "Ready"
                        self.result =
                            "Inspected \(probe.nodes.count) Dock accessibility elements. See Diagnostic Log."
                        self.record(
                            "command_finished", details: ["elapsed_ms": self.commandElapsedMilliseconds])
                        self.queuedPhrase = nil
                        self.isWorking = false
                        self.finishCommand()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
    }

    func decideApproval(allow: Bool, forSession: Bool = false) {
        guard let request = approval else { return }
        sendRaw(request.response(allow: allow, forSession: forSession))
        let decision = allow ? (forSession ? "Allowed for session" : "Allowed once") : "Declined"
        append("\(decision): \(request.detail)")
        record(
            "approval_decided",
            details: [
                "request_id": String(request.id), "decision": decision, "detail": request.detail,
            ])
        approval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst()
        if approval == nil && isWorking { status = "Codex is working…" }
    }

    private func startServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            fail("Codex CLI was not found in ~/.local/bin, an installed app, or Homebrew.")
            return
        }

        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("VoiceComputerPOC", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("Could not create the app support directory: \(error.localizedDescription)")
            return
        }
        serverDirectory = directory

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["app-server"]
        task.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [
            home.appendingPathComponent(".local/bin").path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
            "/bin",
        ].joined(separator: ":")
        task.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errorOutput = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = errorOutput
        self.input = input
        self.output = output
        self.errorOutput = errorOutput
        self.process = task

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consumeOutput(data) }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.consumeError(data) }
        }
        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.serverEnded(process: ended) }
        }

        do {
            try task.run()
            status = "Connecting to Codex…"
            append("Started codex app-server")
            record(
                "server_started",
                details: [
                    "executable": executable, "pid": String(task.processIdentifier),
                ])
            _ = send(
                "initialize",
                params: [
                    "clientInfo": [
                        "name": "voice_computer_poc",
                        "title": "Voice Computer POC",
                        "version": "0.1.0",
                    ]
                ], pendingKind: .initialize)
        } catch {
            fail("Could not start Codex: \(error.localizedDescription)")
            cleanupProcess()
        }
    }

    private func startTurn(threadID: String) {
        guard let phrase = queuedPhrase else { return }
        queuedPhrase = nil
        var instruction =
            "This prototype is for reversible, low-impact desktop tests. For other requests, explain that the prototype does not support them. Use only mcp__cua_repl.js for desktop UI interaction. Do not use shell commands, AppleScript, or file operations. If Computer Use access is needed, request it. Check the visible result before reporting success. Distinguish a declined access request from a tool failure; do not call a tool failure an access denial."
        if phrase.localizedCaseInsensitiveContains("chrome"),
            let runningChrome = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.google.Chrome" && $0.activationPolicy == .regular
            }), let path = runningChrome.bundleURL?.path
        {
            instruction +=
                " Google Chrome is already running from this exact app bundle path: \(path). When using cua.getApp, target this path because this Mac has another Chrome bundle with the same identifier."
            append("Resolved running Chrome: \(path)")
        }
        instruction += " User request: \(phrase)"
        status = "Codex is working…"
        append("Sent phrase to Codex")
        record("turn_requested", details: ["thread_id": threadID])
        _ = send(
            "turn/start",
            params: [
                "threadId": threadID,
                "input": [["type": "text", "text": instruction]],
            ], pendingKind: .turn)
    }

    @discardableResult
    private func send(_ method: String, params: [String: Any], pendingKind: Pending) -> Int {
        nextID += 1
        let id = nextID
        pending[id] = pendingKind
        record("rpc_sent", details: ["id": String(id), "method": method])
        sendRaw(["id": id, "method": method, "params": params])
        return id
    }

    private func sendRaw(_ message: [String: Any]) {
        guard let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            fail("Could not send to Codex: \(error.localizedDescription)")
        }
    }

    private func consumeOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer.prefix(upTo: newline)
            outputBuffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line),
                let message = object as? [String: Any]
            else {
                append("Received an unreadable app-server message")
                record("unreadable_server_message")
                continue
            }
            handle(message)
        }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty else { return }
        errorBuffer.append(data)
        if errorBuffer.count > 4_000 { errorBuffer.removeFirst(errorBuffer.count - 4_000) }
        errorLineBuffer.append(data)
        while let newline = errorLineBuffer.firstIndex(of: 0x0A) {
            let line = errorLineBuffer.prefix(upTo: newline)
            errorLineBuffer.removeSubrange(...newline)
            if errorLinesLogged < 200 {
                record("server_stderr", details: ["line": String(decoding: line, as: UTF8.self)])
                errorLinesLogged += 1
            } else if errorLinesLogged == 200 {
                record("server_stderr_limit_reached")
                errorLinesLogged += 1
            }
        }
        if errorLineBuffer.count > 4_000 {
            errorLineBuffer.removeFirst(errorLineBuffer.count - 4_000)
        }
    }

    private func handle(_ message: [String: Any]) {
        lastServerEventUptime = ProcessInfo.processInfo.systemUptime
        if let method = message["method"] as? String, let id = message["id"] as? Int {
            handleServerRequest(method: method, id: id, params: message["params"] as? [String: Any] ?? [:])
            return
        }
        if let id = message["id"] as? Int {
            handleResponse(id: id, message: message)
            return
        }
        if let method = message["method"] as? String {
            handleNotification(method: method, params: message["params"] as? [String: Any] ?? [:])
        }
    }

    private func handleResponse(id: Int, message: [String: Any]) {
        guard let kind = pending.removeValue(forKey: id) else {
            record("unexpected_rpc_response", details: ["id": String(id)])
            return
        }
        if let error = message["error"] as? [String: Any] {
            record(
                "rpc_failed",
                details: [
                    "id": String(id), "method": kind.name,
                    "error": error["message"] as? String ?? "Unknown error",
                ])
            fail("Codex request failed: \(error["message"] as? String ?? "Unknown error")")
            return
        }
        record("rpc_completed", details: ["id": String(id), "method": kind.name])
        let payload = message["result"] as? [String: Any] ?? [:]
        switch kind {
        case .initialize:
            sendRaw(["method": "initialized", "params": [String: Any]()])
            _ = send("model/list", params: [:], pendingKind: .models)
        case .models:
            let models = payload["data"] as? [[String: Any]] ?? []
            let available = models.compactMap { $0["id"] as? String }
            guard let model = available.first(where: { $0 == "gpt-5.6-sol" }) ?? available.first else {
                fail("Codex reported no available models.")
                return
            }
            append("Using model \(model)")
            guard let workingDirectory = serverDirectory?.path else {
                fail("Codex working directory is unavailable.")
                return
            }
            _ = send(
                "thread/start",
                params: [
                    "model": model,
                    "cwd": workingDirectory,
                    "approvalPolicy": "on-request",
                    "sandbox": "read-only",
                ], pendingKind: .thread)
        case .thread:
            guard let thread = payload["thread"] as? [String: Any],
                let id = thread["id"] as? String
            else {
                fail("Codex did not return a thread ID.")
                return
            }
            threadID = id
            append("Connected to Codex")
            startTurn(threadID: id)
        case .turn:
            if let turn = payload["turn"] as? [String: Any] {
                turnID = turn["id"] as? String
                record("turn_started", details: ["turn_id": turnID ?? "unknown"])
            }
        case .interrupt:
            append("Stop requested")
        }
    }

    private func handleServerRequest(method: String, id: Int, params: [String: Any]) {
        if let request = ApprovalRequest.parse(method: method, id: id, params: params) {
            if approval == nil { approval = request } else { queuedApprovals.append(request) }
            status = "Waiting for your approval"
            append("Approval needed: \(request.detail)")
            record(
                "approval_requested",
                details: [
                    "request_id": String(id), "detail": request.detail,
                    "session_grant_available": String(request.supportsSessionGrant),
                ])
        } else {
            sendRaw(["id": id, "error": ["code": -32601, "message": "Unsupported request in prototype"]])
            append("Unsupported server request: \(method)")
            record("unsupported_server_request", details: ["method": method])
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        if method == "item/started", let item = params["item"] as? [String: Any],
            item["type"] as? String == "mcpToolCall"
        {
            let server = item["server"] as? String ?? "tool"
            let tool = item["tool"] as? String ?? "call"
            append("Using \(server).\(tool)")
            record(
                "tool_started",
                details: [
                    "item_id": item["id"] as? String ?? "unknown",
                    "server": server, "tool": tool,
                ])
        } else if method == "item/completed", let item = params["item"] as? [String: Any] {
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String, !text.isEmpty {
                result = text
            } else if item["type"] as? String == "mcpToolCall" {
                let directError = (item["error"] as? [String: Any])?["message"] as? String
                let toolResult = item["result"] as? [String: Any]
                let content = toolResult?["content"] as? [[String: Any]]
                let resultError = content?.compactMap { $0["text"] as? String }.first
                let detail = directError ?? resultError
                let status = item["status"] as? String ?? "unknown"
                let resultIsError = toolResult?["isError"] as? Bool ?? false
                var fields = [
                    "item_id": item["id"] as? String ?? "unknown",
                    "server": item["server"] as? String ?? "tool",
                    "tool": item["tool"] as? String ?? "call",
                    "status": status,
                    "result_is_error": String(resultIsError),
                ]
                if status == "failed" || resultIsError {
                    fields["error"] = detail ?? "Unknown tool error"
                    append(
                        detail.map { "Computer Use tool call failed: \(String($0.prefix(500)))" }
                            ?? "Computer Use tool call failed")
                }
                record("tool_completed", details: fields)
            }
        } else if method == "turn/completed" {
            let turn = params["turn"] as? [String: Any] ?? [:]
            guard isWorking else {
                record(
                    "unexpected_turn_completed",
                    details: ["turn_id": turn["id"] as? String ?? "unknown"])
                return
            }
            let outcome = turn["status"] as? String ?? "completed"
            let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            var verification = "model_report_only"
            status = outcome == "completed" ? "Ready" : "Turn \(outcome)"
            append("Turn \(outcome)")
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
                result = message
            }
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
            record(
                "turn_completed",
                details: [
                    "turn_id": turnID ?? "unknown", "status": outcome, "result": result,
                    "frontmost_app": lastActivatedApp,
                    "frontmost_bundle_id": frontmostBundleID ?? "unknown",
                    "activated_bundle_ids": activatedBundleIDsThisTurn.sorted().joined(separator: ","),
                    "space_change_count": String(spaceChangeCount),
                    "verification": verification,
                    "elapsed_ms": commandElapsedMilliseconds,
                ])
            record(
                "command_finished",
                details: [
                    "status": outcome, "verification": verification,
                    "elapsed_ms": commandElapsedMilliseconds,
                ])
            focusTargetBundleID = nil
            activatedBundleIDsThisTurn.removeAll()
            isWorking = false
            turnID = nil
            approval = nil
            queuedApprovals.removeAll()
            finishCommand()
        } else if method == "error" {
            let error = params["error"] as? [String: Any] ?? [:]
            fail(error["message"] as? String ?? "Codex reported an error")
        }
    }

    private func serverEnded(process ended: Process) {
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

    private func cleanupProcess() {
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        threadID = nil
        turnID = nil
        pending.removeAll()
        approval = nil
        queuedApprovals.removeAll()
        outputBuffer.removeAll()
        errorBuffer.removeAll()
        errorLineBuffer.removeAll()
        errorLinesLogged = 0
    }

    private func fail(_ message: String) {
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

    private func append(_ event: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        events.append("\(stamp)  \(event)")
        record("activity", details: ["message": event])
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }

    func revealLog() {
        guard let logURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    private func record(_ event: String, details: [String: String] = [:]) {
        guard let diagnosticLog else { return }
        do {
            var fields = details
            if let activeCommandID { fields["command_id"] = activeCommandID }
            diagnosticEntries.append(try diagnosticLog.record(event, details: fields))
        } catch {
            logError = "Could not write diagnostic log: \(error.localizedDescription)"
        }
    }

    private var commandElapsedMilliseconds: String {
        guard let commandStartedUptime else { return "unknown" }
        return String(Int((ProcessInfo.processInfo.systemUptime - commandStartedUptime) * 1_000))
    }

    private func checkCommandProgress() {
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

    private func finishCommand() {
        commandWatchdog?.invalidate()
        commandWatchdog = nil
        activeCommandID = nil
        commandStartedUptime = nil
        lastServerEventUptime = nil
        lastIdleWarningUptime = nil
    }
}
