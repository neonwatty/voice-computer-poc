import CoreGraphics
import Foundation

enum SpaceDirection: String {
    case left
    case right

    init?(phrase: String) {
        switch phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "switch to the previous desktop space", "switch one desktop space to the left":
            self = .left
        case "switch to the next desktop space", "switch one desktop space to the right":
            self = .right
        default:
            return nil
        }
    }
}

enum SpaceCommand: Equatable {
    case one(SpaceDirection)
    case rightThenLeft

    init?(phrase: String) {
        let normalized = phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

enum SpaceNavigatorError: LocalizedError {
    case permissionRequired
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            return
                "macOS needs permission to post keyboard events. Enable Voice Computer POC in System Settings → Privacy & Security → Accessibility, then retry."
        case .eventCreationFailed:
            return "macOS could not create the native Space shortcut events."
        }
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
                let main = monitors.first(where: { $0["Display Identifier"] as? String == "Main" }),
                let current = (main["Current Space"] as? [String: Any])?["id64"] as? Int,
                let spaces = main["Spaces"] as? [[String: Any]]
            else { return nil }
            let ordered = spaces.compactMap { $0["id64"] as? Int }
            return ordered.contains(current) ? SpaceSnapshot(current: current, ordered: ordered) : nil
        } catch {
            return nil
        }
    }

    static func post(_ direction: SpaceDirection) throws {
        guard CGPreflightPostEventAccess() || CGRequestPostEventAccess() else {
            throw SpaceNavigatorError.permissionRequired
        }
        // macOS virtual key codes: Control = 59, Left Arrow = 123, Right Arrow = 124.
        let arrow: CGKeyCode = direction == .right ? 124 : 123
        let source = CGEventSource(stateID: .hidSystemState)
        guard let controlDown = CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: true),
            let arrowDown = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: true),
            let arrowUp = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: false),
            let controlUp = CGEvent(keyboardEventSource: source, virtualKey: 59, keyDown: false)
        else { throw SpaceNavigatorError.eventCreationFailed }
        controlDown.flags = .maskControl
        arrowDown.flags = .maskControl
        arrowUp.flags = .maskControl
        for event in [controlDown, arrowDown, arrowUp, controlUp] {
            event.post(tap: .cghidEventTap)
        }
    }
}
