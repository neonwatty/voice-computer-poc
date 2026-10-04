import Darwin
import Foundation

@testable import VoiceComputerPOC

struct SpaceToolBridgePythonPeerObservation {
    let pid: pid_t
    let parentPID: pid_t
    let executablePath: String
    let result: SpaceToolResult
}

enum SpaceToolBridgePythonPeerSupport {
    static func query(socketPath: String) throws -> SpaceToolBridgePythonPeerObservation {
        let (task, input, output, errors) = makeTask(socketPath: socketPath)
        try task.run()

        let capture = ChildOutputCapture()
        capture.drain(output, isError: false)
        capture.drain(errors, isError: true)
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            task.waitUntilExit()
            exited.signal()
        }
        defer {
            if task.isRunning {
                task.terminate()
                _ = exited.wait(timeout: .now() + 2)
            }
            _ = capture.waitForDrain(seconds: 2)
        }

        let pid = task.processIdentifier
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout.size(ofValue: info))
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            throw failure("child identity", task, capture, pid, nil, nil)
        }
        var path = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw failure("child executable", task, capture, pid, pid_t(info.pbi_ppid), nil)
        }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
        let parent = pid_t(info.pbi_ppid)
        func require(_ stage: String, seconds: Int) throws {
            guard capture.waitForStage(stage, seconds: seconds) else {
                throw failure(stage, task, capture, pid, parent, executable)
            }
        }
        try require("started", seconds: 12)
        try require("connected", seconds: 8)
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
        try input.fileHandleForWriting.close()
        try require("released", seconds: 5)
        try require("response", seconds: 15)

        guard exited.wait(timeout: .now() + 5) == .success else {
            throw failure("exit", task, capture, pid, parent, executable)
        }
        guard capture.waitForDrain(seconds: 2), task.terminationStatus == 0 else {
            throw failure("output drain or exit status", task, capture, pid, parent, executable)
        }
        guard
            let result = try? JSONDecoder().decode(
                SpaceToolResult.self, from: capture.stdoutData()), !capture.stdoutData().isEmpty
        else {
            throw failure("typed response", task, capture, pid, parent, executable)
        }
        return .init(pid: pid, parentPID: parent, executablePath: executable, result: result)
    }

    private static func makeTask(socketPath: String) -> (Process, Pipe, Pipe, Pipe) {
        let script = """
            import socket,sys
            def stage(name): print('stage='+name, file=sys.stderr, flush=True)
            stage('started')
            s=socket.socket(socket.AF_UNIX)
            s.settimeout(12)
            s.connect(sys.argv[1])
            stage('connected')
            sys.stdin.readline()
            stage('released')
            data=s.recv(4096)
            sys.stdout.buffer.write(data)
            sys.stdout.buffer.flush()
            stage('response')
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", script, socketPath]
        task.environment = [
            "HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
        ]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = errors
        return (task, input, output, errors)
    }

    private static func failure(
        _ stage: String, _ task: Process, _ capture: ChildOutputCapture, _ pid: pid_t,
        _ parent: pid_t?, _ executable: String?
    ) -> NSError {
        let details =
            "awaited=\(stage) pid=\(pid) parent=\(parent.map { String($0) } ?? "unknown") "
            + "path=\(executable ?? "unknown") running=\(task.isRunning) "
            + "exit=\(task.isRunning ? "pending" : String(task.terminationStatus)) "
            + capture.diagnostics()
        return NSError(
            domain: "SpaceToolBridgePythonPeer", code: 1,
            userInfo: [NSLocalizedDescriptionKey: details])
    }
}

private final class ChildOutputCapture {
    private let lock = NSLock()
    private let changed = DispatchSemaphore(value: 0)
    private let drains = DispatchGroup()
    private var stdout = Data()
    private var stderr = Data()
    private let maxBytes = 4_096

    func drain(_ pipe: Pipe, isError: Bool) {
        drains.enter()
        DispatchQueue.global().async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                self.lock.lock()
                if isError {
                    self.stderr.append(chunk.prefix(max(0, self.maxBytes - self.stderr.count)))
                } else {
                    self.stdout.append(chunk.prefix(max(0, self.maxBytes - self.stdout.count)))
                }
                self.lock.unlock()
                self.changed.signal()
            }
            self.drains.leave()
            self.changed.signal()
        }
    }

    func waitForStage(_ name: String, seconds: Int) -> Bool {
        let deadline = DispatchTime.now() + .seconds(seconds)
        while true {
            lock.lock()
            let reached = String(decoding: stderr, as: UTF8.self).contains("stage=\(name)\n")
            lock.unlock()
            if reached { return true }
            if changed.wait(timeout: deadline) == .timedOut { return false }
        }
    }

    func waitForDrain(seconds: Int) -> Bool {
        drains.wait(timeout: .now() + .seconds(seconds)) == .success
    }

    func stdoutData() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return stdout
    }

    func diagnostics() -> String {
        lock.lock()
        defer { lock.unlock() }
        let text = String(decoding: stderr, as: UTF8.self)
        let last = text.split(separator: "\n").last(where: { $0.hasPrefix("stage=") }) ?? "none"
        return "last=\(last) stdout_bytes=\(stdout.count) "
            + "stdout=\(String(decoding: stdout, as: UTF8.self).prefix(256)) "
            + "stderr_bytes=\(stderr.count) stderr=\(text.prefix(256))"
    }
}
