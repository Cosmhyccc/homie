import CryptoKit
import Foundation

/// Where homie's engines and brain live, and getting the brain onto a fresh Mac.
/// The engines (llama-server, voice helper) ship inside the app. The brain is a 1.3–2.7 GB file fetched once from
/// Hugging Face at a pinned commit and checked against its SHA-256 before it is ever loaded.
enum HomieModels {
    struct Model: Sendable {
        let file: String, url: URL, sha256: String, size: Int64
    }
    static func model(_ tier: LocalBrain.Tier) -> Model {
        switch tier {
        case .full: return Model(file: "Qwen3.5-4B-Q4_K_M.gguf",
                                 url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/Qwen3.5-4B-Q4_K_M.gguf")!,
                                 sha256: "00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4", size: 2_740_937_888)
        case .lite: return Model(file: "Qwen3.5-2B-Q4_K_M.gguf",
                                 url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/f6d5376be1edb4d416d56da11e5397a961aca8ae/Qwen3.5-2B-Q4_K_M.gguf")!,
                                 sha256: "aaf42c8b7c3cab2bf3d69c355048d4a0ee9973d48f16c731c0520ee914699223", size: 1_280_835_840)
        }
    }

    /// Engines bundled in the app; the dev folder is the fallback for local builds without them.
    static var helpers: URL? {
        let folder = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/homie")
        return FileManager.default.isExecutableFile(atPath: folder.appendingPathComponent("llama-server").path) ? folder : nil
    }
    static var llamaServer: URL { helpers?.appendingPathComponent("llama-server") ?? LocalBrain.assets.appendingPathComponent("runtime/llama-b11912/llama-server") }
    static var voiceHelper: URL { helpers?.appendingPathComponent("PixieVoice") ?? LocalBrain.assets.appendingPathComponent("voice/native/PixieVoice") }

    nonisolated static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pixie/Local/models")
    }
    /// The 4B's vision add-on: lets homie look at what you circle instead of only reading its text.
    /// Full tier only; 8 GB Macs skip it to keep ~0.7 GB free. Same pinned commit as the brain.
    static let vision = Model(file: "mmproj-F16.gguf",
                              url: URL(string: "https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/e87f176479d0855a907a41277aca2f8ee7a09523/mmproj-F16.gguf")!,
                              sha256: "cd88edcf8d031894960bb0c9c5b9b7e1fea6ebee02b9f7ce925a00d12891f864", size: 672_423_616)
    static func installedVision(_ tier: LocalBrain.Tier) -> URL? { tier == .full ? find(vision.file) : nil }

    /// The installed brain for this tier, or nil when it still needs downloading.
    static func installed(_ tier: LocalBrain.Tier) -> URL? { find(model(tier).file) }
    static func find(_ file: String) -> URL? {
        for candidate in [folder.appendingPathComponent(file), LocalBrain.assets.appendingPathComponent("models/\(file)")]
        where FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }

    /// Streams a file through SHA-256 without loading it into memory.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum HomieDownloadError: LocalizedError {
    case space(Int64), status(Int), size, checksum
    var errorDescription: String? {
        switch self {
        case .space(let need): return "homie needs about \(need / 1_000_000_000 + 1) GB free to download its brain."
        case .status(let code): return "The download didn't go through (HTTP \(code)). Try again in a bit."
        case .size, .checksum: return "The download came out corrupted, so homie threw it away. Try again."
        }
    }
}

/// One download at a time: 32 MB pieces over 6 connections (Hugging Face gives one connection ~4 MB/s, six ~15 MB/s),
/// written straight into `<file>.part`. A small ledger next to it records finished pieces, so a dropped connection,
/// a quit or a restart picks up where it left off. The whole file is checked against its SHA-256 before install.
/// Servers that ignore Range get one plain download instead.
final class HomieDownloader: @unchecked Sendable {
    private(set) var progress: Double = 0
    private(set) var running = false
    /// Fraction done, and seconds left once there's a few seconds of speed to go on.
    var onProgress: ((Double, Double?) -> Void)?
    var connections = 6
    var piece: Int64 = 32 << 20

