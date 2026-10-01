import Foundation

struct SpaceToolRequest: Codable {
    let sessionID: String
    let direction: String

    static func direction(for phrase: String) -> SpaceDirection? {
        switch phrase.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "agent switch desktop space left": return .left
        case "agent switch desktop space right": return .right
        default: return nil
        }
    }

    static func direction(fromArguments value: Any?) -> SpaceDirection? {
        let object: [String: Any]?
        if let dictionary = value as? [String: Any] {
            object = dictionary
        } else if let text = value as? String,
            let data = text.data(using: .utf8)
        {
            object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        } else {
            object = nil
        }
        guard let object, object.count == 1,
            let direction = object["direction"] as? String
        else { return nil }
        return SpaceDirection(rawValue: direction)
    }
}

struct SpaceToolResult: Codable, Equatable {
    let commandID: String
    let status: String
    let direction: String
    let beforeID: Int?
    let expectedID: Int?
    let afterID: Int?
    let notificationObserved: Bool
    let message: String

    var verified: Bool {
        status == "verified" && expectedID != nil && afterID == expectedID
            && notificationObserved
    }

    static func failure(_ status: String, commandID: String, direction: String, message: String)
        -> Self
    {
        .init(
            commandID: commandID, status: status, direction: direction, beforeID: nil,
            expectedID: nil, afterID: nil, notificationObserved: false, message: message)
    }
}

enum SpaceToolSafety {
    enum Preflight: Equatable {
        case permissionMissing
        case stateMissing
        case noAdjacentSpace
        case ready(Int)
    }

    enum Verification: Equatable {
        case pending
        case verified
        case timedOut
    }

    static func preflight(trusted: Bool, snapshot: SpaceSnapshot?, direction: SpaceDirection)
        -> Preflight
    {
        guard trusted else { return .permissionMissing }
        guard let snapshot else { return .stateMissing }
        guard let expected = snapshot.adjacent(direction) else { return .noAdjacentSpace }
        return .ready(expected)
    }

    static func verification(
        expected: Int, after: Int?, eventObserved: Bool, deadlineReached: Bool
    ) -> Verification {
        if after == expected && eventObserved { return .verified }
        return deadlineReached ? .timedOut : .pending
    }

    static func nextStep(after verification: Verification, remaining: [SpaceDirection])
        -> SpaceDirection?
    {
        verification == .verified ? remaining.first : nil
    }
}
