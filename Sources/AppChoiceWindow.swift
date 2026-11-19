import AppKit
import SwiftUI

enum AppChoiceResult {
    case selected(InstalledApp)
    case learned(InstalledApp)
    case cancelled
}

/// One shared picker for real resolution and the harmless, isolated preview.
final class AppChoiceWindow: NSObject, NSWindowDelegate {
    var onQuestion: ((String) -> Void)?
    var onVoiceCue: ((String, @escaping () -> Void) -> Void)?
    private(set) var isPreview = false
    var onActive: ((Bool) -> Void)?
    private var window: NSWindow?
    private var completion: ((AppChoiceResult) -> Void)?
    private var pendingPresentation: (() -> Void)?
    private var fallback: Timer?
    private var choices: [InstalledApp] = []
    private var demo = false
    private var activationObserver: NSObjectProtocol?
    private var learningTimer: Timer?
    private var settleTimer: Timer?
    private var learning = false
    private let demoDefaults = UserDefaults(suiteName: "local.pixie.app-choice-preview")!


    @MainActor func choose(_ apps: [InstalledApp], preview: Bool = false) async -> AppChoiceResult {
        guard completion == nil else { return .cancelled }
        choices = Array(apps.prefix(5)); demo = preview; isPreview = preview
        return await withCheckedContinuation { continuation in
            completion = { continuation.resume(returning: $0) }
            let question = choices.count == 1 ? "Is this the app you meant?" : "Which of these did you mean?"
            onActive?(true)
            onQuestion?(question)
            // Open a real visible window immediately, even if voice is connecting.
            present(question: question, waitingForVoice: true)
            pendingPresentation = { [weak self] in self?.showChoices(question: question) }
            onVoiceCue?(choices.count == 1 ? "choose_one" : "choose_many", { [weak self] in self?.reveal() })
            // Voice failure must never make the picker disappear or trap the person.
            fallback = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(voiceCueTimeout), userInfo: nil, repeats: false)

        }
    }

    @objc private func voiceCueTimeout() { reveal() }

    private func reveal() {
        fallback?.invalidate(); fallback = nil
        let show = pendingPresentation; pendingPresentation = nil; show?()
    }

    private func present(question: String, waitingForVoice: Bool = false) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 370),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = demo ? "\(LocalBrain.appName) · App picker preview" : LocalBrain.appName
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            Text("Let’s find your app.").font(.system(size: 24, weight: .semibold))
            Text("\(LocalBrain.appName) is getting ready…").foregroundStyle(.secondary)
            Button("Cancel") { [weak self] in self?.cancel() }
        }.padding(30).frame(width: 460, height: 260))
        if let content = panel.contentView { panel.setContentSize(content.fittingSize) }
        window?.orderOut(nil)
        panel.center(); window = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func showChoices(question: String) {
        guard completion != nil, !learning else { return }
        window?.contentView = NSHostingView(rootView: AppChoiceView(question: question, apps: choices, preview: demo,
            selected: { [weak self] app in self?.select(app) }, cancel: { [weak self] in self?.learnFromOpening() }))
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
        window?.orderFrontRegardless()
    }

    func voiceUnavailable() {
        guard completion != nil else { return }
        fallback?.invalidate(); fallback = nil
        pendingPresentation = nil
        window?.contentView = NSHostingView(rootView: VStack(spacing: 20) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            Text("Voice is off.").font(.system(size: 24, weight: .semibold))
            Text("Your app choice is still here.").foregroundStyle(.secondary)
            Button("Reconnect \(LocalBrain.appName)") { [weak self] in self?.retryVoice() }
                .buttonStyle(.borderedProminent).tint(.indigo)
            Button("Cancel") { [weak self] in self?.cancel() }
        }.padding(30).frame(width: 460, height: 260))
        if let content = window?.contentView { window?.setContentSize(content.fittingSize) }
        window?.orderFrontRegardless()
    }

    private func retryVoice() {
        guard completion != nil else { return }
        onActive?(true)
        if learning {
            stopLearning()
            learnFromOpening()
        } else {
            let question = choices.count == 1 ? "Is this the app you meant?" : "Which of these did you mean?"
            present(question: question, waitingForVoice: true)
            pendingPresentation = { [weak self] in self?.showChoices(question: question) }
            onVoiceCue?(choices.count == 1 ? "choose_one" : "choose_many", { [weak self] in self?.reveal() })
            fallback = Timer.scheduledTimer(timeInterval: 15, target: self, selector: #selector(voiceCueTimeout), userInfo: nil, repeats: false)
        }
    }

    private func select(_ app: InstalledApp, learned: Bool = false) {
        guard (choices.contains(app) || learned), completion != nil else { return }
        stopLearning()
        if demo {
            let resolver = AppResolver(defaults: demoDefaults)
            resolver.remember("my chat app", app: app)
            let remembered: Bool
            if case .found(let saved) = AppResolver(defaults: demoDefaults).match("my chat app", in: choices + [app]) {
                remembered = saved.bundleID == app.bundleID
            } else { remembered = false }
            window?.contentView = NSHostingView(rootView: VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 42)).foregroundStyle(.green)
                Text(remembered ? "Got it. \(app.name)." : "Couldn’t save that choice.").font(.system(size: 24, weight: .semibold))
                Text("Remembered for this demo. No app was opened.").font(.system(size: 13)).foregroundStyle(.secondary)
                Button("Done") { [weak self] in self?.window?.close() }.buttonStyle(.borderedProminent).tint(.black)
            }.padding(32).frame(width: 460, height: 320))
            onVoiceCue?("remembered", {})
            finish(learned ? .learned(app) : .selected(app), closeWindow: false)
        } else { finish(learned ? .learned(app) : .selected(app)) }
    }

    func cancel() { finish(.cancelled) }
    func windowWillClose(_ notification: Notification) { finish(.cancelled, closeWindow: false); window = nil }
    private func finish(_ result: AppChoiceResult, closeWindow: Bool = true) {
        stopLearning()
        pendingPresentation = nil; fallback?.invalidate(); fallback = nil
        let done = completion; completion = nil
        if closeWindow { window?.orderOut(nil); window = nil }
        if done != nil { onActive?(false); done?(result) }
    }

    private func learnFromOpening() {
        guard completion != nil, !learning else { return }
        learning = true
        let question = "None of those? Can you open the app once so I can see which one you mean? I’ll remember it next time."
        onQuestion?(question)
        pendingPresentation = nil; fallback?.invalidate(); fallback = nil
        onVoiceCue?("learn", {})
        window?.contentView = NSHostingView(rootView: VStack(spacing: 20) {
            Image(systemName: "macwindow").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Open the app you mean.").font(.system(size: 24, weight: .semibold))
            Text("I’ll recognize it and remember for next time.").font(.system(size: 14)).foregroundStyle(.secondary)
            if demo {
                Button("Simulate opening a different app") { [weak self] in
                    guard let self, self.learning else { return }
                    let app = InstalledApp(url: URL(fileURLWithPath: "/Pixie Preview/Sketchbook.app"),
                                           bundleID: "preview.pixie.sketchbook", names: ["Sketchbook"])
                    self.select(app, learned: true)
                }.buttonStyle(.borderedProminent).tint(.indigo)
                Text("Preview only. No real apps are watched.").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Cancel") { [weak self] in self?.cancel() }.keyboardShortcut(.cancelAction)
        }.padding(30).frame(width: 460, height: 300))
        // A preview must never learn an accidental real app switch.
        if !demo {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let self, self.learning,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self.settleTimer?.invalidate()
                guard app.activationPolicy == .regular, let id = app.bundleIdentifier,
                      ![Bundle.main.bundleIdentifier ?? "local.saif.pixie", "com.apple.finder", "com.apple.Spotlight", "com.apple.systempreferences"].contains(id),
                      let url = app.bundleURL, let installed = AppResolver.installedApp(at: url), installed.bundleID == id else { return }
                // Launchers are skipped; only a stable, visible regular app counts.
                self.settleTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                    guard let self, self.learning, !app.isTerminated,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
                    self.select(installed, learned: true)
                }
            }
        }
        // Leave a demo open until explicitly dismissed; it must not vanish while
        // the founder is reading the chat. Real observers still expire promptly.
        if !demo { learningTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.cancel() } }
    }

    private func stopLearning() {
        learning = false
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        learningTimer?.invalidate(); learningTimer = nil
        settleTimer?.invalidate(); settleTimer = nil
    }

    @MainActor func preview() async {
        if let window, completion != nil {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }
        guard completion == nil else { return }
        let apps = ["Discord 2", "Discord Canary", "Discord PTB"].enumerated().map { index, name in
            InstalledApp(url: URL(fileURLWithPath: "/Pixie Preview/\(name).app"),
                         bundleID: "preview.pixie.chat.\(index)", names: [name])
        }
        _ = await choose(apps, preview: true)
    }
}

private struct AppChoiceView: View {
    let question: String
    let apps: [InstalledApp]
    let preview: Bool
    let selected: (InstalledApp) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                Text(preview ? "PIXIE · PREVIEW" : "PIXIE").font(.system(size: 11, weight: .semibold)).tracking(1.5).foregroundStyle(.secondary)
            }
            Text(question).font(.system(size: 25, weight: .semibold))
            VStack(spacing: 8) {
                ForEach(apps, id: \.url) { app in
                    Button { selected(app) } label: {
                        HStack(spacing: 12) {
                            if preview {
                                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 23)).foregroundStyle(.indigo).frame(width: 36, height: 36)
                            } else {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 36, height: 36)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).font(.system(size: 15, weight: .medium))
                                if apps.filter({ $0.name == app.name }).count > 1 {
                                    Text(app.url.deletingLastPathComponent().path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(10).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            HStack {
                Text("I’ll remember your choice\(preview ? " in this demo" : "").").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("None of these", action: cancel).font(.system(size: 12))
            }
        }.padding(28).padding(.top, 12).frame(width: 460)
    }
}
