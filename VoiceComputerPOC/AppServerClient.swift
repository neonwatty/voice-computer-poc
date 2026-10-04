import AppKit
import Combine
import Foundation

final class AppServerClient: ObservableObject {
    enum InputSource: String {
        case typed
        case reviewedVoice = "reviewed_voice"
    }

    enum GeneralTurnFailure: String {
        case approvalUnavailable = "approval_unavailable"
        case accessDeclined = "access_declined"
        case toolFailed = "tool_failed"
    }

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
        case initialize, models, thread, mcpStatus, turn, interrupt

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
    var selectedModel: String?
    var turnID: String?
    var queuedPhrase: String?
    var queuedApprovals: [ApprovalRequest] = []
    var spaceObserver: NSObjectProtocol?
    var activationObserver: NSObjectProtocol?
    var spaceCountAtTurnStart: Int?
    var focusTargetBundleID: String?
    var browserDocsURL: URL?
    var finderReportURL: URL?
    var activatedBundleIDsThisTurn: Set<String> = []
    var activeCommandID: String?
    var cancelledNativeSpaceCommandID: String?
    var voiceCaptureCommandID: String?
    var commandStartedUptime: TimeInterval?
    var lastServerEventUptime: TimeInterval?
    var lastIdleWarningUptime: TimeInterval?
    var commandWatchdog: Timer?
    var nativeSpacePollTimer: Timer?
    var toolCallTimeoutTimer: Timer?
    var spaceToolBridge: SpaceToolBridge?
    var desktopToolPreflight: DesktopToolPreflight?
    var expectedToolDirection: SpaceDirection?
    var requestedToolDirection: SpaceDirection?
    var activeToolDirection: SpaceDirection?
    var toolReply: ((SpaceToolResult) -> Void)?
    var toolCallObserved = false
    var activeMCPToolItemID: String?
    var activeMCPToolTurnID: String?
    var activeMCPToolDirection: SpaceDirection?
    var spaceToolApproval: SpaceToolApproval?
    var toolCallCompleted = false
    var toolResult: SpaceToolResult?
    var generalTurnFailure: GeneralTurnFailure?
    var generalToolObserved = false
    var fixtureCUAToolStartedIDs: Set<String> = []
    var fixtureCUAToolCompletedIDs: Set<String> = []
    var remainingRoutedDirections: [SpaceDirection] = []
    var routedOriginalPhrase: String?
    #if DEBUG
        var actingTurnOverride: (() -> Void)?
        var routingOverride: ((String) -> Void)?
    #endif
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
            guard let self else { return }
            var fields = details
            if let voiceCaptureCommandID = self.voiceCaptureCommandID {
                fields["command_id"] = voiceCaptureCommandID
            }
            self.record(event, details: fields)
        }
        let center = NSWorkspace.shared.notificationCenter
        lastActivatedApp = NSWorkspace.shared.frontmostApplication?.localizedName ?? "Unknown"
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.observeSystemSpaceNotification()
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
        toolCallTimeoutTimer?.invalidate()
        desktopToolPreflight?.cancel()
        spaceToolBridge?.stop()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        output?.fileHandleForReading.readabilityHandler = nil
        errorOutput?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    func prepareVoiceCapture() {
        guard !isWorking, voiceInput.state == .idle else { return }
        let commandID = UUID().uuidString
        voiceCaptureCommandID = commandID
        record("voice_capture_prepared", details: ["command_id": commandID])
    }

    func run(_ phrase: String, source: InputSource = .typed, transcriptEdited: Bool = false) {
        let phrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty, !isWorking else { return }
        result = ""
        isWorking = true
        activeCommandID =
            source == .reviewedVoice ? (voiceCaptureCommandID ?? UUID().uuidString) : UUID().uuidString
        cancelledNativeSpaceCommandID = nil
        voiceCaptureCommandID = nil
        commandStartedUptime = ProcessInfo.processInfo.systemUptime
        lastServerEventUptime = commandStartedUptime
        lastIdleWarningUptime = nil
        commandWatchdog?.invalidate()
        commandWatchdog = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.checkCommandProgress()
        }
        queuedPhrase = phrase
        configureCommandRouting(phrase)
        append("Requested: \(phrase)")
        record(
            "command_started",
            details: [
                "input_source": source.rawValue,
                "transcript_edited": String(transcriptEdited),
                "user_action": "run",
                "frontmost_bundle_id": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
                "frontmost_app": lastActivatedApp,
                "space_change_count": String(spaceChangeCount),
            ])
        recordLiveSpaceObservation("before_command")
        if source == .reviewedVoice {
            routePhrase(phrase)
            return
        }
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
        if SpaceToolRequest.direction(for: phrase) == nil {
            routePhrase(phrase)
            return
        }
        beginActingTurn()
    }

    private func configureCommandRouting(_ phrase: String) {
        browserDocsURL = nil
        finderReportURL = nil
        expectedToolDirection = SpaceToolRequest.direction(for: phrase)
        requestedToolDirection = expectedToolDirection
        activeToolDirection = nil
        toolCallObserved = false
        activeMCPToolItemID = nil
        activeMCPToolTurnID = nil
        activeMCPToolDirection = nil
        spaceToolApproval = nil
        spaceToolBridge?.revoke()
        toolCallCompleted = false
        toolResult = nil
        generalTurnFailure = nil
        generalToolObserved = false
        fixtureCUAToolStartedIDs.removeAll()
        fixtureCUAToolCompletedIDs.removeAll()
        remainingRoutedDirections = []
        routedOriginalPhrase = nil
        spaceCountAtTurnStart =
            phrase.localizedCaseInsensitiveContains("desktop Space")
            ? spaceChangeCount : nil
        activatedBundleIDsThisTurn.removeAll()
        if phrase.caseInsensitiveCompare("Open Calculator") == .orderedSame {
            focusTargetBundleID = "com.apple.calculator"
        } else if phrase.localizedCaseInsensitiveContains("foreground")
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
    }

    func stop() {
        guard isWorking else { return }
        cancelledNativeSpaceCommandID = activeCommandID
        spaceToolApproval = nil
        spaceToolBridge?.revoke()
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
        if nativeSpacePollTimer != nil || toolReply != nil
            || queuedPhrase.flatMap({ SpaceCommand(phrase: $0) }) != nil
        {
            let hadToolReply = toolReply != nil
            nativeSpacePollTimer?.invalidate()
            nativeSpacePollTimer = nil
            completeNativeSpace(
                status: "stopped", verification: "unverified",
                message: "Stopped the desktop Space command.", details: [:])
            if hadToolReply, let threadID, let turnID {
                _ = send(
                    "turn/interrupt", params: ["threadId": threadID, "turnId": turnID],
                    pendingKind: .interrupt)
                status = "Stopping…"
            }
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
