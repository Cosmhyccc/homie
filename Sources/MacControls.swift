import AppKit
import ApplicationServices

/// Quick Mac controls: system settings, window layouts, screenshots, files and Trash.
/// Inputs are data only: fixed enums, app names, and file choices from Pixie's own search.
@MainActor final class MacControls {
    nonisolated private static func function(_ name: String, _ description: String, _ properties: [String: Any]) -> [String: Any] {
        ["type": "function", "name": name, "description": description,
         "parameters": ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false], "strict": true]
    }
    nonisolated(unsafe) static let tools: [[String: Any]] = [
        function("mac_setting", "Change a Mac setting. dark_mode and wifi take on, off or toggle. brightness and volume take up, down or set with level 0-100 (level is -1 unless action is set). mute takes on, off or toggle. Returns the new state.",
                 ["setting": ["type": "string", "enum": ["dark_mode", "wifi", "brightness", "volume", "mute"]],
                  "action": ["type": "string", "enum": ["on", "off", "toggle", "up", "down", "set"]],
                  "level": ["type": "integer", "minimum": -1, "maximum": 100]]),
        function("arrange_windows", "Move and resize the front window of open apps, in one call for the whole layout. For side by side, give one app left and the other right. Positions: left, right, top, bottom, full, center, minimize. Apps must already be open; open_app first if needed.",
                 ["windows": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["app", "position"],
                    "properties": ["app": ["type": "string"], "position": ["type": "string", "enum": ["left", "right", "top", "bottom", "full", "center", "minimize"]]]]]]),
        function("take_screenshot", "Take a screenshot the way the user asked. full saves the whole screen silently to their usual screenshot folder. selection and window let the user pick with the mouse. Returns the saved file name.",
                 ["kind": ["type": "string", "enum": ["full", "selection", "window"]]]),
        function("find_file", "Find files by name on this Mac with Spotlight. Call with choice 0 to search; it returns up to 5 numbered matches. If one clearly matches, call again with that choice number to open it, or reveal it in Finder. Never guess a choice the user did not confirm when matches are ambiguous.",
                 ["query": ["type": "string"], "choice": ["type": "integer", "minimum": 0, "maximum": 5], "action": ["type": "string", "enum": ["open", "reveal"]]]),
        function("click_on_screen", "Click a spot on the screen with Pixie's cursor, for controls inspect_app cannot see (web pages, canvases, custom apps). First call look_at_screen, then pass its snapshot ID and normalized top-left x/y of the exact target center. button is left, right or double. Never click to buy, send, post, delete, accept terms or change security settings without the user's explicit approval of that action. Look again afterward to verify.",
                 ["snapshot": ["type": "string"], "x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1],
                  "button": ["type": "string", "enum": ["left", "right", "double"]]]),
        function("press_keys", "Press a key or shortcut in the named app, for example return, escape, tab, down, cmd+t, cmd+l, cmd+shift+n. Brings the app forward first. Never press return to send a message, submit a purchase or post unless the user explicitly asked for that exact action. Inspect or look afterward to verify.",
                 ["app": ["type": "string"], "keys": ["type": "string"]]),
        function("scroll_screen", "Scroll at a spot on the screen. Use the snapshot ID and normalized x/y from the latest look_at_screen. amount 1-10 (about three lines each).",
                 ["snapshot": ["type": "string"], "x": ["type": "number", "minimum": 0, "maximum": 1], "y": ["type": "number", "minimum": 0, "maximum": 1],
                  "direction": ["type": "string", "enum": ["up", "down", "left", "right"]], "amount": ["type": "integer", "minimum": 1, "maximum": 10]]),
        function("window_action", "Close, minimize or full-screen the front window, the one the user is looking at. For close this, close it, close the window, minimize this, make this full screen. Never quits the app; unsaved-document prompts stay with the user.",
                 ["action": ["type": "string", "enum": ["close", "minimize", "fullscreen"]]]),
        function("empty_trash", "Empty the Trash, only when the user explicitly asked. Call with confirmed false first: it returns how many items are in the Trash, then ask the user to confirm because this can't be undone. Call with confirmed true only after the user says yes.",
                 ["confirmed": ["type": "boolean"]]),
    ]
    nonisolated static func owns(_ name: String) -> Bool { tools.contains { $0["name"] as? String == name } }

    private var chain: Task<Void, Never>?
    private var found: [URL] = []
    /// When homie last asked about emptying the Trash. A yes only counts right after that question,
    /// so a model that jumps straight to confirmed true (or asks and answers itself) still gets asked first.
    private var trashAsked: Date?
    nonisolated init() {}

    /// Runs calls one after another, so a parallel batch never collides.
    func execute(name: String, arguments: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let previous = chain
        chain = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            var result: [String: Any]
            do {
                switch name {
                case "mac_setting": result = try await setting(arguments)
                case "arrange_windows": result = try arrange(arguments)
                case "take_screenshot": result = try await screenshot(arguments)
                case "find_file": result = try await findFile(arguments)
                case "empty_trash": result = try await emptyTrash(arguments)
                case "window_action": result = try windowAction(arguments)
                case "click_on_screen": result = try await clickOnScreen(arguments)
                case "press_keys": result = try await pressKeys(arguments)
                case "scroll_screen": result = try await scrollScreen(arguments)
                default: throw MusicFailure.message("Unsupported Mac control.")
                }
            } catch { result = ["status": "error", "message": error.localizedDescription] }
            completion(result)
        }
    }

    func cancel() { chain?.cancel(); chain = nil }

    // MARK: Settings

    private func setting(_ arguments: [String: Any]) async throws -> [String: Any] {
        let action = arguments["action"] as? String ?? ""
        let level = (arguments["level"] as? NSNumber)?.intValue ?? -1
        switch arguments["setting"] as? String {
        case "dark_mode":
            // The system setting, not this app's own appearance.
            let current = UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
            let target = action == "on" ? true : action == "off" ? false : !current
            if target == current { return ["status": "completed", "dark_mode": target ? "on" : "off", "already": true] }
            try await script("tell application \"System Events\" to tell appearance preferences to set dark mode to \(target)")
            return ["status": "completed", "dark_mode": target ? "on" : "off"]
        case "wifi":
            let device = try await wifiDevice()
            let state = try await run("/usr/sbin/networksetup", ["-getairportpower", device])
            let current = state.lowercased().contains(": on")
            let target = action == "on" ? true : action == "off" ? false : !current
            if target == current { return ["status": "completed", "wifi": target ? "on" : "off", "already": true] }
            _ = try await run("/usr/sbin/networksetup", ["-setairportpower", device, target ? "on" : "off"])
            return ["status": "completed", "wifi": target ? "on" : "off"]
        case "volume":
            let current = Int(try await script("output volume of (get volume settings)").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 50
            let target = max(0, min(100, action == "set" && level >= 0 ? level : action == "up" ? current + 15 : action == "down" ? current - 15 : current))
            try await script("set volume output volume \(target) without output muted")
            return ["status": "completed", "volume": target]
        case "mute":
            let muted = try await script("output muted of (get volume settings)").contains("true")
            let target = action == "on" ? true : action == "off" ? false : !muted
            try await script("set volume \(target ? "with" : "without") output muted")
            return ["status": "completed", "muted": target]
        case "brightness":
            guard let current = Brightness.get() else {
                // No readable built-in display: step with the brightness keys instead.
                guard action == "up" || action == "down" else { throw MusicFailure.message("This display’s brightness can only be stepped up or down.") }
                for _ in 0..<4 { Brightness.key(up: action == "up") }
                return ["status": "completed", "brightness": action]
            }
            let target = max(0.02, min(1, action == "set" && level >= 0 ? Float(level) / 100 : action == "up" ? current + 0.2 : action == "down" ? current - 0.2 : current))
            guard Brightness.set(target) else { throw MusicFailure.message("Couldn’t change brightness on this display.") }
            return ["status": "completed", "brightness": Int((target * 100).rounded())]
        default: throw MusicFailure.message("Unknown setting.")
        }
    }

    private func wifiDevice() async throws -> String {
        let ports = try await run("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = ports.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() where line.contains("Wi-Fi") || line.contains("AirPort") {
            if index + 1 < lines.count, let device = lines[index + 1].components(separatedBy: "Device: ").last?.trimmingCharacters(in: .whitespaces), !device.isEmpty { return device }
        }
        throw MusicFailure.message("This Mac has no Wi-Fi hardware.")
    }

    // MARK: Windows

    private func arrange(_ arguments: [String: Any]) throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw MusicFailure.message("\(LocalBrain.appName) needs Accessibility permission to move windows.") }
        guard let windows = arguments["windows"] as? [[String: Any]], !windows.isEmpty else { throw MusicFailure.message("No windows to arrange.") }
        guard let screen = NSScreen.main ?? NSScreen.screens.first, let primary = NSScreen.screens.first else { throw MusicFailure.message("No display found.") }
        let visible = screen.visibleFrame
        // Accessibility uses top-left origin coordinates measured from the primary display.
        let top = primary.frame.maxY - visible.maxY
        var done: [String] = [], missing: [String] = []
        for entry in windows.prefix(4) {
            let name = (entry["app"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            guard let app = Self.runningApp(name) else { missing.append(name); continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard (AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success
                   || AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &value) == .success),
                  let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else { missing.append(name); continue }
            let ax = window as! AXUIElement
            let position = entry["position"] as? String ?? "full"
            if position == "minimize" {
                AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
                done.append(app.localizedName ?? name); continue
            }
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            var frame = CGRect(x: visible.minX, y: top, width: visible.width, height: visible.height)
            switch position {
            case "left": frame.size.width /= 2
            case "right": frame.size.width /= 2; frame.origin.x += frame.width
            case "top": frame.size.height /= 2
            case "bottom": frame.size.height /= 2; frame.origin.y += frame.height
            case "center": frame = frame.insetBy(dx: visible.width * 0.15, dy: visible.height * 0.1)
            default: break
            }
            var origin = frame.origin, size = frame.size
            // Position, size, then position again: some apps clamp size against the old origin.
            if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, p) }
            if let s = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, s) }
            if let p = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, p) }
            app.activate()
            done.append(app.localizedName ?? name)
        }
        if done.isEmpty { throw MusicFailure.message("Couldn’t find an open window for " + missing.joined(separator: ", ") + ". Open the app first.") }
        var result: [String: Any] = ["status": "completed", "arranged": done]
        if !missing.isEmpty { result["not_open"] = missing }
        return result
    }

    /// Presses the front window's own close / minimize / full-screen button (the traffic lights), like a click would.
    private func windowAction(_ arguments: [String: Any]) throws -> [String: Any] {
        let action = arguments["action"] as? String ?? "close"
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw MusicFailure.message("Click the window you mean first, then ask again.")
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard (AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success
               || AXUIElementCopyAttributeValue(root, kAXMainWindowAttribute as CFString, &value) == .success),
              let window = value, CFGetTypeID(window) == AXUIElementGetTypeID() else {
            throw MusicFailure.message("\(app.localizedName ?? "That app") has no window open.")
        }
        let ax = window as! AXUIElement
        if action == "minimize" {
            guard AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success else { throw MusicFailure.message("That window can't be minimized.") }
            return ["status": "completed", "window": "minimized", "app": app.localizedName ?? ""]
        }
        let key = action == "fullscreen" ? kAXFullScreenButtonAttribute : kAXCloseButtonAttribute
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, key as CFString, &button) == .success, let button, CFGetTypeID(button) == AXUIElementGetTypeID(),
              AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success else {
            throw MusicFailure.message(action == "fullscreen" ? "That window can't go full screen." : "That window has no close button.")
        }
        return ["status": "completed", "window": action == "fullscreen" ? "fullscreen" : "closed", "app": app.localizedName ?? ""]
    }

    static func runningApp(_ name: String) -> NSRunningApplication? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        guard !wanted.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.lowercased() == wanted }
            ?? apps.first { $0.localizedName?.lowercased().hasPrefix(wanted) == true }
            ?? apps.first { $0.localizedName?.lowercased().contains(wanted) == true }
    }

    // MARK: Screenshot

    private func screenshot(_ arguments: [String: Any]) async throws -> [String: Any] {
        let kind = arguments["kind"] as? String ?? "full"
        let folder = (UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"))
            .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let file = folder.appendingPathComponent("Screenshot \(stamp).png")
        let flags = kind == "selection" ? ["-i", "-s"] : kind == "window" ? ["-i", "-w"] : ["-x"]
        _ = try await run("/usr/sbin/screencapture", flags + [file.path], timeout: kind == "full" ? 10 : 90)
        guard FileManager.default.fileExists(atPath: file.path) else { return ["status": "cancelled", "message": "No screenshot was taken."] }
        return ["status": "completed", "file": file.lastPathComponent, "folder": folder.lastPathComponent]
    }

    // MARK: Files

    private func findFile(_ arguments: [String: Any]) async throws -> [String: Any] {
        let choice = (arguments["choice"] as? NSNumber)?.intValue ?? 0
        if choice > 0 {
            guard choice <= found.count else { throw MusicFailure.message("Search for the file first.") }
            let url = found[choice - 1]
            guard FileManager.default.fileExists(atPath: url.path) else { throw MusicFailure.message("That file no longer exists.") }
            if arguments["action"] as? String == "reveal" { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else { NSWorkspace.shared.open(url) }
            return ["status": "opened", "file": url.lastPathComponent]
        }
        let query = (arguments["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 120 else { throw MusicFailure.message("Say part of the file name.") }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let output = try await run("/usr/bin/mdfind", ["-onlyin", home, "-name", query], timeout: 6)
        let skip = ["/Library/", "/.Trash/", "/node_modules/", "/.git/", "/DerivedData/"]
        let paths = output.split(separator: "\n").map(String.init)
            .filter { path in !skip.contains { path.contains($0) } && !(path as NSString).lastPathComponent.hasPrefix(".") }
        let ranked = paths.map { URL(fileURLWithPath: $0) }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        found = Array(ranked.prefix(5))
        guard !found.isEmpty else { return ["status": "not_found", "message": "No files named like that."] }
        return ["status": "found", "matches": found.enumerated().map { index, url in
            ["choice": index + 1, "name": url.lastPathComponent, "folder": url.deletingLastPathComponent().lastPathComponent]
        }]
    }

    private func emptyTrash(_ arguments: [String: Any]) async throws -> [String: Any] {
        // Finder knows the real count; the .Trash folder itself is privacy-protected.
        let count = Int(try await script("tell application \"Finder\" to count items of trash").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if count == 0 { trashAsked = nil; return ["status": "completed", "message": "The Trash was already empty."] }
        let askedRecently = trashAsked.map { (4..<120).contains(Date().timeIntervalSince($0)) } ?? false
        guard arguments["confirmed"] as? Bool == true, askedRecently else {
            trashAsked = Date()
            return ["status": "needs_confirmation", "items": count, "message": "Not emptied yet. Ask the user to confirm. Emptying the Trash can't be undone."]
        }
        trashAsked = nil
        try await script("tell application \"Finder\" to empty trash")
        return ["status": "completed", "emptied_items": count]
    }

    // MARK: Any app: clicks, keys and scrolling

    /// Maps a point from the latest look into global coordinates (AppKit and CoreGraphics).
    private func screenPoint(_ arguments: [String: Any]) throws -> (appKit: CGPoint, cg: CGPoint) {
        let ink = ScreenInk.shared
        guard let screen = ink.screen, let id = arguments["snapshot"] as? String, !id.isEmpty, id == ink.snapshot,
              Date().timeIntervalSince(ink.snapshotDate) < 90 else {
            throw MusicFailure.message("Look at the screen again first; that snapshot is stale.")
        }
        guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue,
              (0...1).contains(x), (0...1).contains(y), let primary = NSScreen.screens.first else { throw MusicFailure.message("Invalid screen position.") }
        let appKit = CGPoint(x: screen.frame.minX + x * screen.frame.width, y: screen.frame.maxY - y * screen.frame.height)
        return (appKit, CGPoint(x: appKit.x, y: primary.frame.maxY - appKit.y))
    }

    private func clickOnScreen(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw MusicFailure.message("\(LocalBrain.appName) needs Accessibility permission to click.") }
        let point = try screenPoint(arguments)
        let arrival = PixieCursor.shared.click(at: point.appKit)
        if arrival > 0 { try await Task.sleep(for: .milliseconds(Int(arrival * 1000))) }
        try Task.checkCancellation()
        let button = arguments["button"] as? String ?? "left"
        let restore = CGEvent(source: nil)?.location
        let source = CGEventSource(stateID: .hidSystemState)
        let (down, up, mouse): (CGEventType, CGEventType, CGMouseButton) = button == "right" ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point.cg, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(40))
        for click in 1...(button == "double" ? 2 : 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point.cg, mouseButton: mouse)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(click))
                event?.post(tap: .cghidEventTap)
            }
            if click == 1 && button == "double" { try await Task.sleep(for: .milliseconds(60)) }
        }
        // Hand the pointer back to the user where they left it.
        if let restore { try await Task.sleep(for: .milliseconds(60)); CGWarpMouseCursorPosition(restore) }
        return ["status": "click_dispatched", "message": "Look at the screen again to verify what happened."]
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
    ]
    /// Shortcuts that log out, lock, force quit or trash files are never pressed.
    private static let blocked: Set<String> = ["cmd+delete", "cmd+shift+delete", "cmd+option+shift+delete", "cmd+option+escape", "cmd+option+esc", "ctrl+cmd+q", "cmd+shift+q", "cmd+option+shift+q", "ctrl+cmd+power"]

    static func parseKeys(_ text: String) throws -> (CGKeyCode, CGEventFlags, String) {
        let parts = text.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+").map(String.init)
        guard let key = parts.last, let code = keyCodes[key], parts.count <= 4 else { throw MusicFailure.message("Unsupported key: \(text).") }
        var flags: CGEventFlags = []; var names: [String] = []
        for modifier in parts.dropLast() {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand); names.append("cmd")
            case "shift": flags.insert(.maskShift); names.append("shift")
            case "option", "opt", "alt": flags.insert(.maskAlternate); names.append("option")
            case "ctrl", "control": flags.insert(.maskControl); names.append("ctrl")
            default: throw MusicFailure.message("Unsupported modifier: \(modifier).")
            }
        }
        let order = ["ctrl", "cmd", "option", "shift"]
        let canonical = (order.filter(names.contains) + [key == "esc" ? "escape" : key]).joined(separator: "+")
        let loose = (["cmd", "option", "shift"].filter(names.contains) + [key == "esc" ? "escape" : key]).joined(separator: "+")
        guard !blocked.contains(canonical), !blocked.contains(loose) else { throw MusicFailure.message("\(LocalBrain.appName) doesn’t press that shortcut.") }
        return (code, flags, canonical)
    }

    private func pressKeys(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw MusicFailure.message("\(LocalBrain.appName) needs Accessibility permission to press keys.") }
        let (code, flags, name) = try Self.parseKeys(arguments["keys"] as? String ?? "")
        guard let app = Self.runningApp(arguments["app"] as? String ?? "") else { throw MusicFailure.message("That app isn’t open.") }
        app.activate()
        try await Task.sleep(for: .milliseconds(150))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw MusicFailure.message("The app didn’t come forward, so no keys were pressed.")
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        return ["status": "keys_dispatched", "keys": name, "app": app.localizedName ?? ""]
    }

    private func scrollScreen(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard AXIsProcessTrusted() else { throw MusicFailure.message("\(LocalBrain.appName) needs Accessibility permission to scroll.") }
        let point = try screenPoint(arguments)
        let amount = Int32(max(1, min(10, (arguments["amount"] as? NSNumber)?.intValue ?? 3))) * 3
        let direction = arguments["direction"] as? String ?? "down"
        let vertical = direction == "up" ? amount : direction == "down" ? -amount : 0
        let horizontal = direction == "left" ? amount : direction == "right" ? -amount : 0
        _ = PixieCursor.shared.click(at: point.appKit)
        let restore = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point.cg, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(40))
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)?.post(tap: .cghidEventTap)
        if let restore { try await Task.sleep(for: .milliseconds(60)); CGWarpMouseCursorPosition(restore) }
        return ["status": "scrolled", "message": "Look again to see the new content."]
    }

    // MARK: Helpers

    @discardableResult
    private func script(_ source: String) async throws -> String {
        try await run("/usr/bin/osascript", ["-e", source])
    }

    private func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 6) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process(); let pipe = Pipe(), errors = Pipe()
                process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
                process.standardOutput = pipe; process.standardError = errors
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                let deadline = DispatchTime.now() + timeout
                DispatchQueue.global().asyncAfter(deadline: deadline) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let problem = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0 { continuation.resume(returning: String(data: data, encoding: .utf8) ?? "") }
                else if problem.contains("-1743") || problem.contains("Not authorized") {
                    continuation.resume(throwing: MusicFailure.message("\(LocalBrain.appName) needs Automation permission for this. Allow it in System Settings → Privacy & Security → Automation."))
                } else { continuation.resume(throwing: MusicFailure.message("That Mac control didn’t work.")) }
            }
        }
    }
}

/// Built-in display brightness through DisplayServices, loaded at runtime; key presses otherwise.
enum Brightness {
    private typealias Getter = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias Setter = @convention(c) (UInt32, Float) -> Int32
    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static var display: UInt32 {
        var ids = [CGDirectDisplayID](repeating: 0, count: 8); var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }
    static func get() -> Float? {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesGetBrightness") else { return nil }
        var value: Float = 0
        return unsafeBitCast(symbol, to: Getter.self)(display, &value) == 0 ? value : nil
    }
    static func set(_ value: Float) -> Bool {
        guard let handle, let symbol = dlsym(handle, "DisplayServicesSetBrightness") else { return false }
        return unsafeBitCast(symbol, to: Setter.self)(display, value) == 0
    }
    static func key(up: Bool) {
        let code: Int = up ? 2 : 3 // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                               subtype: 8, data1: (code << 16) | ((down ? 0xa : 0xb) << 8), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
