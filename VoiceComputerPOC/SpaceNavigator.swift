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
        default: return nil
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
                !identifier.isEmpty, identifiers.insert(identifier).inserted
            else { return nil }
            if identifier != "Main" {
                if let spaces = monitor["Spaces"] as? [[String: Any]] {
                    guard spaces.isEmpty else { return nil }
                } else {
                    guard monitor["Spaces"] == nil,
                        isCollapsedStaleMonitor(monitor, identifier: identifier)
                    else { return nil }
                }
                continue
            }
            guard let spaces = monitor["Spaces"] as? [[String: Any]] else { return nil }
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
    private static func isCollapsedStaleMonitor(
        _ monitor: [String: Any], identifier: String
    ) -> Bool {
        guard UUID(uuidString: identifier) != nil,
            Set(monitor.keys) == ["Display Identifier", "Collapsed Space"],
            let collapsed = monitor["Collapsed Space"] as? [String: Any],
            Set(collapsed.keys).subtracting(["AutoCreated"])
                == ["ManagedSpaceID", "id64", "type", "uuid"],
            let managed = collapsed["ManagedSpaceID"] as? NSNumber,
            let id = collapsed["id64"] as? NSNumber,
            let type = collapsed["type"] as? NSNumber,
            CFGetTypeID(managed) != CFBooleanGetTypeID(),
            CFGetTypeID(id) != CFBooleanGetTypeID(),
            CFGetTypeID(type) != CFBooleanGetTypeID(),
            [managed, id, type].allSatisfy({
                ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"]
                    .contains(String(cString: $0.objCType))
            }),
            managed.int64Value > 0, managed == id, type.int64Value == 0,
            let uuid = collapsed["uuid"] as? String, UUID(uuidString: uuid) != nil
        else { return false }
        if let autoCreated = collapsed["AutoCreated"] {
            guard let value = autoCreated as? NSNumber,
                CFGetTypeID(value) == CFBooleanGetTypeID()
            else { return false }
        }
        return true
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
    let title: String
    let description: String
    let actions: String
}
struct NativeSpaceReadiness {
    let direction: SpaceDirection
    let before: SpaceSnapshot
    let expected: Int
    let baseline: Int
    let targetNumber: Int
    let remaining: [SpaceDirection]
    let roundTripOrigin: Int?
    let commandID: String?
    let deadline: TimeInterval
    let pressGate = NativeSpacePressGate()
}
final class NativeSpacePressGate {
    private(set) var attempted = false
    func claim() -> Bool {
        guard !attempted else { return false }
        attempted = true
        return true
    }
}
enum MissionControlAXError: LocalizedError {
    case permissionRequired
    case dockUnavailable
    case desktopNotFound(String)
    case scanUnavailable(String, Int, Int)
    case pressFailed(AXError)
    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return "Voice Computer POC needs Accessibility permission to select a desktop."
        case .dockUnavailable: return "The macOS Dock process is unavailable."
        case .desktopNotFound, .scanUnavailable:
            return "Mission Control did not expose the expected desktop controls."
        case .pressFailed(let error):
            return "Mission Control did not accept the desktop press (\(error.rawValue))."
        }
    }
}
enum MissionControlAXProbe {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    static func inspectDock(limit: Int = 120) -> (
        trusted: Bool, dockFound: Bool, nodes: [MissionControlAXNode],
        visited: Int, limitReached: Bool
    ) {
        guard AXIsProcessTrusted() else { return (false, false, [], 0, false) }
        guard
            let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
                .first
        else { return (true, false, [], 0, false) }
        var queue = [AXUIElementCreateApplication(dock.processIdentifier)]
        var nodes: [MissionControlAXNode] = []
        var visited = 0
        while !queue.isEmpty && visited < limit {
            let element = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(element, 0.1)
            let title = string(element, attribute: kAXTitleAttribute)
            if title.hasPrefix("Desktop ") {
                var actionValue: CFArray?
                let status = AXUIElementCopyActionNames(element, &actionValue)
                nodes.append(
                    MissionControlAXNode(
                        title: title, description: string(element, attribute: kAXDescriptionAttribute),
                        actions: status == .success
                            ? (actionValue as? [String] ?? []).joined(separator: ",") : ""))
            }
            queue.append(contentsOf: children(of: element))
        }
        return (true, true, nodes, visited, !queue.isEmpty)
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
