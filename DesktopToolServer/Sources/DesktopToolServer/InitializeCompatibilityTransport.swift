import Foundation
import Logging
import MCP

/// The pinned MCP SDK decodes client `experimental` capabilities as strings.
/// Codex sends an object value for `codex/auth-change`; retain string entries
/// and omit only values this pinned SDK cannot represent.
actor InitializeCompatibilityTransport: Transport {
    private let base: StdioTransport
    nonisolated let logger: Logger

    init() {
        let transport = StdioTransport()
        base = transport
        logger = transport.logger
    }

    func connect() async throws { try await base.connect() }

    func disconnect() async { await base.disconnect() }

    func send(_ data: Data) async throws { try await base.send(data) }

    func receive() -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await data in await base.receive() {
                        continuation.yield(Self.compatibleInitialize(data))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    static func compatibleInitialize(_ data: Data) -> Data {
        guard
            var message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            message["method"] as? String == "initialize",
            var params = message["params"] as? [String: Any],
            var capabilities = params["capabilities"] as? [String: Any],
            let experimental = capabilities["experimental"] as? [String: Any],
            experimental.values.contains(where: { !($0 is String) })
        else { return data }

        let supported = experimental.compactMapValues { $0 as? String }
        if supported.isEmpty {
            capabilities.removeValue(forKey: "experimental")
        } else {
            capabilities["experimental"] = supported
        }
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? data
    }
}
