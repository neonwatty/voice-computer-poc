import Foundation

enum CommandRoute: Equatable {
    case space([SpaceDirection])
    case computerUse(String)
    case clarification

    static func parse(_ data: Data, originalPhrase: String) -> Self? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(object.keys) == Set(["route", "directions", "target"]),
            let route = object["route"] as? String,
            let directions = object["directions"] as? [String],
            let target = object["target"] as? String
        else { return nil }
        switch route {
        case "space":
            let parsed = directions.compactMap(SpaceDirection.init(rawValue:))
            guard target.isEmpty, (1...2).contains(directions.count),
                parsed.count == directions.count,
                parsed.count == 1 || parsed == [.right, .left]
            else { return nil }
            guard RouteSafety.permits(.space(parsed), phrase: originalPhrase) else { return nil }
            return .space(parsed)
        case "computer_use":
            guard directions.isEmpty, target == "calculator",
                originalPhrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased().contains("calculator")
            else { return nil }
            guard RouteSafety.permits(.computerUse("calculator"), phrase: originalPhrase) else {
                return nil
            }
            return .computerUse("calculator")
        case "clarification":
            guard directions.isEmpty, target.isEmpty else { return nil }
            return .clarification
        default:
            return nil
        }
    }

}

enum RouteHandoff: Equatable {
    case invalid
    case clarification
    case space(SpaceDirection, remaining: [SpaceDirection])
    case calculator

    static func decide(_ data: Data?, phrase: String) -> Self {
        guard let data, let route = CommandRoute.parse(data, originalPhrase: phrase) else {
            return .invalid
        }
        switch route {
        case .clarification: return .clarification
        case .space(let directions):
            return .space(directions[0], remaining: Array(directions.dropFirst()))
        case .computerUse: return .calculator
        }
    }
}

enum RouteSafety {
    static func permits(_ route: CommandRoute, phrase: String) -> Bool {
        let lowercase = phrase.lowercased()
        let tokens = lowercase.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let words = Set(tokens)
        let space = !words.isDisjoint(with: ["space", "spaces", "desktop", "desktops"])
        let uncertain = !words.isDisjoint(with: [
            "or", "either", "maybe", "perhaps", "whichever",
            "unsure", "uncertain", "probably",
        ])
        let negated =
            !words.isDisjoint(with: [
                "not", "never", "no", "dont", "without", "avoid",
                "except", "cannot",
            ])
            || lowercase.contains("n't") || lowercase.contains("don’t")
        let multipleSteps = !words.isDisjoint(with: ["two", "three", "twice", "thrice", "2", "3"])
        let cues = tokens.enumerated().compactMap { index, token -> (Int, SpaceDirection)? in
            if ["left", "previous", "prior"].contains(token) { return (index, .left) }
            if ["right", "next"].contains(token) { return (index, .right) }
            return nil
        }
        switch route {
        case .space(let directions):
            guard space, !words.contains("calculator"), !multipleSteps, !uncertain, !negated
            else { return false }
            if directions.count == 1 {
                return cues.count == 1 && cues[0].1 == directions[0]
            }
            guard directions == [.right, .left], cues.count == 2,
                cues[0].1 == .right, cues[1].1 == .left
            else { return false }
            let between = tokens[(cues[0].0 + 1)..<cues[1].0]
            return between.contains("then") || between.contains("back")
        case .computerUse:
            return words.contains("calculator") && !space && !uncertain && !negated
                && !words.contains("and")
                && words.isDisjoint(with: ["close", "quit", "delete", "remove", "clear"])
                && !words.isDisjoint(with: ["open", "launch", "bring", "show", "start", "need"])
        case .clarification:
            return true
        }
    }
}
