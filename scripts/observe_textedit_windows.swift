import AppKit
import CoreGraphics
import Foundation

func fail(_ reason: String) -> Never {
    fputs("TextEdit window observation unavailable: \(reason)\n", stderr)
    exit(2)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let watch = arguments.contains("--watch")
let expectedTitle = arguments.first { $0 != "--watch" }

func inventory() -> ([Int], [Int]) {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
    guard apps.count <= 1 else { fail("multiple TextEdit processes") }
    guard let rawWindows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID)
        as? [[String: Any]]
    else { fail("window inventory could not be read") }
    var identifiers: [Int] = []
    var matching: [Int] = []
    if let app = apps.first {
        for window in rawWindows {
            guard window[kCGWindowOwnerPID as String] as? Int == Int(app.processIdentifier),
                window[kCGWindowLayer as String] as? Int == 0,
                let title = window[kCGWindowName as String] as? String,
                !title.isEmpty, !["Open", "Save Panel Accessory View"].contains(title)
            else { continue }
            guard let identifier = window[kCGWindowNumber as String] as? Int,
                identifier > 0
            else { fail("TextEdit window has no numeric identity") }
            identifiers.append(identifier)
            if title == expectedTitle { matching.append(identifier) }
        }
    }
    guard Set(identifiers).count == identifiers.count else { fail("duplicate window identity") }
    return (identifiers.sorted(), matching.sorted())
}

var previous: ([Int], [Int])?
repeat {
    let current = inventory()
    if previous == nil || previous!.0 != current.0 || previous!.1 != current.1 {
        let data = try JSONSerialization.data(withJSONObject: [
            "window_ids": current.0, "matching_window_ids": current.1,
        ])
        guard let output = String(data: data, encoding: .utf8) else { fail("JSON encoding failed") }
        print(output)
        fflush(stdout)
        previous = current
    }
    if watch { usleep(100_000) }
} while watch
