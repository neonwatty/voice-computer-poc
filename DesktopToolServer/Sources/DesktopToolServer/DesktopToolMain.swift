import Foundation
import MCP

@main
struct DesktopToolMain {
    static func main() async {
        let server = Server(
            name: "desktop_tool", version: "0.1.0",
            capabilities: .init(tools: .init()))
        await server.withMethodHandler(ListTools.self) { _ in
            ToolServer.stage("tools_list")
            return .init(tools: [ToolServer.definition()])
        }
        await server.withMethodHandler(CallTool.self) { params in
            ToolServer.stage("call_received")
            guard params.name == ToolServer.toolName else {
                return ToolServer.toolResponse(
                    .failure("unknown_tool", "unknown", "Unknown tool."))
            }
            let result = ToolServer.call(arguments: params.arguments) { direction in
                BridgeClient.invoke(direction: direction)
            }
            ToolServer.stage("call_result_\(result.status)")
            return ToolServer.toolResponse(result)
        }
        do {
            ToolServer.stage("server_start")
            try await server.start(transport: InitializeCompatibilityTransport())
            ToolServer.stage("server_ready")
            await server.waitUntilCompleted()
            ToolServer.stage("server_end")
        } catch {
            ToolServer.stage("server_error")
            exit(1)
        }
    }
}
