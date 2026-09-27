import SwiftUI

@main
struct VoiceComputerPOCApp: App {
    @StateObject private var client = AppServerClient()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(client: client)
                .frame(minWidth: 640, minHeight: 620)
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("Voice Computer", systemImage: "cursorarrow.rays") {
            MenuBarContent(client: client)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject var client: AppServerClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(client.status)
        Button("Open Voice Computer") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
    }
}
