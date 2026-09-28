import SwiftUI

struct ContentView: View {
    @ObservedObject var client: AppServerClient
    @State private var phrase = ""
    @State private var activityTab: ActivityTab = .activity

    private enum ActivityTab: String, CaseIterable {
        case activity = "Activity"
        case diagnostics = "Diagnostic Log"
    }

    private let samples = [
        "Open Calculator",
        "In Calculator, enter 2 + 3 = and verify the result",
        "Open Google Chrome",
        "Switch to the next desktop Space",
        "Switch to the previous desktop Space",
        "Switch one desktop Space right and then back left",
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

            if activityTab == .activity {
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
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Activity view", selection: $activityTab) {
                        ForEach(ActivityTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    Spacer()
                    if activityTab == .diagnostics {
                        Button("Show File") { client.revealLog() }
                            .disabled(client.logURL == nil)
                    }
                }
                if !client.logError.isEmpty {
                    Text(client.logError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Group {
                    if activityTab == .activity {
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
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 3) {
                                    ForEach(Array(client.diagnosticEntries.enumerated()), id: \.offset) {
                                        index, entry in
                                        DiagnosticRow(entry: entry)
                                            .id(index)
                                    }
                                }
                            }
                            .onAppear {
                                if !client.diagnosticEntries.isEmpty {
                                    proxy.scrollTo(client.diagnosticEntries.count - 1, anchor: .bottom)
                                }
                            }
                            .onChange(of: client.diagnosticEntries.count) { _, count in
                                if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

private struct DiagnosticRow: View {
    let entry: DiagnosticLog.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.timestamp)
                    .foregroundStyle(.secondary)
                Text(entry.event)
                    .fontWeight(.semibold)
            }
            ForEach(entry.details.keys.sorted(), id: \.self) { key in
                Text("\(key): \(entry.details[key] ?? "")")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Divider() }
    }
}
