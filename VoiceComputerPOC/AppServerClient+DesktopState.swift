import AppKit
import Foundation

extension AppServerClient {
    func shouldRetryDesktopStateDiscovery(outcome: String) -> Bool {
        requestedDesktopState && !desktopStateReadRetried && outcome == "completed"
            && activeStateToolItemID == nil && stateToolResult == nil
            && desktopStateApproval == nil && approval == nil
    }

    func handleDesktopStateRequest(
        _ request: DesktopStateToolRequest, peer: SpaceToolBridge.PeerIdentity,
        reply: @escaping (DesktopStateToolResult) -> Void
    ) {
        guard let bridge = spaceToolBridge, request.sessionID == bridge.sessionID,
            request.operation == "get_desktop_state", requestedDesktopState,
            isWorking, let activeCommandID,
            let itemID = activeStateToolItemID,
            activeStateToolTurnID == turnID, turnID != nil,
            hasAcceptedDesktopStateApproval(commandID: activeCommandID, itemID: itemID),
            bridge.bind(peer, commandID: activeCommandID, itemID: itemID),
            bridge.isBoundPeerAlive(commandID: activeCommandID, itemID: itemID)
        else {
            reply(.failure("rejected", "No matching desktop-state read is active."))
            return
        }
        desktopStateApproval?.state = .consumed
        record("mcp_state_helper_bound", details: bridge.helperIdentityDetails)
        let observed = DesktopStateToolResult.observe(
            snapshot: SpaceNavigator.snapshot,
            frontmost: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
            ambiguousDisplay: SpaceNavigator.displayTopologyAmbiguous)
        stateToolResult = observed
        record(
            "mcp_state_observed",
            details: [
                "status": observed.status,
                "space_id": observed.currentMainSpaceID.map(String.init) ?? "unknown",
                "ordered_space_ids": observed.orderedMainSpaceIDs?.map(String.init).joined(separator: ",")
                    ?? "unknown",
                "observed_at": observed.observedAt ?? "unknown",
                "frontmost_bundle_id": observed.frontmostBundleID ?? "unknown",
            ])
        reply(observed)
    }
}
