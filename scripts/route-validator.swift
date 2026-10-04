import Foundation

// The validator compiles the production route contract without the AppKit executor.
enum SpaceDirection: String {
    case left
    case right
}

@main
struct RouteValidator {
    static func main() {
        while let line = readLine() {
            guard
                let input = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any], let phrase = input["phrase"] as? String,
                let output = input["output"],
                let data = try? JSONSerialization.data(withJSONObject: output)
            else {
                print("{\"route\":\"invalid\"}")
                continue
            }
            let handoff = RouteHandoff.decide(data, phrase: phrase)
            let result: [String: Any]
            switch handoff {
            case .invalid: result = ["route": "invalid"]
            case .clarification: result = ["route": "clarification"]
            case .calculator: result = ["route": "calculator"]
            case .browserDocs(let url):
                result = ["route": "browser", "url": url.absoluteString]
            case .browserForm(let url, let query):
                result = ["route": "browser_form", "url": url.absoluteString, "query": query]
            case .finderReveal(let url):
                result = ["route": "finder", "path": url.path]
            case .space(let first, let remaining):
                result = [
                    "route": "space", "first": first.rawValue,
                    "remaining": remaining.map(\.rawValue),
                ]
            }
            if let encoded = try? JSONSerialization.data(withJSONObject: result),
                let text = String(data: encoded, encoding: .utf8)
            {
                print(text)
            } else {
                print("{\"route\":\"invalid\"}")
            }
        }
    }
}
