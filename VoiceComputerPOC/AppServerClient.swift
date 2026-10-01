import AppKit
import Combine
import Foundation

final class AppServerClient: ObservableObject {
    let voiceInput = LocalVoiceInput()
    @Published var status = "Ready"
    @Published var isWorking = false
    @Published var result = ""
    @Published var events: [String] = []
    @Published var diagnosticEntries: [DiagnosticLog.Entry] = []
    @Published var spaceChangeCount = 0
    @Published var lastActivatedApp = "Unknown"
    @Published var logError = ""
    @Published var approval: ApprovalRequest?

    enum Pending {
        case initialize, models, thread, turn, interrupt

        var name: String { String(describing: self) }
    }

    var process: Process?
    var serverDirectory: URL?
    var input: Pipe?
    var output: Pipe?
    var errorOutput: Pipe?
    var outputBuffer = Data()
    var errorBuffer = Data()
    var errorLineBuffer = Data()
    var errorLinesLogged = 0
    var pending: [Int: Pending] = [:]
    var nextID = 0
    var threadID: String?
    var turnID: String?
    var queuedPhrase: String?
    var queuedApprovals: [ApprovalRequest] = []
    var spaceObserver: NSObjectProtocol?
    var activationObserver: NSObjectProtocol?
    var spaceCountAtTurnStart: Int?
    var focusTargetBundleID: String?
    var activatedBundleIDsThisTurn: Set<String> = []
    var activeCommandID: String?
    var commandStartedUptime: TimeInterval?
    var lastServerEventUptime: TimeInterval?
    var lastIdleWarningUptime: TimeInterval?
    var commandWatchdog: Timer?
    var nativeSpacePollTimer: Timer?
    let diagnosticLog: DiagnosticLog?

    var logURL: URL? { diagnosticLog?.fileURL }

    var canStop: Bool { isWorking }

    init(logDirectory: URL? = nil) {
        let defaultLogDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("VoiceComputerPOC/Logs", isDirectory: true)
        do {
            diagnosticLog = try DiagnosticLog(directory: logDirectory ?? defaultLogDirectory)
        } catch {
            diagnosticLog = nil
            logError = "Could not create diagnostic log: \(error.localizedDescription)"
        }
        record("app_started")
        voiceInput.onEvent = { [weak self] event, details in
            self?.record(event, details: details)
        }
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
        voiceInput.cancel()
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
        if queuedPhrase?.lowercased() == "inspect mission control desktop controls" {
            status = "Stopped"
            result = "Stopped the Mission Control inspection."
            record("mission_control_probe_stopped")
            queuedPhrase = nil
            isWorking = false
            finishCommand()
            return
        }
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

}
