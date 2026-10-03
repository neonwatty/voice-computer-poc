import Foundation

extension AppServerClient {
    func turnInstruction(for phrase: String) -> String {
        if let url = finderReportURL {
            return
                "Use only mcp__cua_repl.js with Finder (com.apple.finder). Get Finder, use Go to Folder (Command-Shift-G), enter exactly \(url.path), and press Return once. Inspect Finder's Accessibility state and report the selected item's exact file URL. Stop if Finder has no window, the file is missing, the selected item differs, access is declined, or the tool fails. Do not open or edit the file, use a shell, or control another app. User request: \(phrase)"
        }
        if let url = browserDocsURL {
            let docsURL = url.absoluteString.replacingOccurrences(of: "/home?", with: "/docs?")
            return
                "Use only mcp__cua_repl.js with the native Safari app. First bind with cua.getApp('com.apple.Safari'); never use cua.getBrowser or createBrowserTab because those browser surfaces are unavailable here. Open one new Safari tab and enter exactly \(url.absoluteString) in its address field. Read the rendered Home page, click its Docs link once, then inspect the rendered page and address. Report the final URL and visible heading. The intended final URL is exactly \(docsURL); report unverified if it differs or the Docs heading is absent. Stop if Safari navigates to a different origin, the Docs link is absent, access is declined, or the tool fails. Do not use a shell, file operations, or another app. User request: \(phrase)"
        }
        if let direction = requestedToolDirection ?? SpaceToolRequest.direction(for: phrase) {
            return
                "Call the MCP tool mcp__desktop_tool__switch_space from desktop_tool exactly once with JSON arguments {\"direction\":\"\(direction.rawValue)\"}. This is one adjacent desktop Space move. Do not use Computer Use or another tool. Report the typed tool result; do not claim success without verified status. User request: \(phrase)"
        }
        return
            "This prototype is for reversible, low-impact desktop tests. For other requests, explain that the prototype does not support them. Use only mcp__cua_repl.js for desktop UI interaction. Do not use shell commands, AppleScript, or file operations. If Computer Use access is needed, request it. Check the visible result before reporting success. Distinguish a declined access request from a tool failure; do not call a tool failure an access denial."
            + " User request: \(phrase)"
    }
}