    private struct Ledger: Codable { var sha256: String; var size: Int64; var piece: Int64; var done: Set<Int> }
    private let lock = NSLock()
    private var ledger = Ledger(sha256: "", size: 0, piece: 0, done: [])
    private var finished: Int64 = 0
    private var queue: ArraySlice<Int> = []
    private var job: Task<Void, Never>?
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = nil; c.timeoutIntervalForRequest = 30; c.httpMaximumConnectionsPerHost = connections
        return URLSession(configuration: c)
    }()

    func fetch(_ model: HomieModels.Model, done: @escaping (Result<URL, Error>) -> Void) {
        guard !running else { return }
        let part = HomieModels.folder.appendingPathComponent(model.file + ".part")
        let resuming = FileManager.default.fileExists(atPath: part.path)
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard free > (resuming ? 0 : model.size) + 1_000_000_000 else { done(.failure(HomieDownloadError.space(model.size))); return }
        running = true; progress = 0
        job = Task { [self] in
            let ticker = Task { await tick(model.size) }
            let result = await run(model, part: part)
            ticker.cancel()
            if case .success = result { progress = 1; onProgress?(1, 0) }
            running = false; job = nil
            done(result)
        }
    }

    /// Stops after the pieces in flight; the next fetch resumes from the ledger.
    func cancel() { job?.cancel() }

    private func run(_ model: HomieModels.Model, part: URL) async -> Result<URL, Error> {
        let fm = FileManager.default, record = part.appendingPathExtension("json")
        do {
            try fm.createDirectory(at: HomieModels.folder, withIntermediateDirectories: true)
            let saved = (try? Data(contentsOf: record)).flatMap { try? JSONDecoder().decode(Ledger.self, from: $0) }
            let partSize = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.int64Value
            if let saved, saved.sha256 == model.sha256, saved.size == model.size, saved.piece == piece, partSize == model.size {
                ledger = saved
            } else {
                try? fm.removeItem(at: part)
                guard fm.createFile(atPath: part.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                let h = try FileHandle(forWritingTo: part); try h.truncate(atOffset: UInt64(model.size)); try h.close()
                ledger = Ledger(sha256: model.sha256, size: model.size, piece: piece, done: [])
                try save(record)
            }
            let count = Int((model.size + piece - 1) / piece)
            finished = ledger.done.reduce(0) { $0 + length($1, model.size) }
            var pending = (0..<count).filter { !ledger.done.contains($0) }
            // The first piece alone tells us whether the server honours Range.
            if let first = pending.first {
                if try await get(first, model, part: part, record: record, probe: true) { pending.removeFirst() } else { pending = [] }
            }
            queue = pending[...]
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<min(connections, pending.count) {
                    group.addTask { [self] in
                        while let i = lock.withLock({ queue.popFirst() }) { _ = try await get(i, model, part: part, record: record, probe: false) }
                    }
                }
                try await group.waitForAll()
            }
            guard try HomieModels.sha256(of: part) == model.sha256 else {
                try? fm.removeItem(at: part); try? fm.removeItem(at: record)
                throw HomieDownloadError.checksum
            }
            let destination = HomieModels.folder.appendingPathComponent(model.file)
            try? fm.removeItem(at: destination)
            try fm.moveItem(at: part, to: destination)
            try? fm.removeItem(at: record)
            return .success(destination)
        } catch { return .failure(error) }
    }

    private func length(_ i: Int, _ size: Int64) -> Int64 { min(size, Int64(i + 1) * piece) - Int64(i) * piece }

    /// Fetches one piece into place, retrying dropped connections. Returns false when the server ignored Range
    /// and sent the whole file, which then becomes the part file as is.
    private func get(_ i: Int, _ model: HomieModels.Model, part: URL, record: URL, probe: Bool) async throws -> Bool {
        let start = Int64(i) * piece, count = length(i, model.size)
        var request = URLRequest(url: model.url)
        request.setValue("bytes=\(start)-\(start + count - 1)", forHTTPHeaderField: "Range")
        var attempt = 0, last: Error = HomieDownloadError.size
        while true {
            try Task.checkCancellation()
            do {
                let (tmp, response) = try await session.download(for: request)
                defer { try? FileManager.default.removeItem(at: tmp) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let got = (try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as? NSNumber)?.int64Value ?? -1
                if status == 200, probe, got == model.size {
                    try? FileManager.default.removeItem(at: part)
                    try FileManager.default.moveItem(at: tmp, to: part)
                    try lock.withLock { ledger.done = Set(0..<Int((model.size + piece - 1) / piece)); finished = model.size; try save(record) }
                    return false
                }
                if status == 206, got == count {
                    let from = try FileHandle(forReadingFrom: tmp), to = try FileHandle(forWritingTo: part)
                    defer { try? from.close(); try? to.close() }
                    try to.seek(toOffset: UInt64(start))
                    while let chunk = try from.read(upToCount: 4 << 20), !chunk.isEmpty { try to.write(contentsOf: chunk) }
                    try lock.withLock { ledger.done.insert(i); finished += count; try save(record) }
                    return true
                }
                // Client errors other than rate limits won't fix themselves.
                if (400..<500).contains(status), status != 408, status != 429 { throw HomieDownloadError.status(status) }
                if status != 206 { last = HomieDownloadError.status(status) }
            } catch let error as HomieDownloadError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch { last = error }
            attempt += 1
            guard attempt <= 5 else { throw last }
            try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
        }
    }

    private func save(_ record: URL) throws { try JSONEncoder().encode(ledger).write(to: record, options: .atomic) }

    /// Twice a second: finished pieces plus bytes in flight, and time left from the last ~15 s of speed.
    private func tick(_ size: Int64) async {
        var samples: [(TimeInterval, Int64)] = []
        while !Task.isCancelled {
            let inFlight = await session.allTasks.reduce(Int64(0)) { $0 + ($1.state == .running ? $1.countOfBytesReceived : 0) }
            let total = min(size, lock.withLock { finished } + inFlight), now = ProcessInfo.processInfo.systemUptime
            samples.append((now, total)); samples.removeAll { now - $0.0 > 15 }
            var left: Double?
            if let first = samples.first, now - first.0 >= 5, total > first.1 { left = Double(size - total) / (Double(total - first.1) / (now - first.0)) }
            progress = min(0.999, Double(total) / Double(size))
            onProgress?(progress, left)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}
