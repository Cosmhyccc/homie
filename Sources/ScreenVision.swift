import AppKit
import ScreenCaptureKit
import SwiftUI

/// One screenshot per requested look. No stream, disk files, or audio capture.
final class ScreenVision {
    static let tool: [String: Any] = [
        "type": "function", "name": "look_at_screen",
        "description": "Take a fresh screenshot when the user asks about their visible screen, this video, diagram, PDF, or what they are looking at. Already authorized for these requests; do not ask again. Never call for unrelated conversation or music commands. The screenshot will arrive as an image message. A snapshot cannot reveal earlier video audio or hidden content.",
        "parameters": ["type": "object", "properties": [:] as [String: String], "required": [] as [String], "additionalProperties": false], "strict": true
    ]

    @MainActor func capture() async throws -> String {
        // CoreGraphics preflight can disagree with ScreenCaptureKit after an app update.
        // A requested capture is the authoritative check; do not issue a second CG request.
        do {
            return try await captureAuthorizedScreen()
        } catch {
            let failure = error as NSError
            if failure.domain == SCStreamErrorDomain && failure.code == -3801 {
                ScreenAccess.shared.captureDenied()
                ScreenAccess.shared.showRecovery()
                throw MusicFailure.message("macOS denied \(LocalBrain.appName)’s screen capture. Open Screen & System Audio Recording in Settings and check \(LocalBrain.appName)’s access. If its switch is already on, the saved permission is not working for this installed app; restarting alone may not resolve it.")
            }
            throw error
        }
    }

    /// The screen as pixels, with homie's own overlays hidden and no ink drawn on top (homie's local eyes read it on this Mac).
    @MainActor func captureImage() async throws -> CGImage {
        try await shot(raw: true)
    }
    @MainActor private func captureAuthorizedScreen() async throws -> String {
        let image = try await shot(raw: false)
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw MusicFailure.message("Couldn’t prepare the screenshot. Please try again.")
        }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }
    @MainActor private func shot(raw: Bool) async throws -> CGImage {
        let revision = ScreenInk.shared.revision
        let screen = (ScreenInk.shared.strokes.isEmpty ? nil : ScreenInk.shared.screen) ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw MusicFailure.message("No display is available to look at.")
        }
        // Hide only overlays. Normal Pixie windows are real screen content too.
        let overlayIDs = Set(NSApp.windows.filter { $0.level != .normal }.compactMap { CGWindowID(exactly: $0.windowNumber) })
        let ownWindows = content.windows.filter { overlayIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        let configuration = SCStreamConfiguration()
        // The cloud brain gets a ≤1600 px picture; local text reading wants full Retina pixels so small text stays legible.
        let scale = raw ? Double(screen?.backingScaleFactor ?? 2) : min(1, 1600.0 / Double(max(display.width, display.height)))
        configuration.width = max(1, Int(Double(display.width) * scale))
        configuration.height = max(1, Int(Double(display.height) * scale))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        ScreenAccess.shared.captureSucceeded()
        if raw { return image }
        try Task.checkCancellation()
        guard revision == ScreenInk.shared.revision else { throw MusicFailure.message("The screen changed during capture. Take another look.") }
        let composited = ScreenInk.shared.composite(image)
        if let screen { _ = ScreenInk.shared.captured(on: screen) }
        return composited
    }
}


/// One shared request path: status polling never prompts, and repeated capture failures
/// open actionable recovery instead of repeatedly asking macOS for the same grant.
@MainActor final class ScreenAccess: ObservableObject {
    static let shared = ScreenAccess()
    @Published private(set) var usable = CGPreflightScreenCaptureAccess()
    private let requestedKey = "pixie.screenAccess.requested"
    private var recovery: NSPanel?
    private var captureVerified = false
    private var captureWasDenied = false
    var requested: Bool { UserDefaults.standard.bool(forKey: requestedKey) }
    func refresh() { usable = captureVerified || (!captureWasDenied && CGPreflightScreenCaptureAccess()); if usable { recovery?.orderOut(nil) } }
    func captureSucceeded() {
        captureVerified = true
        captureWasDenied = false
        usable = true
        UserDefaults.standard.set(true, forKey: requestedKey)
        recovery?.orderOut(nil)
        Diagnostics.shared.record("screen_capture", category: "verified")
    }
    func captureDenied() {
        captureVerified = false
        captureWasDenied = true
        usable = false
        UserDefaults.standard.set(true, forKey: requestedKey)
        Diagnostics.shared.record("screen_capture", category: "denied")
    }
    func request() {
        refresh()
        guard !usable else { return }
        if !requested {
            UserDefaults.standard.set(true, forKey: requestedKey)
            _ = CGRequestScreenCaptureAccess()
            refresh()
        }
    }
    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
    func showRecovery() {
        guard !usable else { return }
        if recovery == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 210), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "\(LocalBrain.appName) screen access"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: ScreenAccessRecovery(access: self))
            panel.center()
            recovery = panel
        }
        recovery?.makeKeyAndOrderFront(nil)
    }
}

private struct ScreenAccessRecovery: View {
    @ObservedObject var access: ScreenAccess
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Let \(LocalBrain.appName) see what you show it.").font(.headline)
            Text("macOS denied this capture. Check \(LocalBrain.appName) in Screen & System Audio Recording. An enabled switch does not always mean the saved permission works for this installed app.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") { access.openSettings() }.buttonStyle(.borderedProminent)
        }.padding(24).frame(width: 390, height: 210)
    }
}
