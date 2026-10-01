import AppKit
import Foundation

extension AppServerClient {
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

    func startServer() {
        guard let (task, executable) = makeServerProcess() else { return }
        process = task
        observeServerProcess(task)
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

    func makeServerProcess() -> (Process, String)? {
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
            return nil
        }

        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("VoiceComputerPOC", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fail("Could not create the app support directory: \(error.localizedDescription)")
            return nil
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
        return (task, executable)
    }

    func observeServerProcess(_ task: Process) {
        guard let output, let errorOutput else { return }
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
    }

    func startTurn(threadID: String) {
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
    func send(_ method: String, params: [String: Any], pendingKind: Pending) -> Int {
        nextID += 1
        let id = nextID
        pending[id] = pendingKind
        record("rpc_sent", details: ["id": String(id), "method": method])
        sendRaw(["id": id, "method": method, "params": params])
        return id
    }

    func sendRaw(_ message: [String: Any]) {
        guard let input else { return }
        do {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0A)
            try input.fileHandleForWriting.write(contentsOf: data)
        } catch {
            fail("Could not send to Codex: \(error.localizedDescription)")
        }
    }

    func consumeOutput(_ data: Data) {
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

    func consumeError(_ data: Data) {
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

    func handle(_ message: [String: Any]) {
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

}
