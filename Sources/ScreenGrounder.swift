import AppKit

/// homie's pointing eyes for things with no words: icons, faders, timeline handles in pro apps.
/// ScreenMarks tries on-screen text and the Accessibility tree first (instant, exact). When both miss, this asks
/// Holo3.1-4B (H Company, Apache-2.0, a Qwen3.5-4B fine-tune for GUI pointing) where the target is: one look at the
/// whole screen, then a second look at a zoomed crop around its guess. Measured 47% on ScreenSpot-Pro pro apps
/// (Tests/guide_eval), ~8–12 s per target on an M5. Full tier only: a separate 3.7 GB download after the brain, and
/// its own model server that starts on first use and quits after a few idle minutes, so it doesn't sit in memory.
@MainActor final class ScreenGrounder {
    static let shared = ScreenGrounder()

    static let model = HomieModels.Model(file: "Holo-3.1-4B.Q4_K_M.gguf",
                                         url: URL(string: "https://huggingface.co/prithivMLmods/Holo-3.1-4B-GGUF/resolve/c34254d35dd0f02af73f3e804abfcbc24cb0bb8a/Holo-3.1-4B.Q4_K_M.gguf")!,
                                         sha256: "44eaed360316d00fb66c2df346b3e307e8539aa08bb2ffca9a368fabfdfdab12", size: 3_066_386_016)
    static let vision = HomieModels.Model(file: "Holo-3.1-4B.mmproj-f16.gguf",
                                          url: URL(string: "https://huggingface.co/prithivMLmods/Holo-3.1-4B-GGUF/resolve/c34254d35dd0f02af73f3e804abfcbc24cb0bb8a/Holo-3.1-4B.mmproj-f16.gguf")!,
                                          sha256: "cc161b66cf68c15245ef0c86358481a709c6ea2af1e157e9a92d70a25bee0e39", size: 675_569_984)

    private let url = URL(string: "http://127.0.0.1:19879")!
    private let key = UUID().uuidString + UUID().uuidString
    private var server: Process?
    private var starting: Task<Bool, Never>?
    private var idle: Task<Void, Never>?
    private let downloader = HomieDownloader()

    private var files: (model: URL, vision: URL)? {
        guard let m = HomieModels.find(Self.model.file), let v = HomieModels.find(Self.vision.file) else { return nil }
        return (m, v)
    }
    var available: Bool { LocalBrain.tier == .full && files != nil }

    /// Full tier, once the brain and its own eyes are in: fetch the pointing eyes in the background, one file at a time.
    func prefetch() {
        guard LocalBrain.tier == .full, !downloader.running,
              let next = [Self.model, Self.vision].first(where: { HomieModels.find($0.file) == nil }) else { return }
        downloader.fetch(next) { result in
            if case .success = result { Task { @MainActor in ScreenGrounder.shared.prefetch() } }
        }
    }

    /// Where `target` is in this screenshot, as a normalized top-left point. nil when not installed or no usable answer.
    func locate(_ target: String, in image: CGImage) async -> CGPoint? {
        guard await start() else { return nil }
        defer { stopWhenIdle() }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        guard let first = await ask(target, image) else { return nil }
        // Second look: half the width and height around the first guess, 4× the detail (+13 points in the eval).
        let w = (W / 2).rounded(), h = (H / 2).rounded()
        let x0 = min(max(first.x * W - w / 2, 0), W - w).rounded(), y0 = min(max(first.y * H - h / 2, 0), H - h).rounded()
        guard let crop = image.cropping(to: CGRect(x: x0, y: y0, width: w, height: h)),
              let second = await ask(target, crop) else { return first }
        return CGPoint(x: (x0 + second.x * w) / W, y: (y0 + second.y * h) / H)
    }

    /// Load the model while ScreenMarks is still trying text and labels, so a miss doesn't also wait ~10–20 s for the load.
    func warm() {
        guard available else { return }
        Task { @MainActor in if await start() { stopWhenIdle() } }
    }

    func shutdown() {
        idle?.cancel(); starting?.cancel()
        if let server, server.isRunning { server.terminate() }
        server = nil; starting = nil
    }

    // MARK: Model server

