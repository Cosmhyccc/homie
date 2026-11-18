import AppKit

/// A transparent, nonactivating canvas. It intercepts input only while Fn is held.
final class ScreenInk {
    static let shared = ScreenInk()
    static let tool: [String: Any] = [
        "type": "function", "name": "draw_on_screen",
        "description": "Annotate the latest look_at_screen screenshot while explaining it. Use normalized 0..1 coordinates, origin top-left. Point with a short label, circle a region, underline, or draw an arrow. Only mark locations visible in that screenshot. Call once per useful annotation; do not cover the page. Refresh screenshot if stale.",
        "parameters": ["type": "object", "properties": [
            "snapshot": ["type": "string"],
            "shape": ["type": "string", "enum": ["circle", "rectangle", "line", "arrow", "underline", "pointer"]],
            "x": ["type": "number"], "y": ["type": "number"],
            "x2": ["type": "number"], "y2": ["type": "number"],
            "label": ["type": "string"], "color": ["type": "string", "enum": ["auto", "green", "yellow", "blue"]]
        ], "required": ["snapshot", "shape", "x", "y", "x2", "y2", "label", "color"], "additionalProperties": false], "strict": true
    ]
    static let clearTool: [String: Any] = [
        "type": "function", "name": "clear_screen_drawings", "description": "Remove all user and Pixie ink from the screen when asked to clear drawings.",
        "parameters": ["type": "object", "properties": [:] as [String: String], "required": [] as [String], "additionalProperties": false], "strict": true
    ]
    static let pathTool: [String: Any] = [
        "type": "function", "name": "draw_screen_path", "description": "Draw a polygon, connected straight lines, or a smooth curve on the latest screenshot. Normalized top-left coordinates. Supply 2 to 64 ordered points (at least 3 for polygon). Curve smoothly follows the supplied guide points, rounding corners. Use curve for handwritten numbers, letters and organic outlines; polygon/polyline only for intentional sharp corners.",
        "parameters": ["type": "object", "properties": [
            "snapshot": ["type": "string"], "shape": ["type": "string", "enum": ["polygon", "polyline", "curve"]],
            "points": ["type": "array", "minItems": 2, "maxItems": 64, "items": ["type": "object", "properties": ["x": ["type": "number"], "y": ["type": "number"]], "required": ["x", "y"], "additionalProperties": false]],
            "label": ["type": "string"], "color": ["type": "string", "enum": ["auto", "green", "yellow", "blue"]]
        ], "required": ["snapshot", "shape", "points", "label", "color"], "additionalProperties": false], "strict": true
    ]
    static let toolNames: Set<String> = ["look_at_screen", "clear_screen_drawings", "draw_on_screen", "draw_screen_path", "write_on_screen", "open_canvas", "close_canvas"]
    var conversationActive = false {
        didSet { if oldValue && !conversationActive { lastInk = Date() } }
    }
    static let userColor = NSColor.systemRed
    enum InkColor: String, CaseIterable {
        case green, yellow, blue, pink, purple, orange, red, white, black
        var value: NSColor {
            switch self {
            case .green: return .systemGreen; case .yellow: return .systemYellow; case .blue: return .systemBlue
            case .pink: return NSColor(red: 1.0, green: 0.36, blue: 0.62, alpha: 1); case .purple: return .systemPurple
            case .orange: return .systemOrange; case .red: return NSColor(red: 0.92, green: 0.2, blue: 0.22, alpha: 1)
            case .white: return .white; case .black: return NSColor(white: 0.12, alpha: 1)
            }
        }
        /// Readable label text on top of this color.
        var labelText: NSColor { [.blue, .purple, .red, .black, .pink].contains(self) ? .white : .black }
    }
    private var nextColor = 0
    static let maxStrokes = 120
    struct Stroke {
        var points: [CGPoint]; var label = ""; var assistant = false; var arrow = false; var color: InkColor = .green; var started = Date()
        var width: CGFloat = 5; var fill = false; var text: String? = nil; var textSize: CGFloat = 24; var duration: TimeInterval = 0.55
    }
    /// The summoned whiteboard, in normalized screen coordinates (top-left origin).
    private(set) var canvasRect: CGRect?
    private(set) var canvasStyle = "grid"
    private(set) var canvasOpened = Date.distantPast
    private var canvasID = ""
    /// Drawing still animating, so the overlay must keep repainting.
    var animating: Bool { strokes.contains { $0.assistant && Date().timeIntervalSince($0.started) < $0.duration + 0.4 } || Date().timeIntervalSince(canvasOpened) < 6 }
    private var panel: NSPanel?
    private var canvas: InkCanvas?
    private(set) var screen: NSScreen?
    private(set) var drawing = false
    private(set) var strokes: [Stroke] = []
    private var timer: Timer?
    private var monitor: Any?
    private var observer: NSObjectProtocol?
    private(set) var revision = 0
    private(set) var snapshot = ""
    private(set) var snapshotDate = Date.distantPast
    private var lastInk = Date.distantPast
    private var lastPointer: CGPoint?
    private var queueEnd = Date.distantPast
    var onFinish: ((Bool) -> Void)?
    init() {
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return }
            // The board is a real window: other apps' clicks, keys and scrolls never close it.
            if self.canvasRect != nil && !self.drawing { return }
            if event.type == .keyDown && event.keyCode == 53 { self.cancel(); return }
            guard !self.drawing, !self.screenshotting else { return }
            if event.type != .keyDown || event.keyCode == 53 || event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126 { self.clear() }
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, !self.drawing else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if let id = app?.bundleIdentifier, Self.screenshotApps.contains(id) { self.screenshotSeen = Date(); return }
            guard !self.screenshotting, self.canvasRect == nil else { return }
            self.clear()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.clear() }
    }
    /// Taking a screenshot (⌘⇧3/4/5) must not close her drawing: the capture overlay
    /// takes clicks and focus, then hands focus back to the previous app.
    private static let screenshotApps: Set<String> = ["com.apple.screencaptureui", "com.apple.Screenshot", "com.apple.screenshot.launcher"]
    private var screenshotSeen = Date.distantPast
    private var screenshotting: Bool {
        let owners = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowOwnerName as String] as? String }
        if owners.contains("screencaptureui") { screenshotSeen = Date() }
        return Date().timeIntervalSince(screenshotSeen) < 10
    }
    // MARK: Board window
    /// While a canvas is open it lives in its own normal-level window: drag it anywhere,
    /// let other apps cover it, and click Pixie to bring it back. × or Esc closes it.
    private var board: BoardPanel?
    private var boardHost: BoardHost?
    private var boardMoveObserver: NSObjectProtocol?
    private var placingBoard = false

    private func boardFrame(_ rect: CGRect, on screen: NSScreen) -> NSRect {
        let f = screen.frame
        return NSRect(x: f.minX + rect.minX * f.width, y: f.maxY - rect.maxY * f.height, width: rect.width * f.width, height: rect.height * f.height)
    }
    /// Puts the ink view in the board window while a canvas is open, otherwise in the full-screen overlay.
    private func placeInkView() {
        guard let canvas, let panel else { return }
        guard let rect = canvasRect, let screen else {
            if panel.contentView !== canvas { canvas.removeFromSuperview(); panel.contentView = canvas }
            board?.orderOut(nil)
            return
        }
        if board == nil {
            let b = BoardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            b.isOpaque = false; b.backgroundColor = .clear; b.hasShadow = true
            b.level = .normal; b.hidesOnDeactivate = false; b.isReleasedWhenClosed = false
            let host = BoardHost(); host.owner = self; b.contentView = host
            let close = BoardClose(); close.autoresizingMask = [.minXMargin]; host.addSubview(close)
            close.frame = NSRect(x: -44, y: 12, width: 28, height: 28)
            board = b; boardHost = host
            boardMoveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: b, queue: .main) { [weak self] _ in self?.boardMoved() }
        }
        guard let board, let host = boardHost else { return }
        if panel.contentView === canvas { panel.contentView = NSView() }
        if canvas.superview !== host { canvas.removeFromSuperview(); host.addSubview(canvas, positioned: .below, relativeTo: nil) }
        placingBoard = true
        board.setFrame(boardFrame(rect, on: screen), display: true)
        placingBoard = false
        canvas.frame = NSRect(x: -rect.minX * screen.frame.width, y: -rect.minY * screen.frame.height, width: screen.frame.width, height: screen.frame.height)
        panel.orderOut(nil)
    }
    private func boardMoved() {
        guard !placingBoard, let board, let rect = canvasRect, let screen else { return }
        let f = screen.frame
        let moved = CGRect(x: (board.frame.minX - f.minX) / f.width, y: (f.maxY - board.frame.maxY) / f.height, width: rect.width, height: rect.height)
        let dx = moved.minX - rect.minX, dy = moved.minY - rect.minY
        guard dx != 0 || dy != 0 else { return }
        canvasRect = moved
        for index in strokes.indices { strokes[index].points = strokes[index].points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) } }
        PixieCursor.shared.cancelTrips()
        canvas?.frame.origin = NSPoint(x: -moved.minX * f.width, y: -moved.minY * f.height)
        canvas?.needsDisplay = true
    }
    /// Brings a covered board back to the front. Returns false when there is nothing to raise.
    @discardableResult
    func raiseBoard() -> Bool {
        guard canvasRect != nil, let board, board.isVisible else { return false }
        let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], CGWindowID(board.windowNumber)) as? [[String: Any]] ?? []
        let covered = above.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0, let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let primary = NSScreen.screens.first else { return false }
            // CG bounds are top-left based; convert to Cocoa before comparing.
            let r = CGRect(x: b["X"] ?? 0, y: primary.frame.maxY - (b["Y"] ?? 0) - (b["Height"] ?? 0), width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            return r.intersects(board.frame)
        }
        guard covered else { return false }
        board.orderFrontRegardless()
        return true
    }
    func begin() {
        clear()
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        self.screen = screen
        drawing = true
        lastInk = Date()
        show(on: screen)
        lastPointer = nil
        samplePointer()
        panel?.ignoresMouseEvents = false
        print("Ink: drawing mode entered"); fflush(stdout)
        canvas?.needsDisplay = true
    }
    func end() {
        guard drawing else { return }
        drawing = false; panel?.ignoresMouseEvents = true
        lastInk = Date()
        onFinish?(strokes.contains { $0.points.count > 2 })
    }
    func cancel() { drawing = false; panel?.ignoresMouseEvents = true; clear(); onFinish?(false) }
    func clear() {
        lastPointer = nil
        revision += 1
        nextColor = 0
        strokes.removeAll(); snapshot = ""; screen = nil
        queueEnd = .distantPast; PixieCursor.shared.cancelTrips()
        canvasRect = nil; canvasID = ""
        placeInkView()
        panel?.orderOut(nil)
        canvas?.needsDisplay = true
    }
    private func show(on screen: NSScreen) {
        if panel == nil {
            let p = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false
            p.level = .floating; p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.hidesOnDeactivate = false; p.ignoresMouseEvents = true; p.acceptsMouseMovedEvents = true
            let view = InkCanvas(); view.owner = self; p.contentView = view
            panel = p; canvas = view
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.canvasRect == nil && self.panel?.isVisible == true && !self.drawing && !self.conversationActive && Date().timeIntervalSince(self.lastInk) > 45 { self.clear() }
                if self.drawing { self.samplePointer() }
                if self.drawing || self.animating { self.canvas?.needsDisplay = true }
            }
            RunLoop.main.add(t, forMode: .common); timer = t
        }
        if canvasRect != nil {
            placeInkView()
            board?.orderFrontRegardless()
        } else {
            placeInkView()
            panel?.setFrame(screen.frame, display: true); panel?.orderFrontRegardless()
        }
    }
    private func samplePointer() {
        guard drawing, let screen else { return }
        let global = NSEvent.mouseLocation
        guard screen.frame.contains(global) else { lastPointer = nil; return }
        let local = CGPoint(x: global.x-screen.frame.minX, y: screen.frame.maxY-global.y)
        if let previous = lastPointer, hypot(local.x-previous.x, local.y-previous.y) < 1.5 { return }
        point(local, new: lastPointer == nil)
        lastPointer = local
    }
    func point(_ p: CGPoint, new: Bool) {
        guard drawing, let canvas else { return }
        let point = CGPoint(x: min(1, max(0, p.x / canvas.bounds.width)), y: min(1, max(0, p.y / canvas.bounds.height)))
        if new { print("Ink: stroke began"); fflush(stdout); if strokes.count >= Self.maxStrokes { strokes.removeFirst() }; strokes.append(Stroke(points: [point])) }
        else if !strokes.isEmpty, strokes[strokes.count - 1].points.count < 4000 { strokes[strokes.count - 1].points.append(point) }
        canvas.needsDisplay = true
    }
    func captured(on screen: NSScreen) -> String {
        self.screen = screen; snapshot = UUID().uuidString; snapshotDate = Date(); lastInk = Date()
        return snapshot
    }
    /// Converts a drawing target into a mapping from tool coordinates to normalized screen coordinates.
    private func target(_ args: [String: Any]) -> ((CGPoint) -> CGPoint)? {
        guard !drawing, screen != nil, let id = args["snapshot"] as? String, !id.isEmpty else { return nil }
        if id == canvasID, let rect = canvasRect { return { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) } }
        guard id == snapshot, Date().timeIntervalSince(snapshotDate) < 60 else { return nil }
        return { $0 }
    }
    private func color(_ args: [String: Any]) -> InkColor? {
        let requested = args["color"] as? String ?? "auto"
        if let color = InkColor(rawValue: requested) { return color }
        guard requested == "auto" else { return nil }
        let palette: [InkColor] = canvasRect == nil ? [.green, .yellow, .blue] : [.blue, .pink, .purple, .orange, .green]
        defer { nextColor += 1 }
        return palette[nextColor % palette.count]
    }
    private static func width(_ args: [String: Any]) -> CGFloat {
        switch args["width"] as? String { case "thin": return 3; case "thick": return 10; default: return 5 }
    }
    private func add(_ stroke: Stroke) {
        guard let screen else { return }
        var stroke = stroke
        if stroke.assistant {
            let length = zip(stroke.points, stroke.points.dropFirst()).reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            stroke.duration = stroke.text != nil ? 0.4 : min(1.6, max(0.45, 0.3 + length * 1.4))
            let global = stroke.points.map { CGPoint(x: screen.frame.minX + $0.x * screen.frame.width, y: screen.frame.maxY - $0.y * screen.frame.height) }
            // Strokes queue up, so a batch of tool calls draws in order while Pixie keeps talking.
            let start = max(Date().addingTimeInterval(PixieCursor.flight), queueEnd.addingTimeInterval(0.12))
            queueEnd = start.addingTimeInterval(stroke.duration)
            stroke.started = start
            PixieCursor.shared.trace(global, start: start, duration: stroke.duration)
        }
        if strokes.count >= Self.maxStrokes { strokes.removeFirst() }
        strokes.append(stroke)
        lastInk = Date(); show(on: screen)
    }
    func execute(_ args: [String: Any]) -> [String: Any] {
        guard let map = target(args) else { return ["status": "stale", "message": "Look at the screen again (or open_canvas) before drawing."] }
        guard let shape = args["shape"] as? String, let points = args["points"] == nil ? Self.geometry(args) : Self.pathGeometry(args), let label = args["label"] as? String else { return ["status": "error", "message": "Invalid annotation coordinates."] }
        guard let color = color(args) else { return ["status": "error", "message": "Unsupported color."] }
        let closed = ["circle", "rectangle", "polygon", "heart", "star"].contains(shape)
        add(Stroke(points: points.map(map), label: String(label.prefix(48)), assistant: true, arrow: shape == "arrow", color: color,
                   width: Self.width(args), fill: closed && (args["fill"] as? Bool ?? false)))
        return ["status": "drawn", "shape": shape, "color": color.rawValue, "message": "Drawing is animating on screen. Keep going or explain it naturally."]
    }
    func write(_ args: [String: Any]) -> [String: Any] {
        guard let map = target(args) else { return ["status": "stale", "message": "Look at the screen again (or open_canvas) before writing."] }
        guard let text = (args["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              let x = args["x"] as? Double, let y = args["y"] as? Double, (0...1).contains(x), (0...1).contains(y) else { return ["status": "error", "message": "Give text and a 0..1 position."] }
        guard let color = color(args) else { return ["status": "error", "message": "Unsupported color."] }
        let size: CGFloat = ["small": 16, "large": 38, "title": 56][args["size"] as? String ?? ""] ?? 24
        add(Stroke(points: [map(CGPoint(x: x, y: y))], assistant: true, color: color, text: String(text.prefix(160)), textSize: size))
        return ["status": "drawn", "message": "Text is on screen."]
    }
    func openCanvas(_ args: [String: Any]) -> [String: Any] {
        guard !drawing else { return ["status": "error", "message": "The user is drawing; wait for them to finish."] }
        if canvasRect != nil, let screen {
            let ratio = (canvasRect!.width * screen.frame.width) / (canvasRect!.height * screen.frame.height)
            return ["status": "already_open", "snapshot": canvasID, "width_to_height": (ratio * 100).rounded() / 100,
                    "message": "The canvas is already open with the earlier drawing on it. Add to it with this snapshot ID; do not redraw what is there. Call close_canvas first only if the user wants a fresh board."]
        }
        let keep = strokes.filter { !$0.assistant }
        clear(); strokes = keep
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return ["status": "error", "message": "No screen available."] }
        self.screen = screen
        let style = args["style"] as? String ?? "grid"
        canvasStyle = ["grid", "dots", "blank"].contains(style) ? style : "grid"
        let width = 0.74, height = 0.74
        canvasRect = CGRect(x: (1 - width) / 2, y: 0.13, width: width, height: height)
        canvasID = "canvas-" + UUID().uuidString.prefix(8)
        canvasOpened = Date()
        lastInk = Date(); show(on: screen)
        let ratio = (width * screen.frame.width) / (height * screen.frame.height)
        return ["status": "opened", "snapshot": canvasID, "width_to_height": (ratio * 100).rounded() / 100,
                "message": "Canvas is open. Draw with this snapshot ID using 0..1 canvas coordinates (top-left origin). A circle looks round when its normalized height is width × width_to_height."]
    }
    func closeCanvas() -> [String: Any] { clear(); return ["status": "cleared"] }
    static func pathGeometry(_ args: [String: Any]) -> [CGPoint]? {
        guard let shape = args["shape"] as? String, ["polygon", "polyline", "curve"].contains(shape),
              let raw = args["points"] as? [[String: Any]], (2...64).contains(raw.count) else { return nil }
        var points: [CGPoint] = []
        for item in raw {
            guard let x = item["x"] as? Double, let y = item["y"] as? Double,
                  x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
            points.append(CGPoint(x: x, y: y))
        }
        if shape == "polygon" { guard points.count >= 3 else { return nil }; points.append(points[0]) }
        if shape != "curve" { return subdivide(points) }
        // Corner-cutting stays inside the guide-point bounds and avoids spline overshoot.
        // Keep endpoints anchored so neighboring strokes still join exactly.
        var curve = points
        for _ in 0..<3 {
            var rounded = [curve[0]]
            for i in 0..<curve.count-1 {
                let a = curve[i], b = curve[i+1]
                rounded.append(CGPoint(x: 0.75*a.x+0.25*b.x, y: 0.75*a.y+0.25*b.y))
                rounded.append(CGPoint(x: 0.25*a.x+0.75*b.x, y: 0.25*a.y+0.75*b.y))
            }
            rounded.append(curve.last!); curve = rounded
        }
        return curve
    }
    private static func subdivide(_ points: [CGPoint]) -> [CGPoint] {
        var result = [points[0]]
        for i in 1..<points.count {
            for step in 1...12 {
                let t = CGFloat(step)/12, a = points[i-1], b = points[i]
                result.append(step == 12 ? b : CGPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t))
            }
        }
        return result
    }
    static func geometry(_ a: [String: Any]) -> [CGPoint]? {
        guard let shape = a["shape"] as? String, ["circle", "rectangle", "line", "arrow", "underline", "pointer", "heart", "star", "check"].contains(shape) else { return nil }
        let values = ["x", "y", "x2", "y2"].compactMap { a[$0] as? Double }
        guard values.count == 4, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        let x = values[0], y = values[1], x2 = values[2], y2 = values[3]
        if shape == "rectangle" { return subdivide([CGPoint(x:x,y:y), CGPoint(x:x2,y:y), CGPoint(x:x2,y:y2), CGPoint(x:x,y:y2), CGPoint(x:x,y:y)]) }
        if shape == "circle" {
            let cx = (x + x2) / 2, cy = (y + y2) / 2
            return (0...72).map { i in let t = Double(i) / 72 * 2 * Double.pi; return CGPoint(x: cx + abs(x2-x)/2*cos(t), y: cy + abs(y2-y)/2*sin(t)) }
        }
        if shape == "pointer" { return [CGPoint(x: x, y: y), CGPoint(x: x + 0.0001, y: y)] }
        let box = { (u: Double, v: Double) in CGPoint(x: x + (x2 - x) * u, y: y + (y2 - y) * v) }
        if shape == "heart" {
            return (0...80).map { i in
                let t = Double(i) / 80 * 2 * Double.pi
                let hx = 16 * pow(sin(t), 3), hy = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                return box((hx + 16) / 32, (12 - hy) / 29)
            }
        }
        if shape == "star" {
            let corners = (0...10).map { i -> CGPoint in
                let angle = -Double.pi / 2 + Double(i) * Double.pi / 5, r = i % 2 == 0 ? 0.5 : 0.2
                return box(0.5 + r * cos(angle), 0.53 + r * 1.05 * sin(angle))
            }
            return subdivide(corners)
        }
        if shape == "check" { return subdivide([box(0, 0.55), box(0.35, 1), box(1, 0)]) }
        var points = (0...30).map { i in CGPoint(x: x + (x2-x)*Double(i)/30, y: y + (y2-y)*Double(i)/30) }
        if shape == "arrow" {
            // Keep the endpoint available for a pixel-sized arrowhead.
            points += [CGPoint(x: x2, y: y2)]
        }
        return points
    }
    func composite(_ image: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.translateBy(x: 0, y: CGFloat(image.height)); ctx.scaleBy(x: 1, y: -1)
        ctx.setStrokeColor(ScreenInk.userColor.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(5); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for stroke in strokes {
            ctx.setStrokeColor((stroke.assistant ? stroke.color.value : ScreenInk.userColor).withAlphaComponent(0.8).cgColor)
            guard let first = stroke.points.first else { continue }
            ctx.beginPath(); ctx.move(to: CGPoint(x: first.x * CGFloat(image.width), y: first.y * CGFloat(image.height)))
            for p in stroke.points.dropFirst() { ctx.addLine(to: CGPoint(x: p.x * CGFloat(image.width), y: p.y * CGFloat(image.height))) }; ctx.strokePath()
        }
        return ctx.makeImage() ?? image
    }
}

