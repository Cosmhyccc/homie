import Foundation
// Serves files locally; never touches the internet.
// xcrun swiftc -parse-as-library Sources/HomieModels.swift Tests/HomieDownloaderTests.swift -o /private/tmp/dl-tests && /private/tmp/dl-tests <dir> <port>
enum LocalBrain { enum Tier: String { case full, lite }; static let assets = URL(fileURLWithPath: "/nonexistent") }
@main struct HomieDownloaderTests { static func main() async throws {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1]), port = CommandLine.arguments[2]
    let good = dir.appendingPathComponent("fake.gguf")
    let sha = try HomieModels.sha256(of: good)
    let size = (try FileManager.default.attributesOfItem(atPath: good.path)[.size] as! NSNumber).int64Value
    func run(_ model: HomieModels.Model) async -> Result<URL, Error> {
        await withCheckedContinuation { c in
            let d = HomieDownloader(); var last = 0.0
            d.onProgress = { last = $0 }
            d.fetch(model) { r in if case .success = r { precondition(last > 0.99, "progress \(last)") }; c.resume(returning: r) }
            _ = d   // keep alive until done
            withExtendedLifetime(d) {}
        }
    }
    let url = URL(string: "http://127.0.0.1:\(port)/fake.gguf")!
    // 1. Good file installs and matches
    let ok = await run(.init(file: "homie-test.gguf", url: url, sha256: sha, size: size))
    guard case .success(let installed) = ok else { fatalError("good download failed: \(ok)") }
    let check = try HomieModels.sha256(of: installed); precondition(check == sha)
    try FileManager.default.removeItem(at: installed)
    print("ok    good file installed and verified (\(size / 1_000_000) MB)")
    // 2. Wrong checksum is thrown away
    let bad = await run(.init(file: "homie-test.gguf", url: url, sha256: String(repeating: "0", count: 64), size: size))
    guard case .failure(let e) = bad, e is HomieDownloadError else { fatalError("bad checksum accepted") }
    precondition(!FileManager.default.fileExists(atPath: HomieModels.folder.appendingPathComponent("homie-test.gguf").path))
    print("ok    corrupted file rejected: \(e.localizedDescription)")
    // 3. Missing file reports the HTTP status
    let missing = await run(.init(file: "homie-test.gguf", url: URL(string: "http://127.0.0.1:\(port)/nope.gguf")!, sha256: sha, size: size))
    guard case .failure(let m) = missing else { fatalError("404 accepted") }
    print("ok    missing file: \(m.localizedDescription)")
    print("HomieDownloader: all passed")
}}
