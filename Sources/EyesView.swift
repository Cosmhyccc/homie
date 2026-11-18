import AppKit

final class EyesView: NSView {
    var eyeCenters: [CGFloat] = []
    private var visibleRows = 6
    private var blinkTimer: Timer?
    private var gazeTimer: Timer?
    private var pupilOffsets: [NSPoint] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        blinkTimer?.invalidate()
        gazeTimer?.invalidate()
        visibleRows = 6
        if window != nil {
            scheduleBlink(after: 2)
            updateGaze()
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.updateGaze()
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            gazeTimer = timer
        }
    }

    deinit {
        blinkTimer?.invalidate()
        gazeTimer?.invalidate()
    }

    private func updateGaze() {
        guard let window else { return }
        let cursor = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let offsets = eyeCenters.map { center -> NSPoint in
            let dx = cursor.x - center
            let dy = cursor.y - bounds.midY
            // Keep a white border around each pupil, even when looking diagonally.
            let distance = max(100, hypot(dx, dy))
            return NSPoint(x: (3 * dx / distance).rounded(), y: (3 * dy / distance).rounded())
        }
        if offsets != pupilOffsets {
            pupilOffsets = offsets
            needsDisplay = true
        }
    }

    private func scheduleBlink(after delay: TimeInterval) {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.animateBlink(step: 0)
        }
    }

    private func animateBlink(step: Int) {
        let frames = [3, 1, 1, 3, 6]
        visibleRows = frames[step]
        needsDisplay = true
        if step == frames.count - 1 {
            scheduleBlink(after: Double.random(in: 2.8...5.5))
        } else {
            blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: false) { [weak self] _ in
                self?.animateBlink(step: step + 1)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let skin = PixieSkin.current
        if !skin.isPink {
            NSColor.black.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
            // Square top corners merge the panel into the screen edge.
            NSRect(x: 0, y: bounds.height - 12, width: bounds.width, height: 12).fill()
        }
        NSGraphicsContext.current?.shouldAntialias = false
        NSColor.white.setFill()
        let pixels = visibleRows == 6
            ? ["01110", "11111", "11111", "11111", "11111", "01110"]
            : Array(repeating: "11111", count: visibleRows)
        let pixel: CGFloat = 3
        for center in eyeCenters {
            for (row, cells) in pixels.enumerated() {
                for (column, cell) in cells.enumerated() where cell == "1" {
                    NSRect(x: round(center - 7.5) + CGFloat(column) * pixel,
                           y: round((bounds.height - CGFloat(visibleRows) * pixel) / 2) + CGFloat(row) * pixel,
                           width: pixel, height: pixel).fill()
                }
            }
        }
        if visibleRows > 1 {
            skin.pupil.setFill()
            let pupilHeight: CGFloat = visibleRows == 6 ? 6 : 3
            for (index, center) in eyeCenters.enumerated() {
                let offset = index < pupilOffsets.count ? pupilOffsets[index] : .zero
                NSRect(x: round(center - 3) + offset.x,
                       y: round((bounds.height - pupilHeight) / 2) + (visibleRows == 6 ? offset.y : 0),
                       width: 6, height: pupilHeight).fill()
            }
        }
        if skin.isPink, let right = eyeCenters.last {
            // A little hair bow perched on the outer top corner of the right eye.
            let pixel: CGFloat = 2
            PixieSkin.drawBow(at: NSPoint(x: round(right + 4), y: bounds.height), pixel: pixel)
        }
    }
}

final class EyesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

