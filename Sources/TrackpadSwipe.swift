import SwiftUI
import AppKit

/// Two-finger horizontal trackpad swipes for a pager, like iOS paging.
/// Watches scroll-wheel events in its own window, locks to an axis after a few points, and only takes
/// horizontal gestures: vertical scrolling, mouse wheels and horizontal scroll views pass through untouched.
/// `moved` gets the total finger travel in points (positive = fingers moved right); `ended` adds velocity (pt/s).
struct TrackpadSwipe: NSViewRepresentable {
    var enabled: () -> Bool
    var moved: (CGFloat) -> Void
    var ended: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView { let v = Probe(); v.coordinator = context.coordinator; return v }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.parent = self }
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    /// Invisible; only here to know which window to listen to.
    final class Probe: NSView {
        weak var coordinator: Coordinator?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); coordinator?.attach(to: window) }
    }

    final class Coordinator {
        var parent: TrackpadSwipe
        private weak var window: NSWindow?
        private var monitor: Any?
        private enum Axis { case undecided, horizontal, vertical, ignored }
        private var axis = Axis.ignored
        private var start = CGSize.zero          // travel before the axis locks
        private var total: CGFloat = 0
        private var velocity: CGFloat = 0
        private var lastTime: TimeInterval = 0
        private var eatMomentum = false

        init(parent: TrackpadSwipe) { self.parent = parent }
        deinit { stop() }

        func attach(to window: NSWindow?) {
            stop()
            guard let window else { return }
            self.window = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event) ?? event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }

        func handle(_ e: NSEvent) -> NSEvent? {
            guard e.window === window, e.hasPreciseScrollingDeltas else { return e }
            // The flick's momentum belongs to the swipe that just ended; don't let it scroll the page underneath.
            if e.momentumPhase != [] {
                if e.momentumPhase.contains(.ended) || e.momentumPhase.contains(.cancelled) { let eat = eatMomentum; eatMomentum = false; return eat ? nil : e }
                return eatMomentum ? nil : e
            }
            // Content follows the fingers whatever the user's scroll-direction setting is.
            let dx = e.isDirectionInvertedFromDevice ? e.scrollingDeltaX : -e.scrollingDeltaX
            let dy = e.scrollingDeltaY
            if e.phase.contains(.began) {
                eatMomentum = false
                axis = parent.enabled() && !editingText && !overHorizontalScroller(e) ? .undecided : .ignored
                start = .zero; total = 0; velocity = 0; lastTime = e.timestamp
            }
            switch axis {
            case .ignored, .vertical:
                return e
            case .undecided:
                guard e.phase.contains(.changed) else { return e }
                start.width += dx; start.height += dy
                guard hypot(start.width, start.height) > 6 else { return e }
                if abs(start.width) > abs(start.height) * 1.3 {
                    axis = .horizontal; total = start.width; parent.moved(total); return nil
                }
                axis = .vertical; return e
            case .horizontal:
                if e.phase.contains(.changed) {
                    total += dx
                    let dt = max(e.timestamp - lastTime, 1.0/240)
                    velocity = velocity * 0.6 + dx / CGFloat(dt) * 0.4   // smoothed pt/s
                    lastTime = e.timestamp
                    parent.moved(total)
                } else if e.phase.contains(.ended) || e.phase.contains(.cancelled) {
                    // A pause before lifting means no flick.
                    if e.timestamp - lastTime > 0.08 { velocity = 0 }
                    parent.ended(total, velocity)
                    axis = .ignored; eatMomentum = true
                }
                return nil
            }
        }

        /// Typing in the chat field (or any text) wins over paging.
        private var editingText: Bool {
            guard let text = window?.firstResponder as? NSTextView else { return false }
            return !text.string.isEmpty
        }

        /// Attachment chips and other sideways scroll views keep their own swipes.
        private func overHorizontalScroller(_ e: NSEvent) -> Bool {
            guard let content = window?.contentView else { return false }
            var view = content.hitTest(content.convert(e.locationInWindow, from: nil))
            while let v = view {
                if let scroll = v as? NSScrollView, let doc = scroll.documentView,
                   doc.frame.width > scroll.contentView.bounds.width + 1 { return true }
                view = v.superview
            }
            return false
        }
    }
}
