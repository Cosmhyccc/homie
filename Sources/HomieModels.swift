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
    private static func find(_ file: String) -> URL? {
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

/// One download at a time, with progress, resume after a dropped connection, and a checksum before install.
final class HomieDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private(set) var progress: Double = 0
    private(set) var running = false
    private var model: HomieModels.Model?
    private var attempts = 0
    private var finished: ((Result<URL, Error>) -> Void)?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    var onProgress: ((Double) -> Void)?

    func fetch(_ model: HomieModels.Model, done: @escaping (Result<URL, Error>) -> Void) {
        guard !running else { return }
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage ?? .max
        guard free > model.size + 1_000_000_000 else { done(.failure(HomieDownloadError.space(model.size))); return }
        self.model = model; finished = done; running = true; attempts = 0; progress = 0
        session.downloadTask(with: model.url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : model?.size ?? 1
        progress = min(1, Double(totalBytesWritten) / Double(total))
        onProgress?(progress)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let model else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let result: Result<URL, Error>
        do {
            guard (200..<300).contains(status) else { throw HomieDownloadError.status(status) }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size == model.size else { throw HomieDownloadError.size }
            guard try HomieModels.sha256(of: location) == model.sha256 else { throw HomieDownloadError.checksum }
            try FileManager.default.createDirectory(at: HomieModels.folder, withIntermediateDirectories: true)
            let destination = HomieModels.folder.appendingPathComponent(model.file)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch { result = .failure(error) }
        finish(result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, running else { return }
        // A dropped connection keeps what it got: pick up where it left off, a few times.
        if let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data, attempts < 5 {
            attempts += 1
            DispatchQueue.global().asyncAfter(deadline: .now() + Double(attempts)) { [weak self] in
                self?.session.downloadTask(withResumeData: data).resume()
            }
            return
        }
        finish(.failure(error))
    }

    private func finish(_ result: Result<URL, Error>) {
        running = false
        let done = finished; finished = nil
        done?(result)
    }
}
