import AppKit
import Vision

/// homie's local eyes. When you circle something on screen, the circled area is read on this Mac with Apple's
/// on-device text recognition and image labels. With the vision add-on (full tier) the crop also goes to the
/// local brain as a picture, so it can say what things are, not just read them. Nothing leaves the Mac.
enum ScreenPeek {
    struct Peek { var note: String?; var image: String? }

    @MainActor static func read(picture: Bool = false) async -> Peek? {
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
        let peek = await Task.detached(priority: .userInitiated) {
            Peek(note: describe(crop, picture: picture), image: picture ? jpegDataURL(crop) : nil)
        }.value
        Diagnostics.shared.record("local_peek_ms", category: peek.image != nil ? "picture" : peek.note == nil ? "empty" : "read",
                                  number: Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
        return peek.note == nil && peek.image == nil ? nil : peek
    }

    /// The crop as a JPEG data URL, longest side at most 1024 px (the brain reads it at ≤256 image tokens anyway).
    nonisolated static func jpegDataURL(_ image: CGImage) -> String? {
        let scale = min(1, 1024 / CGFloat(max(image.width, image.height)))
        let size = NSSize(width: max(1, CGFloat(image.width) * scale), height: max(1, CGFloat(image.height) * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        return "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    /// Text inside the circle (top to bottom) and what the picture looks like.
    nonisolated static func describe(_ image: CGImage, picture: Bool = false) -> String? {
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
        if picture {
            // The model sees the picture; the exact text still helps it quote small print correctly.
            return "They circled part of their screen; the circled area is the attached picture."
                + (words.isEmpty ? "" : " Text recognized inside it: \"\(words)\".")
        }
        guard !words.isEmpty || !looks.isEmpty else { return nil }
        var note = "They circled part of their screen."
        if !words.isEmpty { note += " Text inside the circle: \"\(words)\"." }
        if !looks.isEmpty { note += " It looks like: \(looks.joined(separator: ", "))." }
        return note
    }
}
