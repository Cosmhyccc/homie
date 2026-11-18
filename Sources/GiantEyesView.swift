import AppKit

/// The original 5 × 6 pixel eyes, enlarged with square pupils and shared blinking.
final class GiantEyesView: NSView {
    private var timer: Timer?
    private var blinkStart = Date.distantPast
    private var nextBlink = Date().addingTimeInterval(2)
    private var gaze = CGPoint.zero
    /// Render a specific look instead of the user's current one (Customize previews).
    var skinOverride: PixieSkin?
    private var skin: PixieSkin { skinOverride ?? .current }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    deinit { timer?.invalidate() }
    private func tick() {
        guard !isHidden, let window else { return }
        let now = Date()
        if now >= nextBlink { blinkStart = now; nextBlink = now.addingTimeInterval(Double.random(in: 3...6)) }
        let cursor = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let dx = cursor.x - bounds.midX, dy = cursor.y - bounds.midY
        let distance = max(180, hypot(dx, dy))
        let target = CGPoint(x: dx / distance, y: dy / distance)
        gaze.x += (target.x - gaze.x) * 0.2
        gaze.y += (target.y - gaze.y) * 0.2
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = false
        let pink = skin.isPink
        // Pink Pixie shrinks her eyes a little to fit the bow centered above them.
        let pixel = floor(min(bounds.height * (pink ? 0.56 : 0.72) / 6, bounds.width * 0.27 / 5))
        guard pixel >= 1 else { return }
        let bowPixel = max(2, floor(pixel * 0.6))
        let bowHeight = pink ? CGFloat(PixieSkin.bowSize.rows) * bowPixel + round(pixel * 0.5) : 0
        let midY = round(bounds.midY - bowHeight / 2)
        let elapsed = Date().timeIntervalSince(blinkStart)
        let blinkFrames = [3, 1, 1, 3, 6]
        let rows = elapsed >= 0 && elapsed < 0.225
            ? blinkFrames[min(4, Int(elapsed / 0.045))] : 6
        let silhouette = rows == 6
            ? ["01110", "11111", "11111", "11111", "11111", "01110"]
            : Array(repeating: "11111", count: rows)
        let pupilHeight = rows == 6 ? 2 * pixel : pixel
        // Match little Pixie's half-cell gaze steps and retain a white border.
        let gazeStep = max(1, floor(pixel / 2))
        let offsetX = (gaze.x * 2).rounded() * gazeStep
        let offsetY = rows == 6 ? (gaze.y * 2).rounded() * gazeStep : 0
        for center in [bounds.width * 0.29, bounds.width * 0.71] {
            let left = round(center - 2.5 * pixel)
            let bottom = round(midY - CGFloat(rows) * pixel / 2)
            NSColor.white.setFill()
            for (row, cells) in silhouette.enumerated() {
                for (column, cell) in cells.enumerated() where cell == "1" {
                    NSRect(x: left + CGFloat(column) * pixel,
                           y: bottom + CGFloat(row) * pixel,
                           width: pixel, height: pixel).fill()
                }
            }
            if rows > 1 {
                skin.pupil.setFill()
                NSRect(x: round(center - pixel) + offsetX,
                       y: round(midY - pupilHeight / 2) + offsetY,
                       width: 2 * pixel, height: pupilHeight).fill()
            }
        }
        if pink {
            let size = PixieSkin.bowSize
            let top = midY + 3 * pixel + bowHeight
            PixieSkin.drawBow(at: NSPoint(x: round(bounds.midX - CGFloat(size.columns) * bowPixel / 2), y: round(top)), pixel: bowPixel)
        }
    }
}
