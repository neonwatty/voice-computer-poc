import Darwin
import Foundation

enum BridgeClient {
    struct Limits {
        var connect: TimeInterval = 2
        var write: TimeInterval = 2
        var read: TimeInterval = 8
        var total: TimeInterval = 12
    }

    static func invoke(direction: String, limits: Limits = .init()) -> ToolResult {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SPACE_BRIDGE_PATH"],
            let sessionID = environment["SPACE_SESSION_ID"],
            let address = socketAddress(path)
        else {
            ToolServer.stage("bridge_config_unavailable")
            return .failure("bridge_unavailable", direction, "Bridge configuration is missing.")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let totalDeadline = start + limits.total
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            return .failure("bridge_unavailable", direction, "Could not create bridge socket.")
        }
        defer { Darwin.close(socket) }
        var noSignal: Int32 = 1
        _ = setsockopt(
            socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let flags = fcntl(socket, F_GETFL)
        guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return .failure("bridge_unavailable", direction, "Could not bound bridge socket.")
        }
        guard connect(socket, address: address, deadline: totalDeadline, limits: limits, start: start)
        else { return failure(direction, "bridge_unavailable", "Bridge connect failed or timed out.") }
        ToolServer.stage("bridge_connected")
        let request = ["sessionID": sessionID, "direction": direction]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure("invalid_request", direction, "Could not encode bridge request.")
        }
        payload.append(0x0A)
        guard write(payload, to: socket, deadline: totalDeadline, limits: limits) else {
            return failure(direction, "timeout", "Bridge write failed or timed out.")
        }
        return read(from: socket, direction: direction, deadline: totalDeadline, limits: limits)
    }

    static func invokeState(limits: Limits = .init()) -> DesktopStateToolResult {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SPACE_BRIDGE_PATH"],
            let sessionID = environment["SPACE_SESSION_ID"],
            let address = socketAddress(path)
        else { return .failure("bridge_unavailable", "Bridge configuration is missing.") }
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + limits.total
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            return .failure("bridge_unavailable", "Could not create bridge socket.")
        }
        defer { Darwin.close(socket) }
        var noSignal: Int32 = 1
        _ = setsockopt(
            socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
            socklen_t(MemoryLayout.size(ofValue: noSignal)))
        let flags = fcntl(socket, F_GETFL)
        guard flags >= 0, fcntl(socket, F_SETFL, flags | O_NONBLOCK) == 0,
            connect(socket, address: address, deadline: deadline, limits: limits, start: start)
        else { return .failure("bridge_unavailable", "Bridge connect failed.") }
        let request = ["sessionID": sessionID, "operation": "get_desktop_state"]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
            return .failure("invalid_request", "Could not encode bridge request.")
        }
        payload.append(0x0A)
        guard write(payload, to: socket, deadline: deadline, limits: limits) else {
            return .failure("timeout", "Bridge write failed or timed out.")
        }
        return readState(from: socket, deadline: deadline, limits: limits)
    }

    private static func readState(
        from socket: Int32, deadline: TimeInterval, limits: Limits
    ) -> DesktopStateToolResult {
        let readDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + limits.read)
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 512)
        while response.count < 2048 {
            guard ready(socket, events: Int16(POLLIN), until: readDeadline) else {
                return .failure("timeout", "Bridge reply timed out.")
            }
            let count = Darwin.read(socket, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0 else { return .failure("bridge_unavailable", "Bridge read failed.") }
            response.append(contentsOf: bytes.prefix(count))
        }
        guard let result = try? JSONDecoder().decode(DesktopStateToolResult.self, from: response)
        else { return .failure("invalid_reply", "Bridge reply was invalid.") }
        return result
    }

    private static func connect(
        _ socket: Int32, address: sockaddr_un, deadline: TimeInterval, limits: Limits,
        start: TimeInterval
    ) -> Bool {
        ToolServer.stage("bridge_connect_start")
        var mutableAddress = address
        let connected = withUnsafePointer(to: &mutableAddress) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS,
                ready(
                    socket, events: Int16(POLLOUT),
                    until: min(deadline, start + limits.connect))
            else {
                ToolServer.stage("bridge_connect_failed")
                return false
            }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                socketError == 0
            else {
                ToolServer.stage("bridge_connect_failed")
                return false
            }
        }
        return true
    }

    private static func write(
        _ payload: Data, to socket: Int32, deadline: TimeInterval, limits: Limits
    ) -> Bool {
        let writeDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + limits.write)
        ToolServer.stage("bridge_write_start")
        var written = 0
        while written < payload.count {
            guard ready(socket, events: Int16(POLLOUT), until: writeDeadline) else {
                ToolServer.stage("bridge_write_timeout")
                return false
            }
            let count = payload.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(socket, base.advanced(by: written), buffer.count - written)
            }
            guard count > 0 else {
                return false
            }
            written += count
        }
        ToolServer.stage("bridge_write_complete")
        return true
    }

    private static func read(
        from socket: Int32, direction: String, deadline: TimeInterval, limits: Limits
    ) -> ToolResult {
        let readDeadline = min(deadline, ProcessInfo.processInfo.systemUptime + limits.read)
        ToolServer.stage("bridge_read_start")
        var response = Data()
        var bytes = [UInt8](repeating: 0, count: 512)
        while response.count < 2048 {
            guard ready(socket, events: Int16(POLLIN), until: readDeadline) else {
                ToolServer.stage("bridge_read_timeout")
                return failure(direction, "timeout", "Bridge reply timed out.")
            }
            let count = Darwin.read(socket, &bytes, bytes.count)
            if count == 0 { break }
            guard count > 0 else {
                return failure(direction, "bridge_unavailable", "Bridge read failed.")
            }
            response.append(contentsOf: bytes.prefix(count))
        }
        guard let result = try? JSONDecoder().decode(ToolResult.self, from: response),
            result.direction == direction
        else {
            return failure(direction, "invalid_reply", "Bridge reply was invalid.")
        }
        ToolServer.stage("bridge_reply_\(result.status)")
        return result
    }

    private static func failure(_ direction: String, _ status: String, _ message: String)
        -> ToolResult
    {
        Task.isCancelled
            ? .failure("interrupted", direction, "The tool call was cancelled.")
            : .failure(status, direction, message)
    }

    private static func ready(_ socket: Int32, events: Int16, until deadline: TimeInterval) -> Bool {
        while ProcessInfo.processInfo.systemUptime < deadline {
            if Task.isCancelled { return false }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var descriptor = pollfd(fd: socket, events: events, revents: 0)
            let wait = Int32(max(1, min(200, Int(remaining * 1_000))))
            let result = Darwin.poll(&descriptor, 1, wait)
            if result > 0 { return descriptor.revents & events != 0 }
            if result < 0 && errno != EINTR { return false }
        }
        return false
    }

    private static func socketAddress(_ path: String) -> sockaddr_un? {
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
}
