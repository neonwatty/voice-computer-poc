import Foundation

extension RouteSafety {
    static func permitsTextEdit(_ route: CommandRoute, phrase: String) -> Bool {
        switch route {
        case .textEditSave(let url): return textEditFixtureURL(in: phrase) == url
        case .textEditCreate(let url): return textEditNewFixtureURL(in: phrase) == url
        default: return false
        }
    }

    static func textEditNewFixtureURL(in phrase: String) -> URL? {
        let prefix = "In TextEdit, create the test note at "
        let marker = " with \"Voice Computer saved "
        let suffix = "\" and save it."
        guard phrase.hasPrefix(prefix), phrase.hasSuffix(suffix) else { return nil }
        let rest = String(phrase.dropFirst(prefix.count))
        let pieces = rest.components(separatedBy: marker)
        guard pieces.count == 2, pieces[1].hasSuffix(suffix) else { return nil }
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
        let directory = url.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard url.standardizedFileURL.path == path,
            directory.resolvingSymlinksInPath().standardizedFileURL == directory.standardizedFileURL,
            FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue,
            !FileManager.default.fileExists(atPath: path),
            (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil,
            phrase == "\(prefix)\(path)\(marker)\(runID)\(suffix)"
        else { return nil }
        return url
    }
}
