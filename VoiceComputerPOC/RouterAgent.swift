import Foundation

enum RouterAgent {
    private static func resource(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("evals/\(name)")
    }

    static var instruction: String? {
        try? String(contentsOf: resource("router-instruction.txt"), encoding: .utf8)
    }

    static var isolatedArguments: [String]? {
        guard let data = try? Data(contentsOf: resource("router-cli-args.json")) else { return nil }
        return try? JSONDecoder().decode([String].self, from: data)
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
        guard let instruction, let isolatedArguments, let executable = executable() else {
            completion(nil)
            return
        }
        let schema = resource("router-output.schema.json")
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
            isolatedArguments + [
                "--output-schema", schema.path, "--output-last-message", answer.path, "-",
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
            let payload = "\(instruction)\nRequest: \(String(reflecting: phrase))\n"
            try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            try input.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            try? FileManager.default.removeItem(at: directory)
            completion(nil)
        }
    }
}
