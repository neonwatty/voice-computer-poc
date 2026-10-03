import AppKit
import ApplicationServices
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
        var candidate: MissionControlAXDiscovery?
        var malformed = false
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
                if !desktops.isEmpty, exactControls(desktops, expectedCount: expectedCount),
                    let target = desktops.first(where: {
                        string($0, kAXTitleAttribute) == "Desktop \(number)"
                    })
                {
                    if candidate != nil { malformed = true }
                    candidate = .init(list: element, target: target)
                } else if !desktops.isEmpty {
                    malformed = true
                }
            }
            queue.append(contentsOf: children)
        }
        guard queue.isEmpty else {
            throw MissionControlAXError.scanUnavailable("readiness_timeout", largestCount, visited)
        }
        if !malformed, let candidate { return candidate }
        let reason =
            largestCount == 0
            ? "missing_controls"
            : largestCount < expectedCount && candidate == nil
                ? "incomplete_controls"
                : "mismatched_controls"
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
        guard exactControls(desktops, expectedCount: expectedCount),
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
    private static func exactControls(_ desktops: [AXUIElement], expectedCount: Int) -> Bool {
        guard expectedCount > 0, desktops.count == expectedCount else { return false }
        let titles = Set(desktops.map { string($0, kAXTitleAttribute) })
        guard titles == Set((1...expectedCount).map { "Desktop \($0)" }) else { return false }
        return desktops.allSatisfy {
            string($0, kAXDescriptionAttribute) == "exit to \(string($0, kAXTitleAttribute))"
                && hasPress($0)
        }
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
        if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success {
            return value as? String ?? ""
        }
        return ""
    }
    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
            == .success
        {
            return value as? [AXUIElement] ?? []
        }
        return []
    }
}
extension AppServerClient {
    func requestVoiceForeground(
        _ readiness: NativeSpaceReadiness,
        activate: () -> Void = { NSApp.activate() },
        isActive: @escaping () -> Bool = { NSApp.isActive },
        frontmostBundleID: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        launch: @escaping () -> Void
    ) {
        guard nativeSpaceActionActive(commandID: readiness.commandID) else { return }
        let started = ProcessInfo.processInfo.systemUptime
        guard started < readiness.deadline else {
            handleNativeSpaceReadinessError(
                MissionControlAXError.desktopNotFound("readiness_timeout"),
                readiness: readiness, attempts: 0)
            return
        }
        record("voice_foreground_requested")
        activate()
        pollVoiceForeground(
            readiness, started: started, cutoff: min(readiness.deadline, started + 0.8),
            isActive: isActive, frontmostBundleID: frontmostBundleID,
            launch: launch)
    }
    private func pollVoiceForeground(
        _ readiness: NativeSpaceReadiness, started: TimeInterval, cutoff: TimeInterval,
        isActive: @escaping () -> Bool, frontmostBundleID: @escaping () -> String?,
        launch: @escaping () -> Void
    ) {
        guard nativeSpaceActionActive(commandID: readiness.commandID) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let active = isActive()
        let matches = frontmostBundleID() == "com.neonwatty.VoiceComputerPOC"
        if active && matches && now < readiness.deadline {
            record(
                "voice_foreground_observed",
                details: [
                    "active": "true", "frontmost_matches": "true",
                    "elapsed_ms": String(Int((now - started) * 1000)),
                ])
            launch()
            return
        }
        if now >= cutoff {
            record(
                "voice_foreground_observed",
                details: [
                    "active": String(active), "frontmost_matches": String(matches),
                    "elapsed_ms": String(Int((now - started) * 1000)),
                ])
            handleNativeSpaceReadinessError(
                MissionControlAXError.desktopNotFound(
                    active ? "frontmost_mismatch" : "voice_inactive"),
                readiness: readiness, attempts: 0)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.pollVoiceForeground(
                readiness, started: started, cutoff: cutoff, isActive: isActive,
                frontmostBundleID: frontmostBundleID, launch: launch)
        }
    }
    func launchNativeSpaceDiscovery(_ readiness: NativeSpaceReadiness) {
        let url = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
            [weak self] application, error in
            DispatchQueue.main.async {
                self?.handleMissionControlLaunchResult(
                    readiness, applicationPresent: application != nil, error: error
                ) { [weak self] in
                    self?.discoverAndPressNativeSpace(
                        readiness, launchError: nil, attempts: 1)
                }
            }
        }
    }
    func completeDiscoveredNativeSpace(
        _ readiness: NativeSpaceReadiness, discovery: MissionControlAXDiscovery, attempts: Int,
        revalidate: (MissionControlAXDiscovery) throws -> Void,
        press: (MissionControlAXDiscovery) throws -> Void,
        liveSpaceID: () -> Int?
    ) {
        guard nativeSpaceActionActive(commandID: readiness.commandID) else { return }
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
            guard nativeSpaceActionActive(commandID: readiness.commandID) else { return }
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
        discover: (() throws -> MissionControlAXDiscovery)? = nil,
        revalidate: ((MissionControlAXDiscovery) throws -> Void)? = nil,
        press: ((MissionControlAXDiscovery) throws -> Void)? = nil,
        liveSpaceID: @escaping () -> Int? = { SpaceNavigator.liveSpaceID() },
        openOnAbsent: (() -> Void)? = nil
    ) {
        let discover =
            discover ?? {
                try NativeSpaceAXExecution.discover(
                    number: readiness.targetNumber, expectedCount: readiness.before.ordered.count,
                    deadline: readiness.deadline)
            }
        let revalidate =
            revalidate ?? {
                try NativeSpaceAXExecution.revalidate(
                    $0, number: readiness.targetNumber,
                    expectedCount: readiness.before.ordered.count)
            }
        let press = press ?? { try NativeSpaceAXExecution.press($0) }
        guard nativeSpaceActionActive(commandID: readiness.commandID) else { return }
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
                guard let self, self.nativeSpaceActionActive(commandID: readiness.commandID) else {
                    return
                }
                switch outcome {
                case .failure(let error):
                    if let openOnAbsent,
                        Self.controlsAbsent(error),
                        ProcessInfo.processInfo.systemUptime < readiness.deadline,
                        liveSpaceID() == readiness.before.current
                    {
                        self.record("mission_control_ax_first", details: ["outcome": "absent"])
                        openOnAbsent()
                        return
                    }
                    self.handleNativeSpaceReadinessError(
                        error, readiness: readiness, attempts: attempts,
                        retry: openOnAbsent == nil
                            ? { [weak self] in
                                self?.discoverAndPressNativeSpace(
                                    readiness, launchError: nil, attempts: attempts + 1,
                                    discover: discover, revalidate: revalidate, press: press,
                                    liveSpaceID: liveSpaceID)
                            } : nil)
                case .success(let discovery):
                    self.completeDiscoveredNativeSpace(
                        readiness, discovery: discovery, attempts: attempts,
                        revalidate: revalidate, press: press, liveSpaceID: liveSpaceID)
                }
            }
        }
    }
}
