import Foundation

final class DiagnosticLog {
    let fileURL: URL

    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private let timestampFormatter = ISO8601DateFormatter()

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "session-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).jsonl"
        fileURL = directory.appendingPathComponent(filename)
        guard
            FileManager.default.createFile(
                atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: fileURL)
        timestampFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.outputFormatting = [.sortedKeys]
    }

    deinit { try? handle.close() }

    @discardableResult
    func record(_ event: String, details: [String: String] = [:]) throws -> Entry {
        let entry = Entry(
            timestamp: timestampFormatter.string(from: Date()),
            event: event,
            details: details.mapValues { String($0.prefix(2_000)) }
        )
        var data = try encoder.encode(entry)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        return entry
    }

    struct Entry: Encodable {
        let timestamp: String
        let event: String
        let details: [String: String]
    }
}
