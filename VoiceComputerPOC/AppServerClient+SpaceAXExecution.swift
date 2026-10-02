import AppKit
import ApplicationServices

// The AX tree is discovered off main, as in the successful read-only probe.
// Discovery never performs an AX action. The selected element is checked again on main.
struct MissionControlAXDiscovery {
    let list: AXUIElement
    let target: AXUIElement
}

enum NativeSpaceAXExecution {
    static func discover(number: Int, expectedCount: Int, deadline: TimeInterval) throws
        -> MissionControlAXDiscovery
    {
        guard MissionControlAXProbe.isTrusted else { throw MissionControlAXError.permissionRequired }
        guard
            let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first
        else { throw MissionControlAXError.dockUnavailable }
        var queue = [AXUIElementCreateApplication(dock.processIdentifier)]
        var visited = 0
        var largestCount = 0
        while !queue.isEmpty && visited < 120 {
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw MissionControlAXError.scanUnavailable("readiness_timeout", largestCount, visited)
            }
            let element = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            let children = children(of: element)
            if string(element, kAXRoleAttribute) == kAXListRole as String {
                let desktops = desktopButtons(children)
                largestCount = max(largestCount, desktops.count)
                if exactTitles(desktops, expectedCount: expectedCount),
                    let target = desktops.first(where: {
                        string($0, kAXTitleAttribute) == "Desktop \(number)"
                            && string($0, kAXDescriptionAttribute) == "exit to Desktop \(number)"
                    }), hasPress(target)
                {
                    return .init(list: element, target: target)
                }
            }
            queue.append(contentsOf: children)
        }
        let reason =
            largestCount == 0
            ? "missing_controls"
            : largestCount < expectedCount ? "incomplete_controls" : "mismatched_controls"
        throw MissionControlAXError.scanUnavailable(reason, largestCount, visited)
    }

    static func revalidate(
        _ discovery: MissionControlAXDiscovery, number: Int, expectedCount: Int
    ) throws {
        guard MissionControlAXProbe.isTrusted else { throw MissionControlAXError.permissionRequired }
        guard string(discovery.list, kAXRoleAttribute) == kAXListRole as String else {
            throw MissionControlAXError.desktopNotFound("stale_controls")
        }
        let desktops = desktopButtons(children(of: discovery.list))
        guard exactTitles(desktops, expectedCount: expectedCount),
            desktops.contains(where: { CFEqual($0, discovery.target) }),
            string(discovery.target, kAXRoleAttribute) == kAXButtonRole as String,
            string(discovery.target, kAXTitleAttribute) == "Desktop \(number)",
            string(discovery.target, kAXDescriptionAttribute) == "exit to Desktop \(number)",
            hasPress(discovery.target)
        else { throw MissionControlAXError.desktopNotFound("stale_controls") }
    }
    static func press(_ discovery: MissionControlAXDiscovery) throws {
        let result = AXUIElementPerformAction(discovery.target, kAXPressAction as CFString)
        guard result == .success else { throw MissionControlAXError.pressFailed(result) }
    }

    private static func exactTitles(_ desktops: [AXUIElement], expectedCount: Int) -> Bool {
        guard expectedCount > 0, desktops.count == expectedCount else { return false }
        return Set(desktops.map { string($0, kAXTitleAttribute) })
            == Set((1...expectedCount).map { "Desktop \($0)" })
    }
    private static func desktopButtons(_ children: [AXUIElement]) -> [AXUIElement] {
        children.filter {
            AXUIElementSetMessagingTimeout($0, 0.1)
            return string($0, kAXRoleAttribute) == kAXButtonRole as String
                && string($0, kAXTitleAttribute).hasPrefix("Desktop ")
        }
    }
    private static func hasPress(_ element: AXUIElement) -> Bool {
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success
            && (actions as? [String] ?? []).contains(kAXPressAction as String)
    }
    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return ""
        }
        return value as? String ?? ""
    }
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }
}

