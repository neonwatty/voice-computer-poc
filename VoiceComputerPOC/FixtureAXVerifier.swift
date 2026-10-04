import AppKit
import ApplicationServices
import Foundation

struct FixtureAXObservation {
    let verified: Bool
    let reason: String
    let visited: Int

    static func reject(_ reason: String, visited: Int = 0) -> Self {
        Self(verified: false, reason: reason, visited: visited)
    }
}

enum FixtureAXVerifier {
    struct WebAreaEvidence {
        let url: URL?
        var headings: [String]
    }

    struct FinderWindowEvidence {
        let selectedRowURLs: [[URL]]
        let visibleURLs: [URL]
    }

    private struct WorkItem {
        let element: AXUIElement
        let webAreaIndex: Int?
    }

    private static let nodeLimit = 400
    private static let scanSeconds = 2.5

    static func verifyBrowser(homeURL: URL) -> FixtureAXObservation {
        guard
            let components = URLComponents(url: homeURL, resolvingAgainstBaseURL: false),
            let runID = components.queryItems?.first(where: { $0.name == "run_id" })?.value
        else { return .reject("invalid_target") }
        var docs = components
        docs.path = "/docs"
        guard let expectedURL = docs.url else { return .reject("invalid_target") }
        guard let windows = windows(for: "com.apple.Safari") else {
            return .reject("accessibility_unavailable")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + scanSeconds
        var areas: [WebAreaEvidence] = []
        var visited = 0
        for window in windows {
            var queue = [WorkItem(element: window, webAreaIndex: nil)]
            while !queue.isEmpty {
                guard visited < nodeLimit, ProcessInfo.processInfo.systemUptime < deadline else {
                    return .reject("scan_limit", visited: visited)
                }
                let item = queue.removeFirst()
                visited += 1
                AXUIElementSetMessagingTimeout(item.element, 0.05)
                let role = string(item.element, kAXRoleAttribute)
                var webAreaIndex = item.webAreaIndex
                if role == "AXWebArea" {
                    webAreaIndex = areas.count
                    areas.append(WebAreaEvidence(url: url(item.element), headings: []))
                } else if role == "AXHeading", let webAreaIndex {
                    let heading = string(item.element, kAXTitleAttribute)
                    let value = string(item.element, kAXValueAttribute)
                    if !heading.isEmpty { areas[webAreaIndex].headings.append(heading) }
                    if !value.isEmpty { areas[webAreaIndex].headings.append(value) }
                }
                queue.append(
                    contentsOf: children(item.element).map {
                        WorkItem(element: $0, webAreaIndex: webAreaIndex)
                    })
            }
        }
        let matched = browserMatches(
            areas, expectedURL: expectedURL, expectedHeading: "Voice Computer Docs \(runID)")
        return FixtureAXObservation(
            verified: matched,
            reason: matched ? "exact_url_and_heading" : "url_or_heading_mismatch",
            visited: visited)
    }

    static func verifyFinder(reportURL: URL) -> FixtureAXObservation {
        guard reportURL.isFileURL,
            reportURL.resolvingSymlinksInPath().standardizedFileURL == reportURL.standardizedFileURL,
            (try? reportURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { return .reject("invalid_target") }
        guard let windows = windows(for: "com.apple.finder") else {
            return .reject("accessibility_unavailable")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + scanSeconds
        var evidence: [FinderWindowEvidence] = []
        var visited = 0
        for window in windows {
            var queue = [window]
            var selectedRows: [[URL]] = []
            var visibleURLs: [URL] = []
            while !queue.isEmpty {
                guard visited < nodeLimit, ProcessInfo.processInfo.systemUptime < deadline else {
                    return .reject("scan_limit", visited: visited)
                }
                let node = queue.removeFirst()
                visited += 1
                AXUIElementSetMessagingTimeout(node, 0.05)
                if let value = url(node), value.isFileURL { visibleURLs.append(value) }
                if string(node, kAXRoleAttribute) == kAXRowRole as String,
                    bool(node, kAXSelectedAttribute)
                {
                    guard let rowURLs = descendantURLs(node, deadline: deadline) else {
                        return .reject("scan_limit", visited: visited)
                    }
                    if !rowURLs.isEmpty { selectedRows.append(rowURLs) }
                }
                queue.append(contentsOf: children(node))
            }
            evidence.append(
                FinderWindowEvidence(
                    selectedRowURLs: selectedRows, visibleURLs: visibleURLs))
        }
        let matched = finderMatches(evidence, reportURL: reportURL)
        return FixtureAXObservation(
            verified: matched,
            reason: matched ? "exact_selected_file" : "selection_mismatch",
            visited: visited)
    }

    static func browserMatches(
        _ areas: [WebAreaEvidence], expectedURL: URL, expectedHeading: String
    ) -> Bool {
        areas.filter {
            $0.url?.absoluteString == expectedURL.absoluteString
                && $0.headings.contains(expectedHeading)
        }.count == 1
    }

    static func finderMatches(_ evidence: [FinderWindowEvidence], reportURL: URL) -> Bool {
        let decoy = reportURL.deletingLastPathComponent().appendingPathComponent("report-copy.txt")
        return evidence.filter { window in
            window.selectedRowURLs.count == 1
                && window.selectedRowURLs[0].count == 1
                && window.selectedRowURLs[0][0].standardizedFileURL == reportURL.standardizedFileURL
                && window.visibleURLs.contains { $0.standardizedFileURL == decoy.standardizedFileURL }
        }.count == 1
    }

    private static func windows(for bundleID: String) -> [AXUIElement]? {
        guard AXIsProcessTrusted() else { return nil }
        let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        guard apps.count == 1 else { return nil }
        let root = AXUIElementCreateApplication(apps[0].processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.05)
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &value)
                == .success
        else { return nil }
        return value as? [AXUIElement]
    }

    private static func descendantURLs(_ root: AXUIElement, deadline: TimeInterval) -> [URL]? {
        var queue = [root]
        var visited = 0
        var urls: [URL] = []
        while !queue.isEmpty {
            guard visited < 60, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
            let node = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.05)
            if let value = url(node), value.isFileURL { urls.append(value) }
            queue.append(contentsOf: children(node))
        }
        return urls
    }

    private static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success
            ? value : nil
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String {
        attribute(element, key) as? String ?? ""
    }

    private static func bool(_ element: AXUIElement, _ key: String) -> Bool {
        attribute(element, key) as? Bool ?? false
    }

    private static func url(_ element: AXUIElement) -> URL? {
        let raw = attribute(element, kAXURLAttribute)
        if let value = raw as? URL { return value }
        if let value = raw as? String { return URL(string: value) }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }
}
