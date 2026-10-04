import ApplicationServices
import Foundation

guard CommandLine.arguments.count == 2,
    let pid = pid_t(CommandLine.arguments[1]), pid > 0,
    AXIsProcessTrusted()
else {
    fputs("Stop helper requires a PID and Accessibility trust\n", stderr)
    exit(2)
}

let app = AXUIElementCreateApplication(pid)
var visited = 0
var sawStop = false

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

func pressStop(_ element: AXUIElement) -> Bool {
    visited += 1
    guard visited <= 400 else { return false }
    let role = attribute(element, kAXRoleAttribute) as? String
    let title = attribute(element, kAXTitleAttribute) as? String
    let description = attribute(element, kAXDescriptionAttribute) as? String
    if role == (kAXButtonRole as String), title == "Stop" || description == "Stop" {
        sawStop = true
        let enabled = attribute(element, kAXEnabledAttribute) as? Bool ?? false
        return enabled && AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }
    guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
        return false
    }
    for child in children where pressStop(child) { return true }
    return false
}

let deadline = Date().addingTimeInterval(8)
repeat {
    visited = 0
    let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
    if windows.contains(where: pressStop) {
        print("pressed_stop")
        exit(0)
    }
    Thread.sleep(forTimeInterval: 0.1)
} while Date() < deadline

fputs(sawStop ? "Stop button stayed disabled\n" : "Stop button was not found\n", stderr)
exit(1)
