import Foundation

struct DesktopStateToolRequest: Codable {
    let sessionID: String
    let operation: String

    static func matches(_ phrase: String) -> Bool {
        phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "agent get desktop state"
    }
}

struct DesktopStateToolResult: Codable, Equatable {
    let status: String
    let observedAt: String?
    let displayScope: String?
    let currentMainSpaceID: Int?
    let orderedMainSpaceIDs: [Int]?
    let frontmostBundleID: String?
    let message: String

    var verified: Bool {
        status == "observed" && observedAt != nil && displayScope == "Main"
            && currentMainSpaceID != nil && orderedMainSpaceIDs?.contains(currentMainSpaceID ?? -1) == true
            && frontmostBundleID?.isEmpty == false
    }

    static func failure(_ status: String, _ message: String) -> Self {
        .init(
            status: status, observedAt: nil, displayScope: nil,
            currentMainSpaceID: nil, orderedMainSpaceIDs: nil,
            frontmostBundleID: nil, message: message)
    }

    static func observe(
        snapshot: () -> SpaceSnapshot?, frontmost: () -> String?,
        ambiguousDisplay: () -> Bool? = { nil }
    ) -> Self {
        guard let before = snapshot() else {
            return ambiguousDisplay() == true
                ? .failure("ambiguous_display", "Multiple active display Spaces are unsupported.")
                : .failure("unavailable", "Main desktop Space could not be read.")
        }
        guard let bundleID = frontmost(), !bundleID.isEmpty,
            let after = snapshot(), before == after
        else { return .failure("unavailable", "Desktop state changed or could not be read.") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .init(
            status: "observed", observedAt: formatter.string(from: Date()),
            displayScope: "Main", currentMainSpaceID: after.current,
            orderedMainSpaceIDs: after.ordered, frontmostBundleID: bundleID,
            message: "Observed Main desktop Space and foreground app.")
    }
}
