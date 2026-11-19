import AppKit
import SwiftUI

/// Pixie's look. Classic is the original black tab; the pink skins add a bow.
enum PixieSkin: String, CaseIterable {
    case classic, pink, pinkRainbow
    /// Pink and rainbow are retired (Nov 18: eye colors replaced them); every saved choice shows as classic.
    static var allCases: [PixieSkin] { [.classic] }

    static let changed = Notification.Name("PixieSkinChanged")
    private static let key = "pixie.skin"

    static var current: PixieSkin {
        get { .classic }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .pink: "Pink"
        case .pinkRainbow: "Pink"
        }
    }

    var isPink: Bool { self != .classic }

    /// Extra width on each side of the compact tab so the bow has room beside the right eye.
    var compactPadding: CGFloat { isPink ? 14 : 0 }

    /// Text and icon color for content drawn on the tab.
    var ink: Color { isPink ? Color(red: 0.45, green: 0.07, blue: 0.27) : .white }
    var pupil: NSColor { isPink ? NSColor(red: 0.38, green: 0.05, blue: 0.22, alpha: 1) : .black }

    static let blush = NSColor(red: 1.0, green: 0.80, blue: 0.87, alpha: 0.86)
    static let rose = NSColor(red: 0.93, green: 0.27, blue: 0.54, alpha: 1)

    /// The tab outline: square top corners flush with the screen edge, rounded bottom,
    /// and concave shoulders once the tab is taller than the menu bar.
    static func tabPath(width w: CGFloat, height h: CGFloat, closed: Bool) -> CGMutablePath {
        let r: CGFloat = min(26, h / 2)
        let shoulder: CGFloat = h > 40 ? 15 : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: h))
        path.addCurve(to: CGPoint(x: shoulder, y: h - shoulder), control1: CGPoint(x: shoulder, y: h), control2: CGPoint(x: shoulder, y: h))
        path.addLine(to: CGPoint(x: shoulder, y: r))
        path.addCurve(to: CGPoint(x: shoulder + r, y: 0), control1: CGPoint(x: shoulder, y: 0), control2: CGPoint(x: shoulder, y: 0))
        path.addLine(to: CGPoint(x: w - shoulder - r, y: 0))
        path.addCurve(to: CGPoint(x: w - shoulder, y: r), control1: CGPoint(x: w - shoulder, y: 0), control2: CGPoint(x: w - shoulder, y: 0))
        path.addLine(to: CGPoint(x: w - shoulder, y: h - shoulder))
        path.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: w - shoulder, y: h), control2: CGPoint(x: w - shoulder, y: h))
        if closed { path.closeSubpath() }
        return path
    }

    func drawTab(in bounds: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let w = bounds.width, h = bounds.height
        guard isPink else {
            context.addPath(Self.tabPath(width: w, height: h, closed: true))
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return
        }
        let line: CGFloat = 2.5
        // Inset so the stroke stays inside the panel; the top edge is left open.
        var transform = CGAffineTransform(translationX: line / 2, y: line / 2)
            .scaledBy(x: (w - line) / w, y: (h - line / 2) / h)
        let fill = Self.tabPath(width: w, height: h, closed: true).copy(using: &transform)!
        context.addPath(fill)
        context.setFillColor(Self.blush.cgColor)
        context.fillPath()
        let outline = Self.tabPath(width: w, height: h, closed: false).copy(using: &transform)!
        context.saveGState()
        context.addPath(outline)
        context.setLineWidth(line)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if self == .pinkRainbow {
            context.replacePathWithStrokedPath()
            context.clip()
            // Sweep the hue around the U from the top-center so every side shows the rainbow.
            let center = CGPoint(x: w / 2, y: h), radius = hypot(w, h), slices = 120
            for index in 0..<slices {
                let start = CGFloat.pi + CGFloat.pi * CGFloat(index) / CGFloat(slices)
                let end = CGFloat.pi + CGFloat.pi * CGFloat(index + 1) / CGFloat(slices) + 0.01
                context.move(to: center)
                context.addLine(to: CGPoint(x: center.x + cos(start) * radius, y: center.y + sin(start) * radius))
                context.addLine(to: CGPoint(x: center.x + cos(end) * radius, y: center.y + sin(end) * radius))
                context.closePath()
                context.setFillColor(NSColor(hue: 0.85 * CGFloat(index) / CGFloat(slices), saturation: 0.75, brightness: 1, alpha: 1).cgColor)
                context.fillPath()
            }
        } else {
            context.setStrokeColor(Self.rose.cgColor)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// A still picture of big Pixie wearing this look, for the Customize page.
    func preview(size: NSSize = NSSize(width: 300, height: 170)) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.drawTab(in: rect)
            let eyes = GiantEyesView(frame: NSRect(x: 0, y: 0, width: rect.width - 48, height: rect.height - 46))
            eyes.skinOverride = self
            NSGraphicsContext.saveGraphicsState()
            let shift = NSAffineTransform(); shift.translateX(by: 24, yBy: 18); shift.concat()
            eyes.draw(eyes.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    /// Pixel-art bow with white polka dots. O outline, P pink, K knot, W polka dot.
    private static let bow = [
        "OO.......OO",
        "OPOO...OOPO",
        "OWPPOKOPPWO",
        "OPPWKKKWPPO",
        "OPPPOKOPPPO",
        "OPOO...OOPO",
        "OO.......OO",
    ]
    static let bowSize = (columns: 11, rows: 7)

    /// Draws the bow with its top-left corner at `origin` (AppKit coordinates, y up).
    static func drawBow(at origin: NSPoint, pixel: CGFloat) {
        let palette: [Character: NSColor] = [
            "O": NSColor(red: 0.52, green: 0.07, blue: 0.29, alpha: 1),
            "P": NSColor(red: 1.0, green: 0.42, blue: 0.64, alpha: 1),
            "K": rose,
            "W": .white,
        ]
        for (row, cells) in bow.enumerated() {
            for (column, cell) in cells.enumerated() {
                guard let color = palette[cell] else { continue }
                color.setFill()
                NSRect(x: origin.x + CGFloat(column) * pixel, y: origin.y - CGFloat(row + 1) * pixel,
                       width: pixel, height: pixel).fill()
            }
        }
    }
}
