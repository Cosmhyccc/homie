import AppKit

/// Pixie's own little cursor. It rides beside the user's pointer, shows a voice
/// bubble while talking, flies off to draw or click, then comes back home.
final class PixieCursor {
    static let shared = PixieCursor()
    private static let key = "pixie.cursor"
    private static let colorKey = "pixie.cursor.color"

    enum Color: String, CaseIterable {
        case match, black, pink, purple, blue, green, white
        var title: String { ["match": "Match the look", "black": "Black", "pink": "Pink", "purple": "Purple", "blue": "Blue", "green": "Green", "white": "White"][rawValue]! }
        /// The concrete color to paint; `match` follows the current skin.
        var resolved: Color { self == .match ? .pink : self }  // homie's cursor is pink by default, like the site
        var fill: NSColor {
            switch resolved {
            case .pink: return NSColor(red: 0.878, green: 0.384, blue: 0.541, alpha: 1)  // site #e0628a
            case .purple: return NSColor(red: 0.62, green: 0.32, blue: 1.0, alpha: 1)
            case .blue: return NSColor(red: 0.2, green: 0.52, blue: 1.0, alpha: 1)
            case .green: return NSColor(red: 0.16, green: 0.78, blue: 0.45, alpha: 1)
            case .white: return .white
            default: return .black
            }
        }
        var outline: NSColor { resolved == .white ? .black : .white }
        var eyes: NSColor { resolved == .white ? .black : .white }
        /// Bubble background and lit bars, chosen for strong contrast on any wallpaper.
        var bubble: NSColor {
            switch resolved {
            case .pink: return NSColor(red: 0.42, green: 0.06, blue: 0.25, alpha: 0.96)
            case .purple: return NSColor(red: 0.2, green: 0.06, blue: 0.4, alpha: 0.96)
            case .blue: return NSColor(red: 0.05, green: 0.14, blue: 0.38, alpha: 0.96)
            case .green: return NSColor(red: 0.03, green: 0.26, blue: 0.15, alpha: 0.96)
            case .white: return NSColor(white: 0.98, alpha: 0.97)
            default: return NSColor(white: 0.06, alpha: 0.92)
            }
        }
        var bubbleEdge: NSColor { [.pink, .purple, .blue, .green].contains(resolved) ? fill : resolved == .white ? NSColor(white: 0, alpha: 0.25) : NSColor(white: 1, alpha: 0.25) }
        var listeningBar: NSColor {
            switch resolved {
            case .pink: return NSColor(red: 1.0, green: 0.55, blue: 0.75, alpha: 1)
            case .purple: return NSColor(red: 0.8, green: 0.64, blue: 1.0, alpha: 1)
            case .blue: return NSColor(red: 0.5, green: 0.78, blue: 1.0, alpha: 1)
            case .green: return NSColor(red: 0.45, green: 0.95, blue: 0.65, alpha: 1)
            case .white: return NSColor(red: 0.1, green: 0.62, blue: 0.5, alpha: 1)
            default: return .systemMint
            }
        }
        var speakingBar: NSColor { resolved == .white ? .black : .white }
        var idleBar: NSColor { resolved == .white ? NSColor(white: 0, alpha: 0.18) : NSColor(white: 1, alpha: 0.22) }
    }

