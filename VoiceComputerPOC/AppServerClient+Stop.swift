import Foundation

extension AppServerClient {
    func stop() {
        guard isWorking else { return }
        cancelledNativeSpaceCommandID = activeCommandID
        spaceToolApproval = nil
        desktopStateApproval = nil
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
