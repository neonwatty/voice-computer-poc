import AppKit
import CoreGraphics
import Foundation

func fail(_ reason: String) -> Never {
    fputs("Finder window observation unavailable: \(reason)\n", stderr)
    exit(2)
}

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder")
guard apps.count == 1 else { fail("expected one Finder process") }
guard let rawWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
    as? [[String: Any]]
else { fail("window inventory could not be read") }

let expectedTitle = CommandLine.arguments.dropFirst().first
var identifiers: [Int] = []
var matching: [Int] = []
for window in rawWindows {
    guard window[kCGWindowOwnerPID as String] as? Int == Int(apps[0].processIdentifier),
        window[kCGWindowLayer as String] as? Int == 0,
        let title = window[kCGWindowName as String] as? String,
        !title.isEmpty
    else { continue }
    guard let identifier = window[kCGWindowNumber as String] as? Int,
        identifier > 0
    else { fail("Finder window has no numeric identity") }
    identifiers.append(identifier)
    if title == expectedTitle { matching.append(identifier) }
}
guard Set(identifiers).count == identifiers.count else { fail("duplicate window identity") }
let data = try JSONSerialization.data(withJSONObject: [
    "window_ids": identifiers.sorted(), "matching_window_ids": matching.sorted(),
])
guard let output = String(data: data, encoding: .utf8) else { fail("JSON encoding failed") }
print(output)
