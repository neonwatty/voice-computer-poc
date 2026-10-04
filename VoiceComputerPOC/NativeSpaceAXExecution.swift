import AppKit
import ApplicationServices
enum NativeSpaceAXExecution {
    static func discover(number: Int, expectedCount: Int, deadline: TimeInterval) throws
        -> MissionControlAXDiscovery
    {
        if source(forMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
            == .windowManager
        {
            return try WindowManagerAXExecution.discover(
                number: number, expectedCount: expectedCount, deadline: deadline)
        }
        return try discoverDock(number: number, expectedCount: expectedCount, deadline: deadline)
    }
    static func source(forMajorVersion majorVersion: Int) -> MissionControlAXSource {
        majorVersion >= 27 ? .windowManager : .dock
    }
    private static func discoverDock(number: Int, expectedCount: Int, deadline: TimeInterval) throws
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
        if discovery.source == .windowManager {
            try WindowManagerAXExecution.revalidate(
                discovery, number: number, expectedCount: expectedCount)
            return
        }
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
