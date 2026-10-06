import Foundation

enum RouterAgent {
    struct Resources {
        let instruction: String
        let arguments: [String]
        let schema: URL
    }

    static let requiredArguments = [
        "exec", "--ignore-user-config", "--ignore-rules", "--ephemeral",
        "--skip-git-repo-check", "--sandbox", "read-only", "--disable", "shell_tool",
        "--disable", "plugins", "--disable", "multi_agent", "-c",
        "apps._default.enabled=false", "--json",
    ]

    static func loadResources(from directory: URL?) -> Resources? {
        guard let directory,
            let instruction = try? String(
                contentsOf: directory.appendingPathComponent("router-instruction.txt"), encoding: .utf8),
            !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let argumentsData = try? Data(
                contentsOf: directory.appendingPathComponent("router-cli-args.json")),
            let arguments = try? JSONDecoder().decode([String].self, from: argumentsData),
            arguments == requiredArguments
        else { return nil }
        let schema = directory.appendingPathComponent("router-output.schema.json")
        guard let schemaData = try? Data(contentsOf: schema), validSchema(schemaData) else {
            return nil
        }
        return Resources(instruction: instruction, arguments: arguments, schema: schema)
    }

    private static func validSchema(_ data: Data) -> Bool {
        guard let actual = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let expected: [String: Any] = [
            "type": "object", "additionalProperties": false,
            "required": ["route", "directions", "target"],
            "properties": [
                "route": [
                    "type": "string",
                    "enum": [
                        "space", "computer_use", "browser", "finder", "textedit",
                        "browser_finder", "clarification",
                    ],
                ],
                "directions": [
                    "type": "array", "items": ["type": "string", "enum": ["left", "right"]],
                ],
                "target": [
                    "type": "string",
                    "enum": [
                        "", "calculator", "local_docs", "local_form", "fixture_report",
                        "fixture_note", "fixture_new_note", "local_docs_fixture_report",
                    ],
                ],
            ],
        ]
        return NSDictionary(dictionary: actual).isEqual(to: expected)
    }

    static func toolFreeTrace(_ data: Data) -> Bool {
        guard let lines = String(data: data, encoding: .utf8)?.split(separator: "\n") else {
            return false
        }
        var completed = false
        for line in lines {
            guard
                let event = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any], let type = event["type"] as? String
            else { return false }
            if type == "turn.completed" { completed = true }
            if type.hasPrefix("item.") {
                guard let item = event["item"] as? [String: Any],
                    let kind = item["type"] as? String,
                    kind == "agent_message" || kind == "reasoning"
                else { return false }
            }
        }
        return completed
    }

    private static func executable() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    static func classify(_ phrase: String, completion: @escaping (Data?) -> Void) {
        classify(phrase, resourceDirectory: Bundle.main.resourceURL, completion: completion)
    }

    static func classify(
        _ phrase: String, resourceDirectory: URL?, completion: @escaping (Data?) -> Void
    ) {
        guard let resources = loadResources(from: resourceDirectory), let executable = executable()
        else {
            completion(nil)
            return
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-router-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) } catch
        {
            completion(nil)
            return
        }
        let answer = directory.appendingPathComponent("answer.json")
        let trace = directory.appendingPathComponent("trace.jsonl")
        FileManager.default.createFile(atPath: trace.path, contents: nil)
        guard let traceHandle = try? FileHandle(forWritingTo: trace) else {
            try? FileManager.default.removeItem(at: directory)
            completion(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments =
            resources.arguments + [
                "--output-schema", resources.schema.path, "--output-last-message", answer.path, "-",
            ]
        process.currentDirectoryURL = directory
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = traceHandle
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { ended in
            try? traceHandle.close()
            let data = try? Data(contentsOf: answer)
            let traceData = try? Data(contentsOf: trace)
            let output =
                ended.terminationStatus == 0 && traceData.map(toolFreeTrace) == true
                ? data : nil
            try? FileManager.default.removeItem(at: directory)
            DispatchQueue.main.async { completion(output) }
        }
        do {
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
                if process.isRunning { process.terminate() }
            }
            let payload = "\(resources.instruction)\nRequest: \(String(reflecting: phrase))\n"
            try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
            completion(nil)
        }
    }
}
