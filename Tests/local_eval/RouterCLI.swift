import Foundation
// One line in, one JSON line out: what the instant lane would do and how long homie waits for end of speech.
@main struct RouterCLI { static func main() {
    while let line = readLine() {
        let intent = LocalRouter.intent(line, music: .appleMusic)
        let out: [String: Any] = ["text": line, "tool": intent?.tool ?? NSNull(), "say": intent?.say ?? "", "endpoint": LocalRouter.endpointDelay(line)]
        print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!); fflush(stdout)
    }
}}
