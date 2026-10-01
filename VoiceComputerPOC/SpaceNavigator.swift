import AppKit
import ApplicationServices
import CoreFoundation
import Darwin
import Foundation

enum SpaceDirection: String {
    case left
    case right

    init?(phrase: String) {
        switch Self.normalizedPhrase(phrase) {
        case "switch to the previous desktop space", "switch one desktop space to the left":
            self = .left
        case "switch to the next desktop space", "switch one desktop space to the right":
            self = .right
        default:
            return nil
        }
    }

    static func normalizedPhrase(_ phrase: String) -> String {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

enum SpaceCommand: Equatable {
    case one(SpaceDirection)
    case rightThenLeft

    init?(phrase: String) {
        let normalized = SpaceDirection.normalizedPhrase(phrase)
        if normalized == "switch one desktop space right and then back left" {
            self = .rightThenLeft
        } else if let direction = SpaceDirection(phrase: normalized) {
            self = .one(direction)
        } else {
            return nil
        }
    }

    var directions: [SpaceDirection] {
        switch self {
        case .one(let direction): return [direction]
        case .rightThenLeft: return [.right, .left]
        }
    }
}

struct SpaceSnapshot: Equatable {
    let current: Int
    let ordered: [Int]

    func adjacent(_ direction: SpaceDirection) -> Int? {
        guard let index = ordered.firstIndex(of: current) else { return nil }
        let target = index + (direction == .right ? 1 : -1)
        return ordered.indices.contains(target) ? ordered[target] : nil
    }
}

enum SpaceNavigator {
    static func snapshot() -> SpaceSnapshot? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["export", "com.apple.spaces", "-"]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            guard task.terminationStatus == 0,
                let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
                    as? [String: Any],
                let configuration = plist["SpacesDisplayConfiguration"] as? [String: Any],
                let management = configuration["Management Data"] as? [String: Any],
                let monitors = management["Monitors"] as? [[String: Any]],
                let current = liveSpaceID()
            else { return nil }
            return parseMonitors(monitors, current: current)
        } catch {
            return nil
        }
    }

    static func parseMonitors(_ monitors: [[String: Any]], current: Int) -> SpaceSnapshot? {
        guard current > 0 else { return nil }
        var identifiers = Set<String>()
        var mainIDs: [Int]?
        for monitor in monitors {
            guard let identifier = monitor["Display Identifier"] as? String,
                !identifier.isEmpty, identifiers.insert(identifier).inserted,
                let spaces = monitor["Spaces"] as? [[String: Any]]
            else { return nil }
            if identifier != "Main" {
                guard spaces.isEmpty else { return nil }
                continue
            }
            guard mainIDs == nil, !spaces.isEmpty else { return nil }
            var ordered: [Int] = []
            var seen = Set<Int>()
            for space in spaces {
                guard let number = space["id64"] as? NSNumber,
                    CFGetTypeID(number) != CFBooleanGetTypeID(),
                    ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
                        .contains(String(cString: number.objCType)),
                    number.int64Value > 0,
                    let id = Int(exactly: number.int64Value), seen.insert(id).inserted
                else { return nil }
                ordered.append(id)
            }
            mainIDs = ordered
        }
        guard let mainIDs, mainIDs.contains(current) else { return nil }
        return SpaceSnapshot(current: current, ordered: mainIDs)
    }

    // com.apple.spaces can retain a stale Current Space; this prototype reads the live ID.
    // SkyLight is private API, so distribution needs a supported verification strategy.
    static func liveSpaceID() -> Int? {
        guard
            let library = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        else { return nil }
        defer { dlclose(library) }
        guard let connectionSymbol = dlsym(library, "_CGSDefaultConnection"),
            let spaceSymbol = dlsym(library, "CGSGetActiveSpace")
        else { return nil }
        typealias Connection = @convention(c) () -> UInt32
        typealias ActiveSpace = @convention(c) (UInt32) -> UInt64
        let connection = unsafeBitCast(connectionSymbol, to: Connection.self)()
        let space = unsafeBitCast(spaceSymbol, to: ActiveSpace.self)(connection)
        return Int(exactly: space)
    }

}

struct MissionControlAXNode {
    let path: String
    let role: String
    let title: String
    let description: String
    let actions: String
}

enum MissionControlAXError: LocalizedError {
    case permissionRequired
    case dockUnavailable
    case desktopNotFound
    case pressFailed(AXError)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Voice Computer POC needs Accessibility permission to select a desktop."
        case .dockUnavailable:
            return "The macOS Dock process is unavailable."
        case .desktopNotFound:
            return "Mission Control did not expose the expected desktop controls."
        case .pressFailed(let error):
            return "Mission Control did not accept the desktop press (\(error.rawValue))."
        }
    }
}

enum MissionControlAXProbe {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func pressDesktop(number: Int, expectedCount: Int) throws {
        guard isTrusted else { throw MissionControlAXError.permissionRequired }
        guard
            let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first
        else { throw MissionControlAXError.dockUnavailable }

        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var queue = [root]
        var visited = 0
        while !queue.isEmpty && visited < 120 {
            let element = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.5)
            let childElements = children(of: element)
            if string(element, attribute: kAXRoleAttribute) == kAXListRole as String {
                let desktops = childElements.filter {
                    string($0, attribute: kAXRoleAttribute) == kAXButtonRole as String
                        && string($0, attribute: kAXTitleAttribute).hasPrefix("Desktop ")
                }
                let expectedTitles = Set((1...expectedCount).map { "Desktop \($0)" })
                let actualTitles = Set(desktops.map { string($0, attribute: kAXTitleAttribute) })
                if desktops.count == expectedCount && actualTitles == expectedTitles,
                    let target = desktops.first(where: {
                        string($0, attribute: kAXTitleAttribute) == "Desktop \(number)"
                            && string($0, attribute: kAXDescriptionAttribute)
                                == "exit to Desktop \(number)"
                    })
                {
                    let result = AXUIElementPerformAction(target, kAXPressAction as CFString)
                    guard result == .success else { throw MissionControlAXError.pressFailed(result) }
                    return
                }
            }
            queue.append(contentsOf: childElements)
        }
        throw MissionControlAXError.desktopNotFound
    }

    static func inspectDock(limit: Int = 120) -> (
        trusted: Bool, dockFound: Bool, nodes: [MissionControlAXNode]
    ) {
        let trusted = AXIsProcessTrusted()
        guard trusted,
            let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first
        else { return (trusted, false, []) }

        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var queue: [(element: AXUIElement, path: String)] = [(root, "root")]
        var nodes: [MissionControlAXNode] = []
        while !queue.isEmpty && nodes.count < limit {
            let item = queue.removeFirst()
            AXUIElementSetMessagingTimeout(item.element, 0.5)
            var actionValue: CFArray?
            let actionStatus = AXUIElementCopyActionNames(item.element, &actionValue)
            let actions =
                actionStatus == .success ? (actionValue as? [String] ?? []).joined(separator: ",") : ""
            nodes.append(
                MissionControlAXNode(
                    path: item.path,
                    role: string(item.element, attribute: kAXRoleAttribute),
                    title: string(item.element, attribute: kAXTitleAttribute),
                    description: string(item.element, attribute: kAXDescriptionAttribute),
                    actions: actions))
            for (index, child) in children(of: item.element).enumerated() {
                queue.append((child, "\(item.path).\(index)"))
            }
        }
        return (trusted, true, nodes)
    }

    private static func string(_ element: AXUIElement, attribute: String) -> String {
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
