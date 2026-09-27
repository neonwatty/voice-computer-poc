import AppKit
import Combine
import Foundation

final class AppServerClient: ObservableObject {
    @Published private(set) var status = "Ready"
    @Published private(set) var isWorking = false
    @Published private(set) var result = ""
    @Published private(set) var events: [String] = []
    @Published private(set) var spaceChangeCount = 0
    @Published private(set) var lastActivatedApp = "Unknown"
    @Published var approval: ApprovalRequest?

    private enum Pending {
        case initialize, models, thread, turn, interrupt
    }

    private var process: Process?
    private var serverDirectory: URL?
    private var input: Pipe?
    private var output: Pipe?
    private var errorOutput: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
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

    var canStop: Bool { isWorking }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        lastActivatedApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.spaceChangeCount += 1
            self?.append("macOS reported an active Space change")
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
            }
        }
    }

    deinit {
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
        if let threadID, let turnID {
            _ = send(
                "turn/interrupt", params: ["threadId": threadID, "turnId": turnID], pendingKind: .interrupt)
            status = "Stopping…"
        } else {
            queuedPhrase = nil
            isWorking = false
            status = "Stopped"
            process?.terminate()
        }
    }

    func decideApproval(allow: Bool, forSession: Bool = false) {
        guard let request = approval else { return }
        sendRaw(request.response(allow: allow, forSession: forSession))
        let decision = allow ? (forSession ? "Allowed for session" : "Allowed once") : "Declined"
        append("\(decision): \(request.detail)")
        approval = queuedApprovals.isEmpty ? nil : queuedApprovals.removeFirst()
        if approval == nil && isWorking { status = "Codex is working…" }
    }

    private func startServer() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            fail("Codex CLI was not found in ~/.local/bin, /opt/homebrew/bin, or /usr/local/bin.")
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
            DispatchQueue.main.async { self?.serverEnded(exitCode: ended.terminationStatus) }
        }

        do {
            try task.run()
            status = "Connecting to Codex…"
            append("Started codex app-server")
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
                continue
            }
            handle(message)
        }
    }

    private func consumeError(_ data: Data) {
        guard !data.isEmpty else { return }
        errorBuffer.append(data)
        if errorBuffer.count > 4_000 { errorBuffer.removeFirst(errorBuffer.count - 4_000) }
    }

    private func handle(_ message: [String: Any]) {
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
        guard let kind = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? [String: Any] {
            fail("Codex request failed: \(error["message"] as? String ?? "Unknown error")")
            return
        }
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
        } else {
            sendRaw(["id": id, "error": ["code": -32601, "message": "Unsupported request in prototype"]])
            append("Unsupported server request: \(method)")
        }
    }

    private func handleNotification(method: String, params: [String: Any]) {
        if method == "item/started", let item = params["item"] as? [String: Any],
            item["type"] as? String == "mcpToolCall"
        {
            let server = item["server"] as? String ?? "tool"
            let tool = item["tool"] as? String ?? "call"
            append("Using \(server).\(tool)")
        } else if method == "item/completed", let item = params["item"] as? [String: Any] {
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String, !text.isEmpty {
                result = text
            } else if item["type"] as? String == "mcpToolCall", item["status"] as? String == "failed" {
                let directError = (item["error"] as? [String: Any])?["message"] as? String
                let toolResult = item["result"] as? [String: Any]
                let content = toolResult?["content"] as? [[String: Any]]
                let resultError = content?.compactMap { $0["text"] as? String }.first
                let detail = directError ?? resultError
                append(
                    detail.map { "Computer Use tool call failed: \(String($0.prefix(500)))" }
                        ?? "Computer Use tool call failed")
            }
        } else if method == "turn/completed" {
            let turn = params["turn"] as? [String: Any] ?? [:]
            let outcome = turn["status"] as? String ?? "completed"
            status = outcome == "completed" ? "Ready" : "Turn \(outcome)"
            append("Turn \(outcome)")
            if let error = turn["error"] as? [String: Any], let message = error["message"] as? String {
                result = message
            }
            if let baseline = spaceCountAtTurnStart {
                if spaceChangeCount > baseline {
                    append("Verified: macOS reported an active Space change during this command")
                } else {
                    append("Unverified: macOS reported no active Space change during this command")
                    result =
                        "The shortcut was attempted, but macOS reported no active Space change. The Space switch is unverified."
                }
            }
            spaceCountAtTurnStart = nil
            if let target = focusTargetBundleID,
                !activatedBundleIDsThisTurn.contains(target)
            {
                append("Unverified: macOS reported no activation of the requested app")
                result =
                    "Computer Use inspected the app window, but macOS did not report the requested app becoming active. Foreground focus is unverified."
            }
            focusTargetBundleID = nil
            activatedBundleIDsThisTurn.removeAll()
            isWorking = false
            turnID = nil
            approval = nil
            queuedApprovals.removeAll()
        } else if method == "error" {
            let error = params["error"] as? [String: Any] ?? [:]
            fail(error["message"] as? String ?? "Codex reported an error")
        }
    }

    private func serverEnded(exitCode: Int32) {
        let details =
            String(data: errorBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    }

    private func fail(_ message: String) {
        status = "Error"
        result = message
        append(message)
        isWorking = false
        queuedPhrase = nil
        spaceCountAtTurnStart = nil
        focusTargetBundleID = nil
        activatedBundleIDsThisTurn.removeAll()
    }

    private func append(_ event: String) {
        let stamp = Date().formatted(date: .omitted, time: .shortened)
        events.append("\(stamp)  \(event)")
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }
}
