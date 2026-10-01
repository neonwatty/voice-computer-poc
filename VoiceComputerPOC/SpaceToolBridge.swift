import Darwin
import Foundation

final class SpaceToolBridge {
    let sessionID = UUID().uuidString
    let socketPath: String
    var serverPID: pid_t?
    private(set) var helperPID: pid_t?
    private var helperStartSecond: UInt64?
    var onRequest: ((SpaceToolRequest, @escaping (SpaceToolResult) -> Void) -> Void)?
    private let directory: URL
    private let socket: Int32
    private var running = true

    private var helperBuildDirectory: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DesktopToolServer/.build")
            .resolvingSymlinksInPath().path + "/"
    }

    init?() {
        directory = URL(fileURLWithPath: "/tmp/vc-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch { return nil }
        socketPath = directory.appendingPathComponent("bridge.sock").path
        guard let address = Self.address(for: socketPath) else { return nil }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var mutableAddress = address
        let bound = withUnsafePointer(to: &mutableAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 2) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        socket = descriptor
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        guard running else { return }
        running = false
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
        try? FileManager.default.removeItem(at: directory)
    }

    static func address(for path: String) -> sockaddr_un? {
        let characters = Array(path.utf8CString)
        var address = sockaddr_un()
        guard characters.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: characters.map(UInt8.init))
        }
        return address
    }

    private func acceptLoop() {
        while running {
            let client = Darwin.accept(socket, nil, nil)
            if client < 0 { break }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.handle(client)
            }
        }
    }

    private func isServerChild(_ peer: pid_t) -> Bool {
        guard let serverPID, peer > 0 else { return false }
        var current = peer
        for _ in 0..<8 {
            if current == serverPID { return true }
            var info = proc_bsdinfo()
            let count = proc_pidinfo(
                current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
            guard count == MemoryLayout.size(ofValue: info), info.pbi_ppid > 1 else { break }
            current = pid_t(info.pbi_ppid)
        }
        return false
    }

    private func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        return count == MemoryLayout.size(ofValue: info) ? info : nil
    }

    private func isExpectedHelperExecutable(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        let resolved = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
        return resolved.hasPrefix(helperBuildDirectory)
            && URL(fileURLWithPath: resolved).lastPathComponent == "DesktopToolServer"
    }

    func pinReadyHelper() -> Bool {
        guard serverPID != nil else { return false }
        let capacity = max(1, Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)) / MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: capacity + 32)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return false }
        let matches = pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter {
            $0 > 0 && isServerChild($0) && isExpectedHelperExecutable($0)
        }
        guard matches.count == 1, let info = processInfo(matches[0]) else { return false }
        helperPID = matches[0]
        helperStartSecond = info.pbi_start_tvsec
        return true
    }

    private func isPinnedHelper(_ peer: pid_t) -> Bool {
        guard peer == helperPID, let helperStartSecond,
            isServerChild(peer), isExpectedHelperExecutable(peer),
            processInfo(peer)?.pbi_start_tvsec == helperStartSecond
        else { return false }
        return true
    }

    private func handle(_ client: Int32) {
        var peer: pid_t = 0
        var peerLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerLength) == 0,
            isPinnedHelper(peer)
        else {
            respond(
                client,
                .failure(
                    "unauthorized", commandID: "unknown",
                    direction: "unknown", message: "Caller is outside the app-server session."))
            return
        }
        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        _ = setsockopt(
            client, SOL_SOCKET, SO_RCVTIMEO, &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout)))
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 512)
        while data.count < 2048 {
            let count = Darwin.read(client, &bytes, bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            if data.contains(0x0A) { break }
        }
        guard let newline = data.firstIndex(of: 0x0A),
            let request = try? JSONDecoder().decode(
                SpaceToolRequest.self, from: data.prefix(upTo: newline))
        else {
            respond(
                client,
                .failure(
                    "invalid_request", commandID: "unknown",
                    direction: "unknown", message: "Invalid bridge request."))
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let onRequest = self.onRequest else {
                self?.respond(
                    client,
                    .failure(
                        "unavailable", commandID: "unknown",
                        direction: request.direction, message: "App session is unavailable."))
                return
            }
            onRequest(request) { [weak self] result in self?.respond(client, result) }
        }
    }

    private func respond(_ client: Int32, _ result: SpaceToolResult) {
        var noSignal: Int32 = 1
        _ = setsockopt(
            client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal)))
        if let data = try? JSONEncoder().encode(result) {
            data.withUnsafeBytes { buffer in
                if let base = buffer.baseAddress { _ = Darwin.write(client, base, buffer.count) }
            }
        }
        Darwin.close(client)
    }
}
