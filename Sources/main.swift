import AppKit
import Carbon

/// homie: a voice buddy in your Mac's notch that runs entirely on your Mac.
/// Press Fn to talk, press Fn again to stop. Nothing you say leaves this computer.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notch = NotchController()
    private let music = MusicController()
    private let desktop = DesktopController()
    private let controls = MacControls()
    private let tasks = TaskController()
    private lazy var brain = MainActor.assumeIsolated { LocalBrain() }
    private var statusItem: NSStatusItem?
    private var hotkey: Timer?
    private var previousFn = false
    private var fnDownAt: Date?
    private var drawing = false
    private var talking = false
    private var lastSpeaker: Bool?
    private var caption = ""

    /// Version and build for bug reports.
    @objc private func showAbout() { NSApp.activate(ignoringOtherApps: true); NSApp.orderFrontStandardAboutPanel(nil) }
    /// Technical events only (no conversation text); the bug report template asks for this file.
    @objc private func exportDiagnostics() { MainActor.assumeIsolated { NSApp.activate(ignoringOtherApps: true); Diagnostics.shared.export() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "homie"
        let menu = NSMenu()
        menu.addItem(withTitle: "Talk to homie (Fn)", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(withTitle: "Make homie bigger / smaller", action: #selector(toggleGiant), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "About homie", action: #selector(showAbout), keyEquivalent: "")
        menu.addItem(withTitle: "Export Diagnostics…", action: #selector(exportDiagnostics), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit homie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        item.menu = menu; statusItem = item

        notch.model.control = { [weak self] action in self?.music.button(action) }
        notch.model.endVoice = { [weak self] in MainActor.assumeIsolated { self?.brain.stop() } }
        notch.model.permissions = { [weak self] in self?.music.requestAccessibility() }
        music.onTrack = { [weak self] track, artwork in self?.notch.track(track, artwork: artwork) }
        music.onStatus = { [weak self] message, error in self?.notch.musicStatus(message, error: error) }
        desktop.onStatus = { [weak self] status in self?.notch.model.visionStatus = status }

        MainActor.assumeIsolated {
            brain.tools = LocalTools.localize(MusicController.tools + DesktopController.tools + TaskController.tools + MacControls.tools
                                              + [ScreenInk.tool, ScreenInk.pathTool, ScreenInk.clearTool, LocalTools.sizeTool, HomieCanvas.tool, ScreenMarks.tool])
            brain.context = { [weak self] in MainActor.assumeIsolated { self?.desktop.taskContext() ?? [:] } }
            brain.onTool = { [weak self] name, arguments, done in self?.run(name, arguments, done) }
            brain.onCaption = { [weak self] text, assistant in self?.show(text, assistant: assistant) }
            brain.onInputLevel = { [weak self] level in self?.notch.model.inputLevel = level }
            brain.onPhase = { [weak self] phase, message in self?.phase(phase, message) }
            brain.warm()   // engines start now so the first Fn is fast; the brain downloads once on a fresh Mac
        }

        notch.position()
        NotificationCenter.default.addObserver(self, selector: #selector(position), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Circle something while holding Fn: homie reads it on this Mac (Apple Vision) and you ask about it.
        ScreenInk.shared.onFinish = { [weak self] marked in
            guard let self, marked else { return }
            MainActor.assumeIsolated {
                if !self.talking { self.brain.start() }
                self.notch.model.caption = "Taking a peek… What would you like to know?"
                Task { @MainActor in
                    let peek = await ScreenPeek.read(picture: self.brain.hasVision)
                    self.brain.screenImage = peek?.image
                    self.brain.screenNote = peek?.note
                        ?? "They circled part of their screen, but nothing in it could be read as text. Say you can only read text on screen for now."
                }
            }
        }
        // Poll the real Fn key (not the function modifier shared by arrow keys).
        // Tap: talk / interrupt / end. Hold: draw on the screen, release to ask about it.
        previousFn = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function))
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let down = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Function))
            let alone = NSEvent.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if down && !self.previousFn && alone { self.fnDownAt = Date() }
            if down, let began = self.fnDownAt, !self.drawing, Date().timeIntervalSince(began) >= 0.28 {
                self.drawing = true
                ScreenInk.shared.begin()
                self.notch.model.visionStatus = "Draw to point · Release Fn to ask"
            }
            if !down && self.previousFn, self.fnDownAt != nil {
                self.fnDownAt = nil
                if self.drawing { self.drawing = false; self.notch.model.visionStatus = nil; ScreenInk.shared.end() }
                else { self.toggle() }
            }
            self.previousFn = down
        }
        RunLoop.main.add(timer, forMode: .common); hotkey = timer
    }

    /// Fn: start; while homie is thinking or talking, interrupt and listen; while listening, end.
    @objc private func toggle() { MainActor.assumeIsolated {
        if brain.interrupt() { return }
        talking ? brain.stop() : brain.start()
    } }
    @objc private func toggleGiant() { notch.setGiant(!notch.model.giantEyes) }
    @objc private func position() { notch.position() }

    private func run(_ name: String, _ arguments: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        if name == "clear_screen_drawings" { ScreenInk.shared.cancel(); done(["status": "cleared"]) }
        else if name == "draw_on_screen" || name == "draw_screen_path" { done(ScreenInk.shared.execute(arguments)) }
        else if ScreenMarks.owns(name) { MainActor.assumeIsolated { ScreenMarks.run(arguments, done: done) } }
        else if HomieCanvas.owns(name) { done(MainActor.assumeIsolated { HomieCanvas.shared.show(arguments) }) }
        else if name == "set_pixie_size" {
            guard let size = arguments["size"] as? String, ["giant", "small"].contains(size) else { done(["status": "error", "message": "Use giant or small."]); return }
            notch.setGiant(size == "giant"); done(["status": "resized", "size": size])
        } else if TaskController.owns(name) { MainActor.assumeIsolated { tasks.execute(name: name, arguments: arguments, completion: done) } }
        else if DesktopController.owns(name) { desktop.execute(name: name, arguments: arguments, completion: done) }
        else if MacControls.owns(name) { MainActor.assumeIsolated { controls.execute(name: name, arguments: arguments, completion: done) } }
        else { music.execute(name: name, arguments: arguments) { [weak self] result in
            MainActor.assumeIsolated { self?.desktop.noteMusicResult(name: name, result: result) }
            done(result)
        } }
    }

    private func phase(_ phase: LocalBrain.Phase, _ message: String) {
        let state: VoiceState
        switch phase {
        case .idle: state = .idle
        case .waking: state = .connecting
        case .listening, .thinking: state = .listening
        case .speaking: state = .speaking
        }
        talking = phase != .idle
        notch.voice(state: state, message: message)
        PixieCursor.shared.voice = state == .speaking ? .speaking : state == .idle ? .off : .listening
        statusItem?.button?.title = phase == .idle ? "homie" : phase == .speaking ? "homie ◦" : "homie •"
        switch phase {
        case .idle: notch.model.caption = message.isEmpty ? "" : message; lastSpeaker = nil
        case .waking: notch.model.caption = message
        case .listening where lastSpeaker == nil: notch.model.caption = "I'm here. What's on your mind?"
        default: break
        }
    }

    private func show(_ text: String, assistant: Bool) {
        if lastSpeaker != assistant { caption = "" }
        lastSpeaker = assistant
        caption = String((caption + text).suffix(4000))
        notch.model.caption = assistant ? caption : "You: " + caption
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.invalidate()
        MainActor.assumeIsolated { brain.shutdown(); ScreenGrounder.shared.shutdown() }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