private final class InkCanvas: NSView {
    weak var owner: ScreenInk?
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { /* Fn movement owns the stroke; swallow clicks while drawing. */ }
    override func mouseDragged(with event: NSEvent) { /* Sampled in the common-mode animation timer. */ }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { owner?.cancel() } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        if owner.drawing {
            // Holding Fn must visibly acknowledge the mode even before the first stroke.
            let mouse = window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) } ?? .zero
            ScreenInk.userColor.withAlphaComponent(0.14).setFill()
            NSBezierPath(ovalIn: CGRect(x: mouse.x-15, y: mouse.y-15, width: 30, height: 30)).fill()
            ScreenInk.userColor.setStroke()
            let ring = NSBezierPath(ovalIn: CGRect(x: mouse.x-7, y: mouse.y-7, width: 14, height: 14)); ring.lineWidth = 2; ring.stroke()
            let text = "Move to draw · Release Fn to ask"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
            let size = (text as NSString).size(withAttributes: attributes)
            let box = CGRect(x: (bounds.width-size.width-32)/2, y: bounds.height-76, width: size.width+32, height: 38)
            NSColor.black.withAlphaComponent(0.8).setFill()
            NSBezierPath(roundedRect: box, xRadius: 19, yRadius: 19).fill()
            (text as NSString).draw(at: CGPoint(x: box.minX+16, y: box.minY+10), withAttributes: attributes)
        }
        if let rect = owner.canvasRect { drawBoard(CGRect(x: rect.minX * bounds.width, y: rect.minY * bounds.height, width: rect.width * bounds.width, height: rect.height * bounds.height), style: owner.canvasStyle, opened: owner.canvasOpened) }
        for stroke in owner.strokes {
            let progress = stroke.assistant ? min(1, max(0, Date().timeIntervalSince(stroke.started) / stroke.duration)) : 1
            if stroke.assistant && Date() < stroke.started { continue }
            if let text = stroke.text, let anchor = stroke.points.first {
                drawText(text, at: CGPoint(x: anchor.x * bounds.width, y: anchor.y * bounds.height), size: stroke.textSize, color: stroke.color.value, alpha: progress)
                continue
            }
            let count = max(1, Int(Double(stroke.points.count) * progress))
            let points = stroke.points.prefix(count).map { CGPoint(x: $0.x * bounds.width, y: $0.y * bounds.height) }
            guard let first = points.first, let last = points.last else { continue }
            let path = NSBezierPath(); path.move(to: first)
            if points.count > 2 && !stroke.assistant {
                for i in 1..<points.count {
                    let previous = points[i-1], current = points[i]
                    let midpoint = CGPoint(x: (previous.x+current.x)/2, y: (previous.y+current.y)/2)
                    let start = path.currentPoint
                    path.curve(to: midpoint,
                        controlPoint1: CGPoint(x: start.x+(previous.x-start.x)*2/3, y: start.y+(previous.y-start.y)*2/3),
                        controlPoint2: CGPoint(x: midpoint.x+(previous.x-midpoint.x)*2/3, y: midpoint.y+(previous.y-midpoint.y)*2/3))
                }
                path.line(to: last)
            } else { for point in points.dropFirst() { path.line(to: point) } }
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            let color = stroke.assistant ? stroke.color.value : ScreenInk.userColor
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow(); glow.shadowColor = color.withAlphaComponent(0.25); glow.shadowBlurRadius = 8; glow.set()
            if stroke.fill && progress == 1 {
                let age = Date().timeIntervalSince(stroke.started) - stroke.duration
                color.withAlphaComponent(0.85 * min(1, max(0, age / 0.25))).setFill(); path.fill()
            }
            color.withAlphaComponent(stroke.assistant && owner.canvasRect != nil ? 1 : 0.8).setStroke(); path.lineWidth = stroke.width; path.stroke()
            if stroke.arrow && progress == 1, points.count > 2 {
                let before = points[points.count - 3]
                let angle = atan2(last.y-before.y, last.x-before.x)
                let head = NSBezierPath(); head.move(to: CGPoint(x: last.x-15*cos(angle-0.5), y: last.y-15*sin(angle-0.5)))
                head.line(to: last); head.line(to: CGPoint(x: last.x-15*cos(angle+0.5), y: last.y-15*sin(angle+0.5)))
                head.lineWidth = stroke.width; head.lineCapStyle = .round; head.lineJoinStyle = .round; head.stroke()
            }
            if !stroke.fill { color.setFill(); NSBezierPath(ovalIn: CGRect(x: last.x-stroke.width*0.6, y: last.y-stroke.width*0.6, width: stroke.width*1.2, height: stroke.width*1.2)).fill() }
            NSGraphicsContext.restoreGraphicsState()
            if stroke.assistant && progress == 1 && !stroke.label.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: stroke.color.labelText]
                let size = (stroke.label as NSString).size(withAttributes: attrs)
                let box = CGRect(x: min(max(8, last.x+12), bounds.width-size.width-24), y: min(max(8, last.y+10), bounds.height-38), width: size.width+20, height: 30)
                color.withAlphaComponent(0.95).setFill(); NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9).fill()
                (stroke.label as NSString).draw(at: CGPoint(x: box.minX+10, y: box.minY+6), withAttributes: attrs)
            }
        }
    }

    private func drawBoard(_ rect: CGRect, style: String, opened: Date) {
        let t = min(1, Date().timeIntervalSince(opened) / 0.28)
        let ease = 1 - pow(1 - t, 3)
        let board = rect.insetBy(dx: rect.width * 0.04 * (1 - ease), dy: rect.height * 0.04 * (1 - ease))
        let shape = NSBezierPath(roundedRect: board, xRadius: 26, yRadius: 26)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow(); shadow.shadowColor = .black.withAlphaComponent(0.28 * ease); shadow.shadowBlurRadius = 30; shadow.shadowOffset = NSSize(width: 0, height: -8); shadow.set()
        NSColor(red: 0.99, green: 0.98, blue: 0.955, alpha: ease).setFill(); shape.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        let step: CGFloat = 32
        let ink = NSColor(red: 0.55, green: 0.62, blue: 0.78, alpha: 0.28 * ease)
        if style == "grid" {
            ink.setStroke()
            let grid = NSBezierPath(); grid.lineWidth = 1
            var x = board.minX + step; while x < board.maxX { grid.move(to: CGPoint(x: x, y: board.minY)); grid.line(to: CGPoint(x: x, y: board.maxY)); x += step }
            var y = board.minY + step; while y < board.maxY { grid.move(to: CGPoint(x: board.minX, y: y)); grid.line(to: CGPoint(x: board.maxX, y: y)); y += step }
            grid.stroke()
        } else if style == "dots" {
            ink.withAlphaComponent(0.5 * ease).setFill()
            var x = board.minX + step; while x < board.maxX { var y = board.minY + step; while y < board.maxY { NSBezierPath(ovalIn: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3)).fill(); y += step }; x += step }
        }
        NSGraphicsContext.restoreGraphicsState()
        let hint = "Pixie’s canvas · drag to move · × to close"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.black.withAlphaComponent(0.35 * ease * hintFade(opened))]
        (hint as NSString).draw(at: CGPoint(x: board.minX + 22, y: board.minY + 16), withAttributes: attrs)
    }
    /// The board hint shows for a few seconds, then gets out of the drawing's way.
    private func hintFade(_ opened: Date) -> CGFloat {
        let age = Date().timeIntervalSince(opened)
        return age < 5 ? 1 : max(0, 1 - CGFloat(age - 5) / 0.8)
    }
    private func drawText(_ text: String, at center: CGPoint, size: CGFloat, color: NSColor, alpha: Double) {
        let base = NSFont.systemFont(ofSize: size, weight: size >= 38 ? .heavy : .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(alpha), .paragraphStyle: style]
        // Wrap to the room on either side of the anchor, so text never runs off the board or screen.
        var room = bounds.width * 0.6
        if let rect = owner?.canvasRect {
            let left = rect.minX * bounds.width + 28, right = rect.maxX * bounds.width - 28
            if center.x > left && center.x < right { room = min(room, 2 * min(center.x - left, right - center.x)) }
        } else {
            room = min(room, 2 * min(center.x - 16, bounds.width - 16 - center.x))
        }
        // Comfortable reading: about 40 characters a line for labels, a little wider for titles.
        room = min(room, size * (size >= 38 ? 15 : 20))
        room = max(room, size * 5)
        let bounding = (text as NSString).boundingRect(with: CGSize(width: room, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin], attributes: attrs)
        let rect = CGRect(x: center.x - bounding.width / 2, y: center.y - bounding.height / 2 + (1 - alpha) * 6, width: bounding.width, height: bounding.height)
        (text as NSString).draw(with: rect, options: [.usesLineFragmentOrigin], attributes: attrs)
    }
}

