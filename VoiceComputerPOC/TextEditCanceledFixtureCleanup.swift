import AppKit
import ApplicationServices
import Foundation

#if DEBUG
    enum TextEditCanceledFixtureCleanup {
        static func discard(noteURL: URL) -> Bool {
            let runID = noteURL.deletingLastPathComponent().lastPathComponent
            let expected = "Voice Computer saved \(runID)"
            guard runID.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
                !FileManager.default.fileExists(atPath: noteURL.path),
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
                    .count == 1,
                let process = NSRunningApplication.runningApplications(
                    withBundleIdentifier: "com.apple.TextEdit"
                ).first
            else { return false }
            let app = AXUIElementCreateApplication(process.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 0.5)
            guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
                return false
            }
            let untitled = windows.filter {
                (attribute($0, kAXTitleAttribute) as? String) == "Untitled"
            }
            let onlyAllowedWindows = windows.allSatisfy {
                ["Untitled", "Open"].contains(
                    (attribute($0, kAXTitleAttribute) as? String) ?? "")
            }
            guard untitled.count == 1, onlyAllowedWindows,
                let documentNodes = nodes(untitled[0])
            else { return false }
            let textAreas = documentNodes.filter {
                (attribute($0, kAXRoleAttribute) as? String) == "AXTextArea"
            }
            guard textAreas.count == 1,
                (attribute(textAreas[0], kAXValueAttribute) as? String) == expected,
                let close = attribute(untitled[0], kAXCloseButtonAttribute),
                CFGetTypeID(close) == AXUIElementGetTypeID(),
                AXUIElementPerformAction(
                    unsafeDowncast(close, to: AXUIElement.self), kAXPressAction as CFString)
                    == .success
            else { return false }
            guard let delete = waitForDeleteButton(app),
                AXUIElementPerformAction(delete, kAXPressAction as CFString) == .success
            else { return false }
            Thread.sleep(forTimeInterval: 0.15)
            if let remaining = attribute(app, kAXWindowsAttribute) as? [AXUIElement] {
                let open = remaining.filter {
                    (attribute($0, kAXTitleAttribute) as? String) == "Open"
                }
                if open.count == 1, remaining.count == 1,
                    let openNodes = nodes(open[0], limit: 2_000)
                {
                    let cancel = openNodes.filter {
                        (attribute($0, kAXRoleAttribute) as? String) == "AXButton"
                            && (attribute($0, kAXTitleAttribute) as? String) == "Cancel"
                    }
                    if cancel.count == 1 {
                        _ = AXUIElementPerformAction(cancel[0], kAXPressAction as CFString)
                    }
                }
            }
            guard let finalWindows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
                return false
            }
            return !FileManager.default.fileExists(atPath: noteURL.path) && finalWindows.isEmpty
        }

        private static func waitForDeleteButton(_ app: AXUIElement) -> AXUIElement? {
            for _ in 0..<12 {
                var roots = (attribute(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
                if let focused = attribute(app, kAXFocusedWindowAttribute),
                    CFGetTypeID(focused) == AXUIElementGetTypeID()
                {
                    roots.insert(unsafeDowncast(focused, to: AXUIElement.self), at: 0)
                }
                for root in roots {
                    guard let all = nodes(root) else { continue }
                    let buttons = all.filter {
                        (attribute($0, kAXRoleAttribute) as? String) == "AXButton"
                            && (attribute($0, kAXTitleAttribute) as? String) == "Delete"
                    }
                    if buttons.count == 1 { return buttons[0] }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return nil
        }

        private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
                return nil
            }
            return value
        }

        private static func nodes(_ root: AXUIElement, limit: Int = 300) -> [AXUIElement]? {
            var queue = [root]
            var output: [AXUIElement] = []
            while !queue.isEmpty {
                guard output.count < limit else { return nil }
                let current = queue.removeFirst()
                output.append(current)
                if let children = attribute(current, kAXChildrenAttribute) as? [AXUIElement] {
                    queue.append(contentsOf: children)
                }
            }
            return output
        }
    }
#endif
