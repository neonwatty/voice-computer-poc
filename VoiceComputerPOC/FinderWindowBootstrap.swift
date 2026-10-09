import AppKit
import ApplicationServices
import Foundation

/// Opens only the parent of a validated fixture report when Finder has no window.
enum FinderWindowBootstrap {
    enum Outcome: Equatable {
        case existingWindow
        case openedWindow
        case unavailable
    }

    static func prepare(reportURL: URL) -> Outcome {
        let phrase = "Reveal the test report at \(reportURL.path) in Finder."
        guard RouteSafety.finderFixtureURL(in: phrase) == reportURL.standardizedFileURL,
            let count = windowCount()
        else { return .unavailable }
        if count > 0 { return .existingWindow }
        return NSWorkspace.shared.open(reportURL.deletingLastPathComponent())
            ? .openedWindow : .unavailable
    }

    static func windowCount() -> Int? {
        guard AXIsProcessTrusted() else { return nil }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
        if apps.isEmpty { return 0 }
        guard apps.count == 1 else { return nil }
        let root = AXUIElementCreateApplication(apps[0].processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return nil }
        var subroles: [String?] = []
        for window in windows {
            var subrole: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(
                    window, kAXSubroleAttribute as CFString, &subrole) == .success,
                let name = subrole as? String
            else { return nil }
            subroles.append(name)
        }
        return fileWindowCount(subroles: subroles)
    }

    static func fileWindowCount(subroles: [String?]) -> Int? {
        var count = 0
        for subrole in subroles {
            if subrole == "AXDesktop" { continue }
            guard subrole == "AXStandardWindow" else { return nil }
            count += 1
        }
        return count
    }
}
