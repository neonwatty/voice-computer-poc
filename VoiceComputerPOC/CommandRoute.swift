import Foundation

enum CommandRoute: Equatable {
    case space([SpaceDirection])
    case computerUse(String)
    case browserDocs(URL)
    case browserForm(URL, String)
    case finderReveal(URL)
    case textEditSave(URL)
    case browserThenFinder(URL, URL)
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
        case "browser":
            return parseBrowser(target: target, directions: directions, phrase: originalPhrase)
        case "finder":
            guard directions.isEmpty, target == "fixture_report",
                let url = RouteSafety.finderFixtureURL(in: originalPhrase)
            else { return nil }
            return .finderReveal(url)
        case "textedit":
            guard directions.isEmpty, target == "fixture_note",
                let url = RouteSafety.textEditFixtureURL(in: originalPhrase)
            else { return nil }
            return .textEditSave(url)
        case "browser_finder":
            guard directions.isEmpty, target == "local_docs_fixture_report",
                let (home, report) = RouteSafety.browserFinderRequest(in: originalPhrase)
            else { return nil }
            return .browserThenFinder(home, report)
        case "clarification":
            guard directions.isEmpty, target.isEmpty else { return nil }
            return .clarification
        default:
            return nil
        }
    }

    private static func parseBrowser(target: String, directions: [String], phrase: String) -> Self? {
        guard directions.isEmpty else { return nil }
        if target == "local_docs", let url = RouteSafety.browserFixtureURL(in: phrase) {
            return .browserDocs(url)
        }
        if target == "local_form", let (url, query) = RouteSafety.browserFormRequest(in: phrase) {
            return .browserForm(url, query)
        }
        return nil
    }

}

enum RouteHandoff: Equatable {
    case invalid
    case clarification
    case space(SpaceDirection, remaining: [SpaceDirection])
    case calculator
    case browserDocs(URL)
    case browserForm(URL, String)
    case finderReveal(URL)
    case textEditSave(URL)
    case browserThenFinder(URL, URL)

    static func decide(_ data: Data?, phrase: String) -> Self {
        guard let data, let route = CommandRoute.parse(data, originalPhrase: phrase) else {
            return .invalid
        }
        switch route {
        case .clarification: return .clarification
        case .space(let directions):
            return .space(directions[0], remaining: Array(directions.dropFirst()))
        case .computerUse: return .calculator
        case .browserDocs(let url): return .browserDocs(url)
        case .browserForm(let url, let query): return .browserForm(url, query)
        case .finderReveal(let url): return .finderReveal(url)
        case .textEditSave(let url): return .textEditSave(url)
        case .browserThenFinder(let home, let report):
            return .browserThenFinder(home, report)
        }
    }
}

