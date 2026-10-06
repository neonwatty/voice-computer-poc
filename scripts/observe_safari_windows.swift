import AppKit
import ApplicationServices
import Foundation

func fail(_ reason: String) -> Never {
    fputs("Safari window observation unavailable: \(reason)\n", stderr)
    exit(2)
}

let apps = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari")
guard apps.count == 1 else { fail("expected one Safari process") }
let app = AXUIElementCreateApplication(apps[0].processIdentifier)
var rawWindows: CFTypeRef?
guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &rawWindows) == .success,
    let windows = rawWindows as? [AXUIElement]
else { fail("AXWindows could not be read") }

var identifiers: [String] = []
for window in windows {
    var rawIdentifier: CFTypeRef?
    guard AXUIElementCopyAttributeValue(window, kAXIdentifierAttribute as CFString,
                                        &rawIdentifier) == .success,
        let identifier = rawIdentifier as? String,
        let uuidText = identifier.components(separatedBy: "UUID=").last,
        UUID(uuidString: uuidText) != nil
    else { fail("window has no Safari UUID") }
    identifiers.append(uuidText.uppercased())
}
guard Set(identifiers).count == identifiers.count else { fail("duplicate window UUID") }
let data = try JSONSerialization.data(withJSONObject: ["window_ids": identifiers.sorted()])
guard let output = String(data: data, encoding: .utf8) else { fail("JSON encoding failed") }
print(output)
