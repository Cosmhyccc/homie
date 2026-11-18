import AppKit
import SwiftUI

final class NotchModel: ObservableObject {
    @Published var invitation = false
    @Published var giantEyes = false
    var shrink: (() -> Void)?
    @Published var status = ""
    @Published var visionStatus: String?
    @Published var caption = ""
    @Published var musicStatus = ""
    @Published var musicError = false
    @Published var inputLevel: Float = 0
    @Published var voiceActive = false
    @Published var voiceError = false
    @Published var musicVisible = false
    @Published var track: MusicTrack?
    @Published var artwork: NSImage?
    @Published var skin = PixieSkin.current
    var control: ((String) -> Void)?
    var collapse: (() -> Void)?
    var endVoice: (() -> Void)?
    var permissions: (() -> Void)?
}

private struct NotchContent: View {
    @ObservedObject var model: NotchModel
    private let pink = Color(red: 1, green: 0.27, blue: 0.42)
    private var ink: Color { model.skin.ink }
    /// Live/active highlight: mint on black, hot pink on the light pink tab.
    private var accent: Color { model.skin.isPink ? Color(red: 0.86, green: 0.12, blue: 0.45) : .mint }

    var body: some View {
        VStack(spacing: 0) {
            if model.invitation && !model.voiceActive {
                Text("Press Fn to make your first wish.").font(.system(size:14,weight:.medium)).foregroundStyle(ink.opacity(0.85)).frame(maxWidth:.infinity)
            }
            if model.voiceActive || model.voiceError {
                HStack(spacing: 8) {
                    Circle().fill(model.voiceError ? Color.orange : accent).frame(width: 6, height: 6)
                    Text(model.visionStatus ?? model.status).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 4)
                    if model.voiceActive {
                        HStack(alignment: .center, spacing: 2) {
                            ForEach(0..<5) { index in
                                Capsule().fill(model.inputLevel > Float(index) * 0.012 + 0.002 ? accent : ink.opacity(0.22))
                                    .frame(width: 3, height: CGFloat(5 + (2 - abs(index - 2)) * 3))
                            }
                        }.accessibilityLabel("Microphone input level")
                    }
                    if model.voiceActive {
                        Button { model.endVoice?() } label: { Image(systemName: "stop.circle").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(ink.opacity(0.6)).help("End voice conversation")
                    } else if model.voiceError {
                        Button { model.endVoice?() } label: { Image(systemName: "xmark.circle").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(ink.opacity(0.6))
                            .help("Dismiss error").accessibilityLabel("Dismiss error")
                    }
                }
                .padding(.bottom, 7)
                if !model.musicVisible || model.giantEyes {
                    ScrollViewReader { scroll in
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(model.caption).font(.system(size: 13)).foregroundStyle(ink.opacity(0.75))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("caption-end")
                            }
                        }
                        .frame(height: 52)
                        .onChange(of: model.caption) { _, _ in scroll.scrollTo("caption-end", anchor: .bottom) }
                        .onAppear { scroll.scrollTo("caption-end", anchor: .bottom) }
                    }
                }
            }

            if model.musicVisible && !model.giantEyes {
                HStack(spacing: 7) {
                    Image(systemName: "music.note").foregroundStyle(pink).font(.system(size: 14, weight: .bold))
                    Text("Apple Music").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if let track = model.track {
                        Text(track.playing ? "PLAYING" : "PAUSED")
                            .font(.system(size: 8, weight: .bold, design: .rounded)).tracking(1.2)
                            .foregroundStyle(track.playing ? accent : ink.opacity(0.45))
                    }
                    Button { model.collapse?() } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(ink.opacity(0.45)).padding(.leading, 9).help("Collapse player; music keeps playing")
                }.padding(.top, model.voiceActive ? 8 : 0)

                if let track = model.track {
                    ZStack {
                        RoundedRectangle(cornerRadius: 13).fill(ink.opacity(0.07))
                        if let image = model.artwork {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note").font(.system(size: 54, weight: .light)).foregroundStyle(ink.opacity(0.28))
                        }
                    }
                    .frame(width: 190, height: 190).clipShape(RoundedRectangle(cornerRadius: 13))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .padding(.top, 17).padding(.bottom, 16)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                        Text(track.artist).font(.system(size: 12)).foregroundStyle(ink.opacity(0.5)).lineLimit(1)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(ink.opacity(0.14))
                                Capsule().fill(ink.opacity(0.75)).frame(width: geometry.size.width * min(1, max(0, track.position / max(1, track.duration))))
                            }
                        }.frame(height: 3).padding(.top, 12)
                        HStack {
                            Text(time(track.position))
                            Spacer()
                            Text("−" + time(max(0, track.duration - track.position)))
                        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(ink.opacity(0.35)).padding(.top, 3)
                    }
                    HStack(spacing: 35) {
                        Button { model.control?("previous") } label: { Image(systemName: "backward.end.fill").font(.system(size: 19)) }
                        Button { model.control?(track.playing ? "pause" : "resume") } label: {
                            Image(systemName: track.playing ? "pause.fill" : "play.fill").font(.system(size: 22)).frame(width: 44, height: 40)
                        }
                        Button { model.control?("next") } label: { Image(systemName: "forward.end.fill").font(.system(size: 19)) }
                    }.buttonStyle(.plain).padding(.top, 10)
                    if model.musicError {
                        Text(model.musicStatus).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3).padding(.top, 8)
                    }
                } else {
                    VStack(spacing: 15) {
                        Image(systemName: model.musicError ? "music.note" : "waveform").font(.system(size: 35, weight: .light)).foregroundStyle(pink)
                        Text(model.musicStatus).font(.system(size: 13)).foregroundStyle(model.musicError ? .orange : ink.opacity(0.75)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        if model.musicError && model.musicStatus.contains("Accessibility") {
                            Button("Enable Music Controls") { model.permissions?() }.buttonStyle(.bordered)
                        }
                    }.frame(maxWidth: .infinity).padding(.vertical, 28)
                }
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(model.skin.isPink ? .light : .dark)
    }

    private func time(_ value: Double) -> String {
        let seconds = max(0, Int(value.isFinite ? value : 0))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class NotchSurface: NSView {
    var onResize: (() -> Void)?
    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        onResize?()
    }
    override func draw(_ dirtyRect: NSRect) {
        PixieSkin.current.drawTab(in: bounds)
    }
}