private final class BoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Hosts the ink view inside the board window; handles dragging, × and Esc.
private final class BoardHost: NSView {
    weak var owner: ScreenInk?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    private var closeRect: NSRect { NSRect(x: bounds.maxX - 44, y: 12, width: 28, height: 28) }
    override func mouseDown(with event: NSEvent) {
        window?.orderFrontRegardless()
        window?.makeKey(); window?.makeFirstResponder(self)
        if closeRect.insetBy(dx: -6, dy: -6).contains(convert(event.locationInWindow, from: nil)) { owner?.clear(); return }
        window?.performDrag(with: event)
    }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { owner?.clear() } else { super.keyDown(with: event) } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand); addCursorRect(closeRect, cursor: .pointingHand) }
    override func draw(_ dirtyRect: NSRect) {}
    override func didAddSubview(_ subview: NSView) { super.didAddSubview(subview); needsDisplay = true }
}

/// The × drawn above the ink (a sibling view on top of it).
private final class BoardClose: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let circle = bounds.insetBy(dx: 2, dy: 2)
        NSColor.black.withAlphaComponent(0.08).setFill(); NSBezierPath(ovalIn: circle).fill()
        NSColor.black.withAlphaComponent(0.45).setStroke()
        let x = NSBezierPath(); x.lineWidth = 1.8; x.lineCapStyle = .round
        let c = circle.insetBy(dx: 8, dy: 8)
        x.move(to: c.origin); x.line(to: CGPoint(x: c.maxX, y: c.maxY)); x.move(to: CGPoint(x: c.minX, y: c.maxY)); x.line(to: CGPoint(x: c.maxX, y: c.minY)); x.stroke()
    }
}