    static var color: Color {
        get { Color(rawValue: UserDefaults.standard.string(forKey: colorKey) ?? "") ?? .match }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: colorKey); shared.view.needsDisplay = true }
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            shared.refreshVisibility()
        }
    }

    enum Voice { case off, listening, speaking }
    var voice: Voice = .off { didSet { view.needsDisplay = true } }
    var level: Float = 0 { didSet { if voice != .off { view.needsDisplay = true } } }

    private struct Trip { var path: [CGPoint]; var start: Date; var duration: TimeInterval; var click = false }
    private var trips: [Trip] = []
    private var tripEnded = Date.distantPast
    private let panel: NSPanel
    private let view = CursorView()
    private var timer: Timer?
    /// Tip position in global Cocoa coordinates (origin bottom-left of primary screen).
    private var tip = NSEvent.mouseLocation
    private static let homeOffset = CGPoint(x: 16, y: -18)
    static let flight: TimeInterval = 0.28
    private static let tipInset = CGPoint(x: 10, y: 118)
    private static let size = CGSize(width: 220, height: 130)

    private init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = view
        view.owner = self
        NotificationCenter.default.addObserver(forName: PixieSkin.changed, object: nil, queue: .main) { [weak self] _ in self?.view.needsDisplay = true }
    }

    func start() { refreshVisibility() }

    private func refreshVisibility() {
        if Self.enabled {
            tip = home
            place()
            panel.orderFrontRegardless()
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common); timer = t
        } else {
            timer?.invalidate(); timer = nil
            trips = []
            panel.orderOut(nil)
        }
    }

    private var home: CGPoint {
        let mouse = NSEvent.mouseLocation
        var point = CGPoint(x: mouse.x + Self.homeOffset.x, y: mouse.y + Self.homeOffset.y)
        // Keep her (and her bubble) on screen near the right and bottom edges.
        if let frame = NSScreen.screens.first(where: { $0.frame.contains(mouse) })?.frame {
            if point.x + 130 > frame.maxX { point.x = mouse.x - 70 }
            if point.y - 80 < frame.minY { point.y = mouse.y + 70 }
        }
        return point
    }

    var busy: Bool { !trips.isEmpty }

    /// Queue a trace of `path` (global Cocoa coordinates) starting at `start`; she flies there first.
    func trace(_ path: [CGPoint], start: Date, duration: TimeInterval) {
        guard Self.enabled, !path.isEmpty else { return }
        trips.append(Trip(path: path, start: start, duration: duration))
    }

    func cancelTrips() { trips.removeAll { !$0.click } }

    /// Fly to a point and show a click ripple there. Returns when the cursor arrives.
    func click(at point: CGPoint) -> TimeInterval {
        guard Self.enabled else { return 0 }
        trips = [Trip(path: [point], start: Date().addingTimeInterval(Self.flight), duration: 0.45, click: true)]
        return Self.flight + 0.05
    }

    private func tick() {
        let now = Date()
        var target = home
        var follow = 0.32
        view.ripple = nil
        if let trip = trips.first {
            if now < trip.start {
                target = trip.path[0]; follow = 0.22
            } else {
                let progress = min(1, now.timeIntervalSince(trip.start) / trip.duration)
                let index = min(trip.path.count - 1, Int(Double(trip.path.count - 1) * progress))
                target = trip.path[index]; follow = 1
                if trip.click { view.ripple = progress }
                if progress >= 1 { trips.removeFirst(); if trips.isEmpty { tripEnded = now } }
            }
        } else if now.timeIntervalSince(tripEnded) < 0.35 {
            // Linger at the finish so the stroke reads as hers, then glide home.
            return
        }
        let next = CGPoint(x: tip.x + (target.x - tip.x) * follow, y: tip.y + (target.y - tip.y) * follow)
        if voice != .off { view.needsDisplay = true }
        if hypot(next.x - tip.x, next.y - tip.y) < 0.2 && view.ripple == nil { return }
        tip = next
        place()
        if view.ripple != nil { view.needsDisplay = true }
    }

    private func place() {
        panel.setFrameOrigin(NSPoint(x: round(tip.x - Self.tipInset.x), y: round(tip.y - Self.tipInset.y)))
    }

    fileprivate final class CursorView: NSView {
        weak var owner: PixieCursor?
        var ripple: Double?
        override func draw(_ dirtyRect: NSRect) {
            guard let owner else { return }
            PixieCursor.paint(tip: PixieCursor.tipInset, color: PixieCursor.color.resolved, voice: owner.voice, level: owner.level, ripple: ripple)
        }
    }

    /// Size of the arrow box in points (the website's cursor is 92; this rides next to your pointer).
    static let arrowSize: CGFloat = 56
    private static let ink = NSColor(red: 0.122, green: 0.114, blue: 0.102, alpha: 1)
    private static let cream = NSColor(red: 1, green: 0.973, blue: 0.906, alpha: 1)

    /// Draws the website's homie cursor (pink triangle, thick ink edge, hard drop shadow)
    /// with its tip at `tip`, plus the voice bubble. Shared by the live panel and Customize previews.
    static func paint(tip: CGPoint, color: Color, voice: Voice, level: Float, ripple: Double? = nil, time: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        let unit = arrowSize / 40   // the site's SVG is drawn in a 40x40 box
        // SVG point (y down) -> view point (y up), with the SVG tip (5,3) on `tip`.
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: tip.x + (x - 5) * unit, y: tip.y - (y - 3) * unit) }
        if let ripple {
            let radius = 8 + 22 * ripple
            color.fill.withAlphaComponent(0.6 * (1 - ripple)).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: tip.x - radius, y: tip.y - radius, width: radius * 2, height: radius * 2))
            ring.lineWidth = 3.5; ring.stroke()
        }
        let arrow = NSBezierPath()
        arrow.move(to: pt(5, 3)); arrow.line(to: pt(34, 17)); arrow.line(to: pt(22, 20.6)); arrow.line(to: pt(16.4, 34)); arrow.close()
        arrow.lineJoinStyle = .round
        // Hard offset shadow, like a sticker on paper.
        let shadow = arrow.copy() as! NSBezierPath
        shadow.transform(using: AffineTransform(translationByX: 4 * unit * 0.8, byY: -7 * unit * 0.8))
        ink.withAlphaComponent(0.28).setFill(); shadow.fill()
        color.fill.setFill(); arrow.fill()
        let edge = color.resolved == .black ? cream : ink
        edge.setStroke(); arrow.lineWidth = 3.4 * unit; arrow.stroke()
        guard voice != .off else { return }
        // Voice bubble: cream with an ink line, like the site's speech bubbles, with live level bars.
        let bubble = NSRect(x: pt(34, 0).x + 7, y: tip.y - 32, width: 54, height: 26)
        let bubblePath = NSBezierPath(roundedRect: bubble, xRadius: 13, yRadius: 13)
        let lift = bubblePath.copy() as! NSBezierPath
        lift.transform(using: AffineTransform(translationByX: 2.5, byY: -3)); ink.withAlphaComponent(0.25).setFill(); lift.fill()
        cream.setFill(); bubblePath.fill()
        ink.setStroke(); bubblePath.lineWidth = 2; bubblePath.stroke()
        let lit = voice == .speaking ? ink : color.fill
        for index in 0..<5 {
            let shape = CGFloat(2 - abs(index - 2))
            var height = 5 + shape * 3
            let on = level > Float(index) * 0.012 + 0.002
            if !on {
                // Breathe gently while quiet, so the bubble always reads as alive.
                let wave = (sin(time * 4 + Double(index) * 0.9) + 1) / 2
                height = 4 + CGFloat(wave) * 3
            }
            (on ? lit : lit.withAlphaComponent(0.4)).setFill()
            NSBezierPath(roundedRect: NSRect(x: bubble.minX + 12 + CGFloat(index) * 6.4, y: bubble.midY - height / 2, width: 3.5, height: height), xRadius: 1.75, yRadius: 1.75).fill()
        }
    }

    /// A still image of the cursor for the Customize page.
    static func preview(_ color: Color, voice: Voice) -> NSImage {
        NSImage(size: NSSize(width: 150, height: 84), flipped: false) { _ in
            paint(tip: CGPoint(x: 14, y: 76), color: color, voice: voice, level: voice == .speaking ? 0.03 : 0.0, time: 0.6)
            return true
        }
    }
}
