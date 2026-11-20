import Foundation
// Serves files locally with Tests/range_server.py; never touches the internet.
// xcrun swiftc -parse-as-library Sources/HomieModels.swift Tests/HomieDownloaderTests.swift -o /private/tmp/dl-tests && /private/tmp/dl-tests <dir> <port>
enum LocalBrain { enum Tier: String { case full, lite }; static let assets = URL(fileURLWithPath: "/nonexistent") }
@main struct HomieDownloaderTests { static func main() async throws {
    let dir = URL(fileURLWithPath: CommandLine.arguments[1]), port = CommandLine.arguments[2]
    let good = dir.appendingPathComponent("fake.gguf")
    let sha = try HomieModels.sha256(of: good)
    let size = (try FileManager.default.attributesOfItem(atPath: good.path)[.size] as! NSNumber).int64Value
    let name = "homie-test.gguf"
    let part = HomieModels.folder.appendingPathComponent(name + ".part"), ledger = part.appendingPathExtension("json")
    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)/\(path)")! }
    func model(_ path: String, sha: String = sha) -> HomieModels.Model { .init(file: name, url: url(path), sha256: sha, size: size) }
    func make(_ connections: Int = 6) -> HomieDownloader { let d = HomieDownloader(); d.piece = 1 << 20; d.connections = connections; return d }
    func run(_ d: HomieDownloader, _ m: HomieDownloader.Model) async -> Result<URL, Error> {
        await withCheckedContinuation { c in
            var last = 0.0
            d.onProgress = { v, _ in last = v }
            d.fetch(m) { r in if case .success = r { precondition(last > 0.99, "progress \(last)") }; c.resume(returning: r) }
        }
    }
    func installed(_ r: Result<URL, Error>, _ what: String) throws {
        guard case .success(let file) = r else { fatalError("\(what) failed: \(r)") }
        let check = try HomieModels.sha256(of: file); precondition(check == sha, "\(what): checksum")
        precondition(!FileManager.default.fileExists(atPath: part.path) && !FileManager.default.fileExists(atPath: ledger.path), "\(what): leftovers")
        try FileManager.default.removeItem(at: file)
    }
    func requests() throws -> Int { Int(String(decoding: try Data(contentsOf: url("stats")), as: UTF8.self))! }

    // 1. Pieces over parallel connections install and match.
    var before = try requests()
    try installed(await run(make(), model("fake.gguf")), "ranged")
    let pieces = Int((size + (1 << 20) - 1) / (1 << 20))
    let used = try requests() - before; precondition(used == pieces, "expected one request per piece, got \(used)")
    print("ok    \(pieces) pieces over 6 connections installed and verified (\(size / 1_000_000) MB)")

    // 2. Connections that drop mid-piece are retried.
    try installed(await run(make(), model("flaky/fake.gguf")), "flaky")
    print("ok    dropped connections retried")

    // 3. Stopped halfway (quit, sleep, wifi gone): a new downloader picks up the finished pieces.
    let first = make(2)
    let stopped: Task<Result<URL, Error>, Never> = Task { await run(first, model("slow/fake.gguf")) }
    try await Task.sleep(nanoseconds: 900_000_000)
    first.cancel()
    guard case .failure = await stopped.value else { fatalError("cancel didn't stop") }
    struct L: Decodable { let done: Set<Int> }
    let kept = try JSONDecoder().decode(L.self, from: Data(contentsOf: ledger)).done.count
    precondition(kept > 0 && kept < pieces, "kept \(kept) of \(pieces)")
    before = try requests()
    try installed(await run(make(), model("fake.gguf")), "resume")
    let refetched = try requests() - before; precondition(refetched == pieces - kept, "resume fetched \(refetched), expected \(pieces - kept)")
    print("ok    resumed after a stop: kept \(kept) of \(pieces) pieces, fetched only the rest")

    // 4. A server that ignores Range still works (one plain download).
    try installed(await run(make(), model("plain/fake.gguf")), "plain")
    print("ok    server without Range: plain download")

    // 5. Wrong checksum is thrown away, part file included.
    let bad = await run(make(), model("fake.gguf", sha: String(repeating: "0", count: 64)))
    guard case .failure(let e) = bad, e is HomieDownloadError else { fatalError("bad checksum accepted") }
    precondition(!FileManager.default.fileExists(atPath: HomieModels.folder.appendingPathComponent(name).path))
    precondition(!FileManager.default.fileExists(atPath: part.path) && !FileManager.default.fileExists(atPath: ledger.path))
    print("ok    corrupted file rejected: \(e.localizedDescription)")

    // 6. Missing file reports the HTTP status.
    let missing = await run(make(), .init(file: name, url: url("nope.gguf"), sha256: sha, size: size))
    guard case .failure(let m) = missing else { fatalError("404 accepted") }
    try? FileManager.default.removeItem(at: part); try? FileManager.default.removeItem(at: ledger)
    print("ok    missing file: \(m.localizedDescription)")
    print("HomieDownloader: all passed")
}}
extension HomieDownloader { typealias Model = HomieModels.Model }
