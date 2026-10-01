import Darwin
import Foundation

final class SpaceToolBridge {
    let sessionID = UUID().uuidString
    let socketPath: String
    var serverPID: pid_t?
    var expectedExecutablePath: String?
    var onRequest: ((SpaceToolRequest, PeerIdentity, @escaping (SpaceToolResult) -> Void) -> Void)?
    private let directory: URL
    private let socket: Int32
    private var running = true
    private var binding: (peer: PeerIdentity, commandID: String, itemID: String)?

    struct PeerIdentity: Equatable {
        let pid: pid_t
        let startSecond: UInt64
        let startMicrosecond: UInt64
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
        revoke()
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

    private func processInfo(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(
            pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info)))
        return count == MemoryLayout.size(ofValue: info) ? info : nil
    }

    private func executablePath(_ pid: pid_t) -> String? {
        var path = [CChar](repeating: 0, count: 4_096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
    }

    func eligiblePeer(_ peer: pid_t) -> PeerIdentity? {
        guard let serverPID, let expectedExecutablePath,
            let info = processInfo(peer), pid_t(info.pbi_ppid) == serverPID,
            executablePath(peer) == expectedExecutablePath
        else { return nil }
        let capacity = max(1, Int(proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)) / MemoryLayout<pid_t>.size)
        var pids = [pid_t](repeating: 0, count: capacity + 32)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return nil }
        let matches = pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { candidate in
            guard let candidateInfo = processInfo(candidate) else { return false }
            return pid_t(candidateInfo.pbi_ppid) == serverPID
                && executablePath(candidate) == expectedExecutablePath
        }
        guard matches.count == 1, matches[0] == peer else { return nil }
        return PeerIdentity(
            pid: peer, startSecond: info.pbi_start_tvsec,
            startMicrosecond: info.pbi_start_tvusec)
    }

    func bind(_ peer: PeerIdentity, commandID: String, itemID: String) -> Bool {
        guard binding == nil, !commandID.isEmpty, !itemID.isEmpty,
            eligiblePeer(peer.pid) == peer
        else { return false }
        binding = (peer, commandID, itemID)
        return true
    }

    func revoke() { binding = nil }

    func isBoundPeerAlive(commandID: String, itemID: String) -> Bool {
        guard let binding, binding.commandID == commandID, binding.itemID == itemID else {
            return false
        }
        return eligiblePeer(binding.peer.pid) == binding.peer
    }

    var helperIdentityDetails: [String: String] {
        [
            "pid": String(binding?.peer.pid ?? -1),
            "path_matches_preflight": String(
                binding.flatMap { executablePath($0.peer.pid) } == expectedExecutablePath),
            "start_sec": binding.map { String($0.peer.startSecond) } ?? "unknown",
            "start_usec": binding.map { String($0.peer.startMicrosecond) } ?? "unknown",
        ]
    }

    #if DEBUG
        func invalidateStartIdentityForTesting() {
            guard let binding else { return }
            self.binding = (
                PeerIdentity(
                    pid: binding.peer.pid, startSecond: binding.peer.startSecond,
                    startMicrosecond: binding.peer.startMicrosecond + 1),
                binding.commandID, binding.itemID
            )
        }
    #endif

    private func handle(_ client: Int32) {
        var peer: pid_t = 0
        var peerLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(client, SOL_LOCAL, LOCAL_PEERPID, &peer, &peerLength) == 0,
            let identity = eligiblePeer(peer)
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
            onRequest(request, identity) { [weak self] result in self?.respond(client, result) }
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
