import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

/// Turns a file the user attached to a chat into text the brain can read. All of it runs on this Mac:
/// PDF text via PDFKit, text in images via Vision's text recognition (plus rough image labels), plain files as-is.
/// Scanned PDFs (no text layer) get their first pages run through text recognition too.
enum ChatAttachmentReader {
    static let maxFiles = 4
    static let maxBytes = 30 * 1024 * 1024
    static let types: [UTType] = [.image, .pdf, .plainText, .utf8PlainText, .text, .sourceCode, .json, .commaSeparatedText, .xml, .yaml, .html]

    enum Failure: LocalizedError {
        case tooBig(String), unreadable(String), locked(String), empty(String), unsupported(String)
        var errorDescription: String? {
            switch self {
            case .tooBig(let n): return "\(n) is over 30 MB."
            case .unreadable(let n): return "Couldn’t read \(n)."
            case .locked(let n): return "\(n) is password-protected."
            case .empty(let n): return "No text or picture homie can read in \(n)."
            case .unsupported(let n): return "\(n) isn’t an image, PDF or text file."
            }
        }
    }

    /// Reads one file off the main thread. `budget` is how many characters of text to keep.
    static func read(_ url: URL, budget: Int) async throws -> ChatAttachment {
        try await Task.detached(priority: .userInitiated) { try readNow(url, budget: budget) }.value
    }

    static func readNow(_ url: URL, budget: Int) throws -> ChatAttachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey])
        if values?.isDirectory == true { throw Failure.unsupported(name) }
        if let size = values?.fileSize, size > maxBytes { throw Failure.tooBig(name) }
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        if type.conforms(to: .pdf) { return try pdf(url, name: name, budget: budget) }
        if type.conforms(to: .image) { return try image(url, name: name, budget: budget) }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json) { return try text(url, name: name, budget: budget) }
        throw Failure.unsupported(name)
    }

    // MARK: kinds

    private static func text(_ url: URL, name: String, budget: Int) throws -> ChatAttachment {
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
        let full = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { throw Failure.empty(name) }
        return ChatAttachment(name: name, kind: .text, text: String(full.prefix(budget)), truncated: full.count > budget)
    }

    private static func image(_ url: URL, name: String, budget: Int) throws -> ChatAttachment {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.unreadable(name) }
        let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 640] as CFDictionary)
        let big = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                 kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary)
        let (lines, looks) = recognize(picture)
        var text = ""
        if !lines.isEmpty { text += "Text in the image:\n" + lines.joined(separator: "\n") }
        if !looks.isEmpty { text += (text.isEmpty ? "" : "\n") + "It looks like: " + looks.joined(separator: ", ") + "." }
        if text.isEmpty { text = "No readable text in the image." }
        return ChatAttachment(name: name, kind: .image, text: String(text.prefix(budget)), preview: thumb.flatMap(jpeg), truncated: text.count > budget,
                              picture: big.flatMap(jpeg))
    }

    private static func pdf(_ url: URL, name: String, budget: Int) throws -> ChatAttachment {
        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable(name) }
        if doc.isLocked { throw Failure.locked(name) }
        let count = doc.pageCount
        guard count > 0 else { throw Failure.empty(name) }
        var text = "", truncated = false
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let body = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let chunk = (count > 1 ? "[page \(i + 1)]\n" : "") + body + "\n\n"
            if text.count + chunk.count > budget { text += String(chunk.prefix(max(0, budget - text.count))); truncated = true; break }
            text += chunk
        }
        // Scanned PDF: no text layer, so read the first pages like pictures.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 20 {
            text = ""
            for i in 0..<min(count, 3) {
                guard let page = doc.page(at: i), let picture = render(page, longEdge: 1800) else { continue }
                let lines = recognize(picture).lines
                if !lines.isEmpty { text += (count > 1 ? "[page \(i + 1)]\n" : "") + lines.joined(separator: "\n") + "\n\n" }
            }
            truncated = count > 3 || text.count > budget
            text = String(text.prefix(budget))
        }
        let preview = doc.page(at: 0).flatMap { render($0, longEdge: 640) }.flatMap(jpeg)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure.empty(name) }
        return ChatAttachment(name: name, kind: .pdf, text: text.trimmingCharacters(in: .whitespacesAndNewlines), preview: preview, pages: count, truncated: truncated)
    }

    // MARK: helpers

    /// Lines of text top to bottom, and up to three rough labels for what the picture shows.
    static func recognize(_ picture: CGImage) -> (lines: [String], looks: [String]) {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        let labels = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: picture).perform([text, labels])
        let lines = (text.results ?? [])
            .sorted { $0.boundingBox.maxY == $1.boundingBox.maxY ? $0.boundingBox.minX < $1.boundingBox.minX : $0.boundingBox.maxY > $1.boundingBox.maxY }
            .compactMap { $0.topCandidates(1).first?.string }
        let looks = (labels.results ?? []).filter { $0.confidence > 0.3 }.prefix(3).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        return (lines, Array(looks))
    }

    private static func render(_ page: PDFPage, longEdge: CGFloat) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = longEdge / max(box.width, box.height)
        let size = NSSize(width: box.width * scale, height: box.height * scale)
        return page.thumbnail(of: size, for: .mediaBox).cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private static func jpeg(_ picture: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: picture).representation(using: .jpeg, properties: [.compressionFactor: 0.72])
    }
}