enum RouteSafety {
    static func textEditFixtureURL(in phrase: String) -> URL? {
        let prefix = "In TextEdit, replace the test note at "
        guard phrase.hasPrefix(prefix), phrase.hasSuffix(" and save it.") else { return nil }
        let marker = " with \"Voice Computer saved "
        let rest = String(phrase.dropFirst(prefix.count))
        let pieces = rest.components(separatedBy: marker)
        guard pieces.count == 2, pieces[1].hasSuffix("\" and save it.") else { return nil }
        let path = pieces[0]
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceComputerPOC/TestFixtures", isDirectory: true)
            .standardizedFileURL
        guard path.hasPrefix(root.path + "/") else { return nil }
        let parts = path.dropFirst(root.path.count + 1).split(
            separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
            String(parts[0]).range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
            parts[1] == "note.txt"
        else { return nil }
        let runID = String(parts[0])
        let url = URL(fileURLWithPath: path)
        guard url.standardizedFileURL.path == path,
            url.resolvingSymlinksInPath().standardizedFileURL.path == path,
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true, let size = values.fileSize, size <= 256,
            (try? Data(contentsOf: url)) == Data("Voice Computer draft \(runID)".utf8),
            phrase == "\(prefix)\(path)\(marker)\(runID)\" and save it."
        else { return nil }
        return url
    }

    static func browserFinderRequest(in phrase: String) -> (URL, URL)? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let separator = " and follow the Docs link, then reveal the test report at "
        guard trimmed.hasSuffix(" in Finder."),
            let range = trimmed.range(of: separator),
            trimmed[range.upperBound...].range(of: separator) == nil
        else { return nil }
        let browserPhrase =
            String(trimmed[..<range.lowerBound])
            + " and follow the Docs link."
        let finderPhrase =
            "Reveal the test report at "
            + String(trimmed[range.upperBound...])
        guard let home = browserFixtureURL(in: browserPhrase),
            let report = finderFixtureURL(in: finderPhrase),
            let runID = URLComponents(url: home, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "run_id" })?.value,
            runID == report.deletingLastPathComponent().lastPathComponent
        else { return nil }
        return (home, report)
    }

    static func finderFixtureURL(in phrase: String) -> URL? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "Reveal the test report at "
        let suffix = " in Finder."
        guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(suffix) else { return nil }
        let path = String(trimmed.dropFirst(prefix.count).dropLast(suffix.count))
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceComputerPOC/TestFixtures", isDirectory: true)
            .standardizedFileURL
        guard path.hasPrefix(root.path + "/") else { return nil }
        let relative = String(path.dropFirst(root.path.count + 1))
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
            String(parts[0]).range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
            parts[1] == "report.txt"
        else { return nil }
        let url = URL(fileURLWithPath: path)
        guard url.standardizedFileURL.path == path,
            url.resolvingSymlinksInPath().standardizedFileURL.path == path,
            (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return nil }
        return url
    }

    static func browserFixtureURL(in phrase: String) -> URL? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern =
            #"(?i)^open (http://127\.0\.0\.1:([0-9]{1,5})/home\?run_id=([A-Za-z0-9-]{8,64})) and follow the Docs link\.?$"#
        guard let match = trimmed.range(of: pattern, options: .regularExpression),
            match == trimmed.startIndex..<trimmed.endIndex
        else { return nil }
        let tokens = trimmed.split(separator: " ")
        guard tokens.count == 7,
            let url = URL(string: String(tokens[1])),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "http", components.host == "127.0.0.1",
            let port = components.port, (1...65535).contains(port),
            components.path == "/home",
            components.queryItems?.count == 1,
            components.queryItems?.first?.name == "run_id",
            components.queryItems?.first?.value?.range(
                of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil,
            components.fragment == nil, components.user == nil, components.password == nil
        else { return nil }
        return url
    }

    static func browserFormRequest(in phrase: String) -> (URL, String)? {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern =
            #"^Open http://127\.0\.0\.1:[0-9]{1,5}/docs\?run_id=[A-Za-z0-9-]{8,64} and submit query test-[A-Za-z0-9-]{8,64}\.$"#
        guard let match = trimmed.range(of: pattern, options: .regularExpression),
            match == trimmed.startIndex..<trimmed.endIndex
        else { return nil }
        let tokens = trimmed.split(separator: " ")
        guard tokens.count == 6,
            let url = URL(string: String(tokens[1])),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme == "http", components.host == "127.0.0.1",
            let port = components.port, (1...65535).contains(port),
            components.path == "/docs", components.queryItems?.count == 1,
            components.queryItems?.first?.name == "run_id",
            let runID = components.queryItems?.first?.value,
            runID.range(of: #"^[A-Za-z0-9-]{8,64}$"#, options: .regularExpression) != nil,
            components.fragment == nil, components.user == nil, components.password == nil
        else { return nil }
        let query = String(tokens[5].dropLast())
        guard query == "test-\(runID)" else { return nil }
        return (url, query)
    }

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
        case .browserDocs(let url):
            return browserFixtureURL(in: phrase) == url
        case .browserForm(let url, let query):
            guard let request = browserFormRequest(in: phrase) else { return false }
            return request.0 == url && request.1 == query
        case .finderReveal(let url):
            return finderFixtureURL(in: phrase) == url
        case .textEditSave(let url):
            return textEditFixtureURL(in: phrase) == url
        case .browserThenFinder(let home, let report):
            guard let request = browserFinderRequest(in: phrase) else { return false }
            return request.0 == home && request.1 == report
        case .clarification:
            return true
        }
    }
}
