import AppKit
import ApplicationServices

enum WindowManagerAXExecution {
    static func discover(number: Int, expectedCount: Int, deadline: TimeInterval) throws
        -> MissionControlAXDiscovery
    {
        guard MissionControlAXProbe.isTrusted else { throw MissionControlAXError.permissionRequired }
        guard
            let manager = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.WindowManager"
            ).first
        else { throw MissionControlAXError.scanUnavailable("missing_controls", 0, 0) }
        var queue = [AXUIElementCreateApplication(manager.processIdentifier)]
        var visited = 0
        var largestCount = 0
        var listCount = 0
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
            if isSpacesList(element) {
                listCount += 1
                let desktops = desktopButtons(children)
                largestCount = max(largestCount, desktops.count)
                if exactControls(desktops, expectedCount: expectedCount),
                    let target = desktops.first(where: {
                        string($0, kAXTitleAttribute) == "Desktop \(number)"
                    })
                {
                    if candidate != nil { malformed = true }
                    candidate = .init(list: element, target: target, source: .windowManager)
                } else if !desktops.isEmpty {
                    malformed = true
                }
            }
            queue.append(contentsOf: children)
        }
        guard queue.isEmpty else {
            throw MissionControlAXError.scanUnavailable("readiness_timeout", largestCount, visited)
        }
        if !malformed, listCount == 1, let candidate { return candidate }
        let reason =
            listCount > 1
            ? "mismatched_controls"
            : largestCount == 0
                ? "missing_controls"
                : largestCount < expectedCount ? "incomplete_controls" : "mismatched_controls"
        throw MissionControlAXError.scanUnavailable(reason, largestCount, visited)
    }

    static func revalidate(
        _ discovery: MissionControlAXDiscovery, number: Int, expectedCount: Int
    ) throws {
        guard MissionControlAXProbe.isTrusted else { throw MissionControlAXError.permissionRequired }
        let desktops = desktopButtons(children(of: discovery.list))
        guard discovery.source == .windowManager, isSpacesList(discovery.list),
            exactControls(desktops, expectedCount: expectedCount),
            desktops.contains(where: { CFEqual($0, discovery.target) }),
            string(discovery.target, kAXTitleAttribute) == "Desktop \(number)"
        else { throw MissionControlAXError.desktopNotFound("stale_controls") }
    }

    private static func isSpacesList(_ element: AXUIElement) -> Bool {
        string(element, kAXRoleAttribute) == kAXListRole as String
            && string(element, kAXIdentifierAttribute) == "mc.spaces.list"
    }

    private static func exactControls(_ desktops: [AXUIElement], expectedCount: Int) -> Bool {
        guard expectedCount > 0, desktops.count == expectedCount else { return false }
        let titles = Set(desktops.map { string($0, kAXTitleAttribute) })
        guard titles == Set((1...expectedCount).map { "Desktop \($0)" }) else { return false }
        return desktops.allSatisfy { element in
            let title = string(element, kAXTitleAttribute)
            var actions: CFArray?
            return string(element, kAXDescriptionAttribute) == "exit to \(title)"
                && AXUIElementCopyActionNames(element, &actions) == .success
                && (actions as? [String] ?? []).contains(kAXPressAction as String)
        }
    }

    private static func desktopButtons(_ children: [AXUIElement]) -> [AXUIElement] {
        children.filter {
            AXUIElementSetMessagingTimeout($0, 0.1)
            return string($0, kAXRoleAttribute) == kAXButtonRole as String
                && string($0, kAXTitleAttribute).hasPrefix("Desktop ")
        }
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