    private func start() async -> Bool {
        if let starting { return await starting.value }
        let task = Task<Bool, Never> { @MainActor in
            if self.server?.isRunning != true, !self.launch() { return false }
            for _ in 0..<160 {   // first load reads 3.7 GB from disk: allow ~40 s
                var r = URLRequest(url: self.url.appendingPathComponent("health")); r.timeoutInterval = 1
                r.setValue("Bearer \(self.key)", forHTTPHeaderField: "Authorization")
                if let (_, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
                guard self.server?.isRunning == true, !Task.isCancelled else { return false }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return false
        }
        starting = task
        let ok = await task.value
        if !ok { starting = nil; shutdown() }   // a server that's up keeps `starting` as its answer
        return ok
    }

    private func launch() -> Bool {
        guard let files else { return false }
        let support = HomieModels.folder.deletingLastPathComponent()
        let keyFile = support.appendingPathComponent("grounder-key.txt"), log = support.appendingPathComponent("grounder.log")
        do {
            try key.write(to: keyFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let p = Process(); p.executableURL = HomieModels.llamaServer
            p.qualityOfService = .userInitiated
            // 1024 image tokens: 256 (what the brain uses for circled crops) can't point at all (5% in the eval).
            p.arguments = ["-m", files.model.path, "--mmproj", files.vision.path, "--image-max-tokens", "1024",
                           "--host", "127.0.0.1", "--port", "19879", "--api-key-file", keyFile.path,
                           "-c", "4096", "-np", "1", "--reasoning", "off", "--jinja"]
            if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
            p.terminationHandler = { _ in Task { @MainActor in ScreenGrounder.shared.server = nil; ScreenGrounder.shared.starting = nil } }
            try p.run(); server = p
            return true
        } catch { return false }
    }

    /// ~3.7 GB in memory while loaded: let it go after a few quiet minutes.
    private func stopWhenIdle() {
        idle?.cancel()
        idle = Task { @MainActor in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled else { return }
            ScreenGrounder.shared.shutdown()
        }
    }

    // MARK: Asking

    /// H Company's own localization prompt for Holo (hai-cookbook); answers {"x": 0-1000, "y": 0-1000}.
    nonisolated static func prompt(_ target: String) -> String {
        "Localize an element on the GUI image according to the provided target and output a click position.\n"
            + " * You must output a valid JSON following the format: {\"x\": int 0-1000, \"y\": int 0-1000}\n"
            + " Your target is:\n\(target)"
    }

    private func ask(_ target: String, _ image: CGImage) async -> CGPoint? {
        // ≤1400 px: same accuracy as full Retina in the eval, and a much smaller upload.
        guard let picture = await Task.detached(priority: .userInitiated, operation: { ScreenPeek.jpegDataURL(image, maxSide: 1400) }).value else { return nil }
        var req = URLRequest(url: url.appendingPathComponent("v1/chat/completions"))
        req.httpMethod = "POST"; req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = ["messages": [["role": "user", "content": [
                                       ["type": "image_url", "image_url": ["url": picture]],
                                       ["type": "text", "text": Self.prompt(target)]]]],
                                   "temperature": 0, "max_tokens": 48, "cache_prompt": false]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = data
        guard let (reply, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let text = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String else { return nil }
        return Self.parse(text)
    }

    /// A point in 0…1 from {"x": .., "y": ..}, point_2d/bbox_2d (box → its center) or a bare pair of numbers.
    nonisolated static func parse(_ text: String) -> CGPoint? {
        let cleaned = text.replacingOccurrences(of: #"\w+_2d"#, with: "", options: .regularExpression)   // never read the "2" in point_2d
        guard let regex = try? NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#) else { return nil }
        let nums = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            .compactMap { Range($0.range, in: cleaned).flatMap { Double(cleaned[$0]) } }
        let x: Double, y: Double
        if text.contains("bbox"), nums.count >= 4 { x = (nums[0] + nums[2]) / 2; y = (nums[1] + nums[3]) / 2 }
        else if nums.count >= 2 { x = nums[0]; y = nums[1] }
        else { return nil }
        return CGPoint(x: min(max(x / 1000, 0), 1), y: min(max(y / 1000, 0), 1))
    }
}