/// Captures only the face/header, leaving all conversation and player buttons alone.
private final class FaceGestureView: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((CGFloat, Bool) -> Void)?
    private var start: NSPoint?
    private var dragging = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let delta = start.y - NSEvent.mouseLocation.y
        if !dragging && abs(delta) < 5 { return }
        dragging = true
        onDrag?(delta, false)
    }
    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        self.start = nil
        if dragging { onDrag?(start.y - NSEvent.mouseLocation.y, true) }
        else { onClick?() }
        dragging = false
    }
}

final class NotchController {
    let model = NotchModel()
    private let panel: NotchPanel
    private let surface = NotchSurface()
    private let eyes = EyesView()
    private let giantEyes = GiantEyesView()
    private let faceGesture = FaceGestureView()
    private var dragProgress: CGFloat?
    private var dragStartedGiant = false
    private let content: NSHostingView<NotchContent>
    private var screen: NSScreen?
    private var eyeWidth: CGFloat = 86
    private var topHeight: CGFloat = 32
    private var center: CGFloat = 0
    private var expanded = false
    private var outsideClickMonitor: Any?
    private var localClickMonitor: Any?
    private var skinObserver: NSObjectProtocol?
    private var targetFrame = NSRect.zero

    init() {
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        content = NSHostingView(rootView: NotchContent(model: model))
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = surface
        surface.addSubview(eyes)
        surface.addSubview(giantEyes)
        giantEyes.isHidden = true
        surface.onResize = { [weak self] in self?.layoutChildren() }
        surface.addSubview(content)
        content.isHidden = true
        content.sizingOptions = []
        surface.addSubview(faceGesture)
        faceGesture.onClick = { [weak self] in
            guard let self else { return }
            self.onInteraction?("notch_click")
            // A canvas hidden behind other windows comes back first.
            if ScreenInk.shared.raiseBoard() { return }
            if self.model.giantEyes || self.model.musicVisible {
                self.setGiant(false)
            } else if self.model.track != nil {
                self.model.musicVisible = true
                self.resize()
            } else {
                self.setGiant(true)
            }
        }
        faceGesture.onDrag = { [weak self] delta, finished in self?.dragFace(delta: delta, finished: finished) }
        faceGesture.toolTip = "Click to reopen music or grow; click again to tuck away. Pull down for big eyes."
        faceGesture.setAccessibilityElement(true)
        faceGesture.setAccessibilityLabel("homie's face: click or drag to resize")
        faceGesture.setAccessibilityRole(.button)
        model.collapse = { [weak self] in
            self?.setGiant(false)
        }
        model.shrink = { [weak self] in self?.setGiant(false) }
        skinObserver = NotificationCenter.default.addObserver(forName: PixieSkin.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.model.skin = PixieSkin.current
            self.position()
            [self.surface, self.eyes, self.giantEyes].forEach { $0.needsDisplay = true }
        }
        position()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.tuckAway()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.panel { self.tuckAway() }
            return event
        }
    }

    deinit {
        panel.orderOut(nil)
        panel.close()
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let skinObserver { NotificationCenter.default.removeObserver(skinObserver) }
    }

    var onInteraction: ((String) -> Void)?

    private func tuckAway() {
        guard !model.invitation, expanded || dragProgress != nil else { return }
        model.musicVisible = false
        setGiant(false)
    }

    func setGiant(_ enabled: Bool) {
        if !enabled { model.invitation = false }
        if model.giantEyes != enabled { onInteraction?(enabled ? "notch_expand" : "notch_shrink") }
        dragProgress = nil
        model.giantEyes = enabled
        // Face sizing and player visibility are mutually exclusive. Shrink always
        // dismisses the player while preserving playback and the compact voice UI.
        model.musicVisible = false
        eyes.alphaValue = 1
        giantEyes.alphaValue = 1
        content.alphaValue = 1
        eyes.isHidden = enabled
        giantEyes.isHidden = !enabled
        resize()
        layoutChildren()
    }

    private func layoutChildren() {
        let size = surface.bounds.size
        eyes.frame = NSRect(x: (size.width - eyeWidth) / 2, y: size.height - topHeight, width: eyeWidth, height: topHeight)
        if let progress = dragProgress {
            let footer: CGFloat = model.voiceActive || model.voiceError ? 112 : 48
            let final = frameForSize(giant: true).size
            let availableHeight = max(topHeight, size.height - progress * (topHeight + footer))
            giantEyes.frame = NSRect(x: 24 * progress, y: footer * progress, width: max(0, size.width - 48 * progress), height: min(availableHeight, final.height - topHeight - footer))
            eyes.alphaValue = max(0, 1 - progress * 5)
            giantEyes.alphaValue = min(1, progress * 3)
            faceGesture.frame = surface.bounds
            return
        }
        if model.giantEyes {
            let footer: CGFloat = model.voiceActive || model.voiceError ? 112 : 48
            giantEyes.frame = NSRect(x: 24, y: footer, width: max(0, size.width - 48), height: max(0, size.height - topHeight - footer))
            content.frame = NSRect(x: 15, y: 0, width: max(0, size.width - 30), height: footer)
            faceGesture.frame = NSRect(x: 15, y: footer, width: max(0, size.width - 30), height: max(0, size.height - footer))
        } else {
            content.frame = NSRect(x: 15, y: 0, width: max(0, size.width - 30), height: max(0, size.height - topHeight))
            faceGesture.frame = NSRect(x: (size.width - eyeWidth) / 2, y: size.height - topHeight, width: eyeWidth, height: topHeight)
        }
    }

    func position() {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        self.screen = screen
        let left = screen.auxiliaryTopLeftArea?.maxX
        let right = screen.auxiliaryTopRightArea?.minX
        let hasNotch = left != nil && right != nil && screen.safeAreaInsets.top > 0
        let pad = PixieSkin.current.compactPadding
        eyeWidth = (hasNotch ? right! - left! + 72 : 86) + 2 * pad
        topHeight = hasNotch ? max(30, screen.safeAreaInsets.top) : 32
        center = hasNotch ? (left! + right!) / 2 : screen.frame.midX
        eyes.eyeCenters = (hasNotch ? [18, eyeWidth - 2 * pad - 18] : [28, 58]).map { $0 + pad }
        resize(animated: false)
        panel.orderFrontRegardless()
    }

    func welcomeInvitation() { model.invitation = true; setGiant(true) }

    func voice(state: VoiceState, message: String) {
        if state == .connecting { model.invitation = false }
        model.status = message
        model.voiceActive = state == .connecting || state == .listening || state == .speaking || state == .closing
        model.voiceError = state == .failed
        resize()
    }

    func musicStatus(_ message: String, error: Bool) {
        setGiant(false)
        model.musicVisible = true
        model.musicStatus = message
        model.musicError = error
        resize()
    }

    func track(_ track: MusicTrack?, artwork: NSImage?) {
        let changed = model.track?.identity != track?.identity
        model.track = track
        model.artwork = artwork
        if changed { resize() }
    }

    private func frameForSize(giant: Bool) -> NSRect {
        guard let screen else { return .zero }
        let hasContent = model.voiceActive || model.voiceError || model.musicVisible
        let width: CGFloat = giant ? min(screen.frame.width - 40, max(350, eyeWidth + 50)) : hasContent ? max(390, eyeWidth + 30) : eyeWidth
        let body: CGFloat = giant ? (model.voiceActive || model.voiceError ? 234 : 170) : model.musicVisible ? (model.track == nil ? 205 : (model.musicError ? 440 : 405)) + (model.voiceActive || model.voiceError ? 35 : 0) : hasContent ? 98 : 0
        let height = min(screen.frame.height - 70, topHeight + body)
        return NSRect(x: center - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    private func dragFace(delta: CGFloat, finished: Bool) {
        if dragProgress == nil { dragStartedGiant = model.giantEyes }
        let progress = min(1, max(0, (dragStartedGiant ? 1 : 0) + delta / 220))
        if finished { onInteraction?("notch_drag"); setGiant(progress >= 0.5); return }
        dragProgress = progress
        let small = frameForSize(giant: false), large = frameForSize(giant: true)
        let width = small.width + (large.width - small.width) * progress
        let height = small.height + (large.height - small.height) * progress
        let frame = NSRect(x: small.midX - width / 2, y: small.maxY - height, width: width, height: height)
        eyes.isHidden = false
        giantEyes.isHidden = false
        content.alphaValue = 0
        panel.setFrame(frame, display: true)
        layoutChildren()
        surface.needsDisplay = true
    }

    private func resize(animated: Bool = true) {
        guard screen != nil, dragProgress == nil else { return }
        expanded = model.giantEyes || model.voiceActive || model.voiceError || model.musicVisible
        let frame = frameForSize(giant: model.giantEyes)
        guard frame != targetFrame || panel.frame != frame else { layoutChildren(); return }
        targetFrame = frame
        panel.ignoresMouseEvents = false
        content.isHidden = !expanded
        eyes.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        content.autoresizingMask = [.width, .height]
        // Position in the target geometry; autoresizing tracks intermediate frames.
        if animated && panel.frame != .zero {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.32
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
        // Use current bounds while animation runs; autoresizing keeps eyes at the top.
        let size = surface.bounds.size
        eyes.frame = NSRect(x: (size.width - eyeWidth) / 2, y: size.height - topHeight, width: eyeWidth, height: topHeight)
        content.frame = NSRect(x: 15, y: 0, width: size.width - 30, height: max(0, size.height - topHeight))
        layoutChildren()
        surface.needsDisplay = true
    }
}
