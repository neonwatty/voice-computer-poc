import AppKit
import ApplicationServices

enum WindowManagerAXProbe {
    static func inspect(limit: Int = 120) -> (
        found: Bool, lists: Int, nodes: [MissionControlAXNode],
        visited: Int, limitReached: Bool
    ) {
        guard
            let process = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.WindowManager"
            ).first
        else { return (false, 0, [], 0, false) }
        var queue = [AXUIElementCreateApplication(process.processIdentifier)]
        var visited = 0
        var lists = 0
        var nodes: [MissionControlAXNode] = []
        while !queue.isEmpty && visited < limit {
            let element = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            let children = children(of: element)
            if string(element, kAXIdentifierAttribute) == "mc.spaces.list"
                && string(element, kAXRoleAttribute) == kAXListRole as String
            {
                lists += 1
                for child in children where string(child, kAXRoleAttribute) == kAXButtonRole as String {
                    let title = string(child, kAXTitleAttribute)
                    guard title.hasPrefix("Desktop ") else { continue }
                    var actions: CFArray?
                    let status = AXUIElementCopyActionNames(child, &actions)
                    nodes.append(
                        MissionControlAXNode(
                            title: title,
                            description: string(child, kAXDescriptionAttribute),
                            actions: status == .success
                                ? (actions as? [String] ?? []).joined(separator: ",") : ""))
                }
            }
            queue.append(contentsOf: children)
        }
        return (true, lists, nodes, visited, !queue.isEmpty)
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
