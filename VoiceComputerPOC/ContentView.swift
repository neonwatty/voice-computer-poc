import SwiftUI

struct ContentView: View {
    @ObservedObject var client: AppServerClient
    @State private var phrase = ""

    private let samples = [
        "Open Calculator",
        "In Calculator, enter 2 + 3 = and verify the result",
        "Open Google Chrome",
        "Switch to the previous desktop Space",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Voice Computer")
                        .font(.largeTitle.bold())
                    Text("Text commands through Codex app-server and Computer Use")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Label(client.status, systemImage: client.isWorking ? "circle.dotted" : "circle.fill")
                    .font(.caption)
                    .foregroundStyle(client.isWorking ? .orange : .secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Command").font(.headline)
                HStack {
                    TextField("What should the computer do?", text: $phrase)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(run)
                        .accessibilityIdentifier("commandField")
                    Button("Run", action: run)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(
                            client.isWorking || phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                        .accessibilityIdentifier("runButton")
                    Button("Stop") { client.stop() }
                        .disabled(!client.canStop)
                }
            }

            HStack(spacing: 16) {
                Text("Space changes observed: \(client.spaceChangeCount)")
                Text("Last activated app: \(client.lastActivatedApp)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Try a phrase").font(.headline)
                ForEach(samples, id: \.self) { sample in
                    Button(sample) { phrase = sample }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Result").font(.headline)
                ScrollView {
                    if client.result.isEmpty {
                        Text("Codex's result will appear here.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text(
                            (try? AttributedString(markdown: client.result))
                                ?? AttributedString(client.result)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
                .frame(height: 90)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Activity").font(.headline)
                    Spacer()
                    Button("Reveal Log") { client.revealLog() }
                        .disabled(client.logURL == nil)
                }
                if !client.logError.isEmpty {
                    Text(client.logError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            ForEach(Array(client.events.enumerated()), id: \.offset) { index, event in
                                Text(event)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: client.events.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(22)
        .sheet(item: $client.approval) { approval in
            VStack(alignment: .leading, spacing: 18) {
                Label("Computer Use approval", systemImage: "hand.raised")
                    .font(.title2.bold())
                Text(approval.message)
                Text(approval.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Decline") { client.decideApproval(allow: false) }
                    Button("Allow once") { client.decideApproval(allow: true) }
                        .keyboardShortcut(.defaultAction)
                    if approval.supportsSessionGrant {
                        Button("Allow for session") {
                            client.decideApproval(allow: true, forSession: true)
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 500)
        }
    }

    private func run() { client.run(phrase) }
}