extension AppServerClient {
    func launchNativeSpaceDiscovery(_ readiness: NativeSpaceReadiness) {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self, self.isWorking,
                    self.activeCommandID == readiness.commandID
                else { return }
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - readiness.deadline + 4) * 1000)
                self.record(
                    error == nil ? "mission_control_launch_completed" : "mission_control_launch_failed",
                    details: ["elapsed_ms": String(elapsed)])
                self.discoverAndPressNativeSpace(
                    readiness, launchError: error, attempts: 1,
                    discover: {
                        try NativeSpaceAXExecution.discover(
                            number: readiness.targetNumber,
                            expectedCount: readiness.before.ordered.count,
                            deadline: readiness.deadline)
                    },
                    revalidate: { discovery in
                        try NativeSpaceAXExecution.revalidate(
                            discovery, number: readiness.targetNumber,
                            expectedCount: readiness.before.ordered.count)
                    },
                    press: { discovery in
                        try NativeSpaceAXExecution.press(discovery)
                    })
            }
        }
    }

    func completeDiscoveredNativeSpace(
        _ readiness: NativeSpaceReadiness, discovery: MissionControlAXDiscovery, attempts: Int,
        revalidate: (MissionControlAXDiscovery) throws -> Void,
        press: (MissionControlAXDiscovery) throws -> Void,
        liveSpaceID: () -> Int?
    ) {
        guard isWorking, activeCommandID == readiness.commandID else { return }
        do {
            guard ProcessInfo.processInfo.systemUptime < readiness.deadline else {
                throw MissionControlAXError.desktopNotFound("readiness_timeout")
            }
            guard liveSpaceID() == readiness.before.current else {
                throw MissionControlAXError.desktopNotFound("start_space_changed")
            }
            try revalidate(discovery)
            guard ProcessInfo.processInfo.systemUptime < readiness.deadline else {
                throw MissionControlAXError.desktopNotFound("readiness_timeout")
            }
            guard liveSpaceID() == readiness.before.current else {
                throw MissionControlAXError.desktopNotFound("start_space_changed")
            }
            guard readiness.pressGate.claim() else {
                throw MissionControlAXError.desktopNotFound("duplicate_press")
            }
            try press(discovery)
            record(
                "native_space_ax_pressed",
                details: [
                    "direction": readiness.direction.rawValue,
                    "desktop_number": String(readiness.targetNumber),
                ])
            append("Pressed Desktop \(readiness.targetNumber) in Mission Control")
            startNativeSpaceVerification(
                readiness.direction, before: readiness.before, expected: readiness.expected,
                baseline: readiness.baseline, remaining: readiness.remaining,
                roundTripOrigin: readiness.roundTripOrigin)
        } catch {
            handleNativeSpaceReadinessError(error, readiness: readiness, attempts: attempts)
        }
    }

    func discoverAndPressNativeSpace(
        _ readiness: NativeSpaceReadiness, launchError: Error?, attempts: Int,
        discover: @escaping () throws -> MissionControlAXDiscovery,
        revalidate: @escaping (MissionControlAXDiscovery) throws -> Void,
        press: @escaping (MissionControlAXDiscovery) throws -> Void,
        liveSpaceID: @escaping () -> Int? = { SpaceNavigator.liveSpaceID() }
    ) {
        guard isWorking, activeCommandID == readiness.commandID else { return }
        if let launchError {
            handleNativeSpaceReadinessError(launchError, readiness: readiness, attempts: attempts)
            return
        }
        guard ProcessInfo.processInfo.systemUptime < readiness.deadline else {
            handleNativeSpaceReadinessError(
                MissionControlAXError.desktopNotFound("readiness_timeout"),
                readiness: readiness, attempts: attempts)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = Result { try discover() }
            DispatchQueue.main.async {
                guard let self, self.isWorking, self.activeCommandID == readiness.commandID else {
                    return
                }
                switch outcome {
                case .failure(let error):
                    self.handleNativeSpaceReadinessError(
                        error, readiness: readiness, attempts: attempts,
                        retry: { [weak self] in
                            self?.discoverAndPressNativeSpace(
                                readiness, launchError: nil, attempts: attempts + 1,
                                discover: discover, revalidate: revalidate, press: press,
                                liveSpaceID: liveSpaceID)
                        })
                case .success(let discovery):
                    self.completeDiscoveredNativeSpace(
                        readiness, discovery: discovery, attempts: attempts,
                        revalidate: revalidate, press: press, liveSpaceID: liveSpaceID)
                }
            }
        }
    }
}
