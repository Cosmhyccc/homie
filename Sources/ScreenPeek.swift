import AppKit
import Vision

/// homie's local eyes. When you circle something on screen, the circled area is read on this Mac with Apple's
/// on-device text recognition and image labels, and handed to the local brain as text. No image leaves the Mac,
/// no extra model in memory, about 0.1–0.4 s.
enum ScreenPeek {
    @MainActor static func read() async -> String? {
        let points = ScreenInk.shared.strokes.filter { !$0.assistant }.flatMap(\.points)
        guard points.count > 2, let image = try? await ScreenVision().captureImage() else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
        // Strokes are fractions of the screen, top-left origin: crop the circled box plus a little margin.
        let xs = points.map(\.x), ys = points.map(\.y)
        let pad = 0.03
        let box = CGRect(x: max(0, xs.min()! - pad), y: max(0, ys.min()! - pad),
                         width: min(1, xs.max()! + pad) - max(0, xs.min()! - pad), height: min(1, ys.max()! + pad) - max(0, ys.min()! - pad))
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let crop = image.cropping(to: CGRect(x: box.minX * w, y: box.minY * h, width: box.width * w, height: box.height * h)) else { return nil }
        let note = await Task.detached(priority: .userInitiated) { describe(crop) }.value
        Diagnostics.shared.record("local_peek_ms", category: note == nil ? "empty" : "read", number: Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
        return note
    }

    /// Text inside the circle (top to bottom) and what the picture looks like.
    nonisolated static func describe(_ image: CGImage) -> String? {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let labels = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([text, labels])
        let lines = (text.results ?? [])
            .sorted { $0.boundingBox.maxY == $1.boundingBox.maxY ? $0.boundingBox.minX < $1.boundingBox.minX : $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        let words = String(lines.joined(separator: " · ").prefix(900))
        let looks = (labels.results ?? []).filter { $0.confidence > 0.3 }.prefix(3).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        guard !words.isEmpty || !looks.isEmpty else { return nil }
        var note = "They circled part of their screen."
        if !words.isEmpty { note += " Text inside the circle: \"\(words)\"." }
        if !looks.isEmpty { note += " It looks like: \(looks.joined(separator: ", "))." }
        return note
    }
}
