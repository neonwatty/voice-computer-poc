import ApplicationServices

enum MissionControlAXSource: String {
    case dock
    case windowManager = "window_manager"
}

struct MissionControlAXDiscovery {
    let list: AXUIElement
    let target: AXUIElement
    let source: MissionControlAXSource

    init(list: AXUIElement, target: AXUIElement, source: MissionControlAXSource = .dock) {
        self.list = list
        self.target = target
        self.source = source
    }
}
