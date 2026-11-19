import AppKit
import Vision

/// homie points at your real screen. The model says *what* to mark ("circle Send; underline deadline; arrow Settings | click here")
/// and homie finds *where*: Apple's on-device text recognition gives the box of every word on screen, and the Accessibility
/// tree gives the frame of every control in the front app. The marks go through ScreenInk, so they animate and the companion
/// cursor flies to each one. No coordinates from the model, no image leaves the Mac.
enum ScreenMarks {
    static let tool: [String: Any] = [
        "type": "function", "name": "mark_screen",
        "description": "Point things out on the user's screen while you talk: circle, underline, box or arrow to text or buttons that are visible. marks: separated by ';', each 'mark target | label' with mark circle, underline, box, arrow or point; target is the exact words shown on screen or a button's name; label is optional. Use 'it' as the target for what the user circled. Example: circle Send; underline due Friday; arrow Settings | click here",
        "parameters": ["type": "object", "properties": ["marks": ["type": "string"]], "required": ["marks"], "additionalProperties": false], "strict": true
    ]
    static func owns(_ name: String) -> Bool { name == "mark_screen" }

    struct Mark { var kind: String; var target: String; var label: String }

    static func parse(_ raw: String) -> [Mark] {
        raw.split(whereSeparator: { $0 == ";" || $0 == "\n" }).prefix(8).compactMap { piece in
            let halves = piece.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            var words = halves[0].split(separator: " ").map(String.init)
            guard !words.isEmpty else { return nil }
            let verbs = ["circle": "circle", "underline": "underline", "box": "box", "highlight": "box", "arrow": "arrow", "point": "point", "pointer": "point"]
            let kind = verbs[words[0].lowercased().trimmingCharacters(in: .punctuationCharacters)] ?? "circle"
            if verbs[words[0].lowercased().trimmingCharacters(in: .punctuationCharacters)] != nil { words.removeFirst() }
            if let first = words.first?.lowercased(), ["to", "at", "on"].contains(first) { words.removeFirst() }
            let target = words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "'\"“”‘’ "))
            guard !target.isEmpty else { return nil }
            return Mark(kind: kind, target: target, label: halves.count > 1 ? String(halves[1].prefix(40)) : "")
        }
    }

    /// Words that describe a target rather than appear on screen ("the Send button" → "Send").
    static func core(_ target: String) -> String {
        let filler: Set<String> = ["the", "a", "an", "button", "icon", "word", "words", "text", "link", "tab", "menu", "field", "option", "toggle", "switch", "that", "says", "labeled", "called"]
        let kept = target.lowercased().split(separator: " ").map(String.init).filter { !filler.contains($0) }
        return kept.isEmpty ? target.lowercased() : kept.joined(separator: " ")
    }

    // MARK: Finding things

    struct Found { var rect: CGRect; var how: String }   // rect: normalized screen coordinates, top-left origin

    /// Every recognized line with its box, from one screenshot. Vision boxes are bottom-left normalized; flip to top-left.
    nonisolated static func readLines(_ image: CGImage) -> [(text: String, box: CGRect, observation: VNRecognizedText)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { line in
            guard let best = line.topCandidates(1).first else { return nil }
            let b = line.boundingBox
            return (best.string, CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height), best)
        }
    }

    /// The best on-screen box for a target: exact phrase inside a line, then whole-word overlap.
    nonisolated static func find(_ target: String, in lines: [(text: String, box: CGRect, observation: VNRecognizedText)]) -> CGRect? {
        let want = core(target)
        guard !want.isEmpty else { return nil }
        var best: (score: Double, rect: CGRect)?
        for line in lines {
            let lower = line.text.lowercased()
            if let range = lower.range(of: want) {
                // Box of just the matching words, not the whole line.
                let original = line.text.index(line.text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))
                let end = line.text.index(original, offsetBy: want.count, limitedBy: line.text.endIndex) ?? line.text.endIndex
                var rect = line.box
                if let sub = try? line.observation.boundingBox(for: original..<end) {
                    let b = sub.boundingBox; rect = CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)
                }
                let score = 2 + (lower == want ? 1 : 0) - Double(lower.count) / 400
                if score > (best?.score ?? 0) { best = (score, rect) }
                continue
            }
            let lineWords = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let targetWords = want.split(separator: " ").map(String.init)
            let hits = targetWords.filter { lineWords.contains($0) }.count
            guard targetWords.count > 1, hits * 3 >= targetWords.count * 2 else { continue }
            let score = Double(hits) / Double(targetWords.count)
            if score > (best?.score ?? 0) { best = (score, line.box) }
        }
        return best?.rect
    }

    /// A control in the front app whose title, description or help matches. AX frames are global top-left points.
    @MainActor static func control(_ target: String, on screen: NSScreen) -> CGRect? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let want = core(target)
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.3)
        // Window buttons (the traffic lights) are often unlabeled: ask the focused window for them directly.
        let windowButton: String? = ["close", "quit", "exit", "x", "red"].contains(want) ? kAXCloseButtonAttribute
            : ["minimize", "minimise", "yellow"].contains(want) ? kAXMinimizeButtonAttribute
            : ["full screen", "fullscreen", "maximize", "maximise", "zoom", "expand", "green"].contains(want) ? kAXFullScreenButtonAttribute : nil
        if let windowButton {
            var window: CFTypeRef?, button: CFTypeRef?
            if AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
               AXUIElementCopyAttributeValue(window as! AXUIElement, windowButton as CFString, &button) == .success, let button,
               let rect = frame(of: button as! AXUIElement, on: screen) { return rect }
        }
        var start: [AXUIElement] = [root]
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement], !list.isEmpty { start = list }
        var queue = start.map { ($0, 0) }, cursor = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 0.6
        func text(_ e: AXUIElement, _ key: String) -> String {
            var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, key as CFString, &v) == .success ? (v as? String ?? "") : ""
        }
        while cursor < queue.count, cursor < 2500, ProcessInfo.processInfo.systemUptime < deadline {
            let (node, depth) = queue[cursor]; cursor += 1
            let names = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute].map { text(node, $0).lowercased() }.filter { !$0.isEmpty && $0.count < 80 }
            if names.contains(where: { $0 == want || ($0.contains(want) && want.count >= 4) }) {
                if let rect = frame(of: node, on: screen) { return rect }
            }
            guard depth < 16 else { continue }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    /// An accessibility element's frame in this screen's normalized top-left space (AX uses the primary display's top-left).
    @MainActor static func frame(of node: AXUIElement, on screen: NSScreen) -> CGRect? {
        var p: CFTypeRef?, s: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, kAXPositionAttribute as CFString, &p) == .success,
              AXUIElementCopyAttributeValue(node, kAXSizeAttribute as CFString, &s) == .success, let p, let s else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &origin); AXValueGetValue(s as! AXValue, .cgSize, &size)
        guard size.width > 2, size.height > 2 else { return nil }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let top = primaryTop - screen.frame.maxY
        let rect = CGRect(x: (origin.x - screen.frame.minX) / screen.frame.width, y: (origin.y - top) / screen.frame.height,
                          width: size.width / screen.frame.width, height: size.height / screen.frame.height)
        return rect.intersects(CGRect(x: 0, y: 0, width: 1, height: 1)) ? rect : nil
    }

    /// "the close button", "settings icon": the user means a control, so real controls win over matching text.
    static func meansControl(_ target: String) -> Bool {
        let words = Set(target.lowercased().split(separator: " ").map(String.init))
        return !words.isDisjoint(with: ["button", "icon", "tab", "field", "toggle", "switch", "checkbox", "menu", "slider", "dropdown"])
    }

    // MARK: Marking

    @MainActor static func run(_ args: [String: Any], done: @escaping ([String: Any]) -> Void) {
        let marks = parse(args["marks"] as? String ?? "")
        guard !marks.isEmpty else { done(["status": "error", "message": "Say what to mark, like: circle Send; underline due Friday."]); return }
        let ink = ScreenInk.shared
        let started = ProcessInfo.processInfo.systemUptime
        let userMarks = ink.strokes.filter { !$0.assistant }.flatMap(\.points)
        let screen = (userMarks.isEmpty ? nil : ink.screen) ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { done(["status": "error", "message": "No screen to mark."]); return }
        Task { @MainActor in
            // One screenshot and one text pass for all marks; skip it when every target is the user's own circle.
            let needsText = marks.contains { !["it", "this", "that", "here"].contains($0.target.lowercased()) }
            var lines: [(text: String, box: CGRect, observation: VNRecognizedText)] = []
            if needsText, let image = try? await ScreenVision().captureImage() {
                lines = await Task.detached(priority: .userInitiated) { readLines(image) }.value
            }
            let snapshot = ink.captured(on: screen)
            var shown: [String] = [], missing: [String] = []
            for mark in marks {
                var rect: CGRect?
                if ["it", "this", "that", "here"].contains(mark.target.lowercased()), userMarks.count > 2 {
                    let xs = userMarks.map(\.x), ys = userMarks.map(\.y)
                    rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                } else {
                    rect = meansControl(mark.target)
                        ? control(mark.target, on: screen) ?? find(mark.target, in: lines)
                        : find(mark.target, in: lines) ?? control(mark.target, on: screen)
                }
                guard let rect else { missing.append(mark.target); continue }
                draw(mark, around: rect, snapshot: snapshot, aspect: Double(screen.frame.width / screen.frame.height))
                shown.append("\(mark.kind) \(mark.target)")
            }
            Diagnostics.shared.record("local_marks", category: missing.isEmpty ? "found" : shown.isEmpty ? "missing" : "partial",
                                      number: Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
            if shown.isEmpty {
                done(["status": "not_found", "message": "Couldn't find \(missing.joined(separator: ", ")) on screen. Say so briefly; don't guess where it is."])
            } else {
                done(["status": "marked", "marked": shown.joined(separator: ", "),
                      "not_found": missing.joined(separator: ", "), "message": "The marks are animating on screen now. Keep talking naturally."])
            }
        }
    }

    @MainActor private static func draw(_ mark: Mark, around r: CGRect, snapshot: String, aspect: Double) {
        let ink = ScreenInk.shared
        func c(_ v: CGFloat) -> Double { Double(min(0.995, max(0.005, v))) }
        var a: [String: Any] = ["snapshot": snapshot, "label": mark.label, "color": "auto", "width": "medium"]
        let padX = max(0.006, r.width * 0.12), padY = max(0.006 * aspect, r.height * 0.35)
        switch mark.kind {
        case "underline":
            a.merge(["shape": "underline", "x": c(r.minX), "y": c(r.maxY + r.height * 0.15), "x2": c(r.maxX), "y2": c(r.maxY + r.height * 0.15)]) { $1 }
        case "box":
            a.merge(["shape": "rectangle", "x": c(r.minX - padX / 2), "y": c(r.minY - padY / 2), "x2": c(r.maxX + padX / 2), "y2": c(r.maxY + padY / 2)]) { $1 }
        case "arrow":
            // From below-left toward the target's left edge, so the arrowhead lands next to it, not on it.
            let tx = r.minX - 0.005, ty = r.midY, len = 0.07
            a.merge(["shape": "arrow", "x": c(tx - len), "y": c(ty + len * aspect * 0.6), "x2": c(tx), "y2": c(ty)]) { $1 }
        case "point":
            a.merge(["shape": "pointer", "x": c(r.midX), "y": c(r.midY), "x2": c(r.midX), "y2": c(r.midY)]) { $1 }
        default:
            a.merge(["shape": "circle", "x": c(r.minX - padX), "y": c(r.minY - padY), "x2": c(r.maxX + padX), "y2": c(r.maxY + padY)]) { $1 }
        }
        _ = ink.execute(a)
    }
}
