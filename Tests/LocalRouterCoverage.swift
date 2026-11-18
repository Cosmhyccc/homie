import Foundation

// How much of real speech the instant lane covers, and whether it ever fires on the wrong thing.
// xcrun swiftc -parse-as-library Sources/LocalRouter.swift Tests/LocalRouterCoverage.swift -o /private/tmp/coverage && /private/tmp/coverage Tests/local_eval/coverage.tsv
@main struct LocalRouterCoverage {
    static func main() {
        let path = CommandLine.arguments.dropFirst().first ?? "Tests/local_eval/coverage.tsv"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { print("can't read \(path)"); exit(2) }
        var shouldFire = 0, fired = 0, wrong = 0, total = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let (said, want) = (parts[0], parts[1])
            total += 1
            let got = LocalRouter.intent(said, music: .appleMusic)?.tool
            if want == "model" {
                if let got { wrong += 1; print("WRONG FIRE  \(said) -> \(got.isEmpty ? "spoken" : got)") }
            } else {
                shouldFire += 1
                if got == want { fired += 1 }
                else if let got { wrong += 1; print("WRONG TOOL  \(said) -> \(got), wanted \(want)") }
                else { print("MISS        \(said)  (wanted \(want.isEmpty ? "spoken" : want))") }
            }
        }
        print(String(format: "\ninstant coverage %d/%d (%.0f%%), wrong fires %d, phrases %d", fired, shouldFire, Double(fired) * 100 / Double(max(1, shouldFire)), wrong, total))
        exit(wrong == 0 ? 0 : 1)
    }
}
