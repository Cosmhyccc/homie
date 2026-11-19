import AppKit
import ApplicationServices

struct MusicTrack: Decodable {
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let position: Double
    let playing: Bool
    var identity: String { title + "|" + artist + "|" + album }
    var result: [String: Any] {
        ["status": playing ? "playing" : "paused", "song": title, "artist": artist, "album": album]
    }
}

/// A narrow local integration. The model can request only the functions listed below.
/// Catalog playback resolves the exact song through Accessibility before activating its row.
final class MusicController {
    var onTrack: ((MusicTrack?, NSImage?) -> Void)?
    var onStatus: ((String, Bool) -> Void)?
    private let queue = DispatchQueue(label: "local.pixie.music", qos: .userInitiated)
    private var timer: Timer?
    private var refreshing = false
    private var refreshFailures = 0
    private var busy = false
    private var track: MusicTrack?
    private var artwork: NSImage?
    private var artworkIdentity = ""
    private var operation = UUID()

    static let tools: [[String: Any]] = [
        ["type": "function", "name": "play_apple_music", "description": "Find and play a song in the Apple Music app on this Mac, then show its real player in Pixie's notch. Use when the user requests Apple Music, not Spotify. Preserve the established music provider for follow-up requests. Never claim success until this tool returns status playing.", "parameters": ["type": "object", "properties": ["song": ["type": "string", "description": "Song title only"], "artist": ["type": "string", "description": "Artist, or empty if not specified"]], "required": ["song", "artist"], "additionalProperties": false], "strict": true],
        ["type": "function", "name": "control_apple_music", "description": "Control Apple Music or show its current track in Pixie's notch. Do not use for Spotify or follow-ups to Spotify playback.", "parameters": ["type": "object", "properties": ["action": ["type": "string", "enum": ["pause", "resume", "next", "previous", "show", "open"]]], "required": ["action"], "additionalProperties": false], "strict": true],
        ["type": "function", "name": "set_music_volume", "description": "Adjust only Apple Music volume, preserving Pixie's voice and Mac system volume. For quieter/louder use decrease/increase by 10 percentage points unless specified. For set to 20 percent use set with amount 20. For mute use set 0. Never claim success before the result.", "parameters": ["type": "object", "properties": ["mode": ["type": "string", "enum": ["set", "increase", "decrease"]], "amount": ["type": "integer", "minimum": 0, "maximum": 100]], "required": ["mode", "amount"], "additionalProperties": false], "strict": true]
    ]

    func execute(name: String, arguments: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        guard !busy else { completion(["status": "error", "message": "Another Music action is still running. Wait for its result."]); return }
        guard name == "play_apple_music" || name == "control_apple_music" || name == "set_music_volume" else {
            completion(["status": "error", "message": "Unknown tool."]); return
        }
        busy = true
        let id = UUID()
        operation = id
        if name != "set_music_volume" { onStatus?(name == "play_apple_music" ? "Finding your song…" : "Opening Apple Music…", false) }
        Task { @MainActor in
            do {
                let result: [String: Any]
                if name == "play_apple_music" {
                    let song = (arguments["song"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let artist = (arguments["artist"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !song.isEmpty, song.count <= 200, artist.count <= 200 else { throw MusicFailure.message("Please give me a song title and optionally an artist.") }
                    result = try await play(song: song, artist: artist, operation: id)
                } else if name == "set_music_volume" {
                    result = try await volume(arguments)
                } else {
                    result = try await control(arguments["action"] as? String ?? "")
                }
                guard operation == id else { return }
                busy = false
                startMonitoring()
                completion(result)
            } catch {
                guard operation == id else { return }
                busy = false
                let message = error.localizedDescription
                onStatus?(message, true)
                completion(["status": "error", "message": message])
            }
        }
    }

    func cancelPending() {
        operation = UUID()
        busy = false
    }

    @MainActor private func play(song: String, artist: String, operation id: UUID) async throws -> [String: Any] {
        let began = ProcessInfo.processInfo.systemUptime
        func timing(_ phase: String) {
            Diagnostics.shared.record("music_stage_ms", category: phase, number: Int((ProcessInfo.processInfo.systemUptime-began)*1000))
        }
        // Both reads belong to this explicit playback request and are independent.
        async let readiness = musicCommand("state")
        let match = try await findSong(title: song, artist: artist)
        timing("catalog")
        guard operation == id else { throw CancellationError() }
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            throw MusicFailure.message("Enable Pixie in System Settings → Privacy & Security → Accessibility, then ask again. This lets Pixie press the exact song’s Play button in Music.")
        }
        guard var components = URLComponents(string: match.trackViewUrl), components.host == "music.apple.com" else {
            throw MusicFailure.message("Apple returned an unsupported song link.")
        }
        components.scheme = "music"
        guard let url = components.url else { throw MusicFailure.message("Couldn’t open that song link.") }
        onStatus?("Opening \(match.trackName)…", false)
        NSWorkspace.shared.open(url)
        var pressed = false
        for attempt in 0..<40 {
            guard operation == id else { throw CancellationError() }
            if try await pressSongPlay(catalogID: match.trackId, title: match.trackName) { pressed = true; break }
            // Music sometimes ignores the link while another page is showing; ask once more.
            // Saif's test: the first link was ignored and the row only appeared ~1 s after the attempt-12 re-open (7 s total).
            if attempt == 4 || attempt == 14 { NSWorkspace.shared.open(url) }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard pressed else { throw MusicFailure.message("I opened the song, but couldn’t find its Play button. Make sure Apple Music is signed in and the song is available.") }
        timing("play_dispatched")
        // Music's status check runs alongside opening the song; only verification needs its answer.
        _ = try await readiness
        timing("ready")
        onStatus?("Starting \(match.trackName)…", false)
        // A correct double-click starts playback in about a second; don't make the user wait 15.
        let verificationDeadline = Date().addingTimeInterval(6)
        var repressed = false
        for attempt in 0..<24 {
            // Music sometimes takes the double-click as a select only (the row turns red, nothing plays). Seen with
            // "Espresso" in Saif's test, while another song kept playing. If it isn't playing after ~1.4 s, double-click the row once more.
            if attempt == 4, !repressed {
                repressed = true
                let now = (try? await snapshot()) ?? nil
                let playingIt = now?.playing == true && Self.normalized(now?.title ?? "") == Self.normalized(match.trackName)
                if !playingIt, try await pressSongPlay(catalogID: match.trackId, title: match.trackName) {
                    Diagnostics.shared.record("music_repress", category: "select_only")
                }
            }
            guard Date() < verificationDeadline else { break }
            guard operation == id else { throw CancellationError() }
            if let actual = try? await snapshot(), actual.playing,
               Self.normalized(actual.title) == Self.normalized(match.trackName),
               Self.normalized(actual.artist) == Self.normalized(match.artistName) {
                timing("verified")
                publish(actual)
                if actual.album == match.collectionName, let art = match.artworkUrl100 { loadArtwork(art, identity: actual.identity) }
                onStatus?("Playing in Apple Music", false)
                return actual.result
            }
            try await Task.sleep(for: .milliseconds(350))
        }
        throw MusicFailure.message("Music didn’t confirm playback of \(match.trackName). Check your Apple Music subscription or any dialog in Music.")
    }

    @MainActor private func control(_ action: String) async throws -> [String: Any] {
        let commands = Set(["pause", "resume", "next", "previous"])
        if action == "open" {
            _ = try await musicCommand("open")
        } else if commands.contains(action) {
            _ = try await musicCommand(action)
            try await Task.sleep(for: .milliseconds(250))
        } else if action != "show" { throw MusicFailure.message("Unsupported Music action.") }
        let current = try await snapshot()
        publish(current)
        if let current {
            if action == "pause", current.playing { throw MusicFailure.message("Music hasn’t paused yet.") }
            if action == "resume", !current.playing { throw MusicFailure.message("Music hasn’t started playing. Choose a song first.") }
            onStatus?(current.playing ? "Playing in Apple Music" : "Paused", false)
            return current.result
        }
        onStatus?("Ask Pixie to play a song", false)
        return ["status": "opened", "message": "Music is open. No current track."]
    }

    static func volumeTarget(current: Int, mode: String, amount: Int) throws -> Int {
        guard (0...100).contains(amount), ["set", "increase", "decrease"].contains(mode) else {
            throw MusicFailure.message("Use a volume from 0 to 100 percent.")
        }
        let base = min(100, max(0, current))
        return min(100, max(0, mode == "set" ? amount : base + (mode == "increase" ? amount : -amount)))
    }

    @MainActor private func volume(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let mode = arguments["mode"] as? String,
              let amount = arguments["amount"] as? NSNumber,
              CFGetTypeID(amount) != CFBooleanGetTypeID(),
              amount.doubleValue.isFinite, amount.doubleValue.rounded() == amount.doubleValue,
              (0...100).contains(amount.doubleValue) else { throw MusicFailure.message("Use a whole-number volume from 0 to 100 percent.") }
        let before = try JSONDecoder().decode(Int.self, from: await musicCommand("volume_get"))
        let target = try Self.volumeTarget(current: before, mode: mode, amount: amount.intValue)
        let actual = try JSONDecoder().decode(Int.self, from: await musicCommand("volume_set", volume: target))
        guard actual == target else { throw MusicFailure.message("Music didn’t confirm the requested volume. Please try again.") }
        return ["status": "volume_changed", "volume_percent": actual, "previous_volume_percent": before, "scope": "Apple Music only"]
    }

    func button(_ action: String) { execute(name: "control_apple_music", arguments: ["action": action]) { _ in } }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func findSong(title: String, artist: String) async throws -> CatalogSong {
        try await SongCatalog.findSong(title: title, artist: artist)
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    // Run OSA in its own process: in-process NSAppleScript timed out on this
    // Mac despite Music responding immediately to the same out-of-process event.
    // Every source string is fixed here; no model or song text becomes script code.
    private func musicCommand(_ action: String, volume: Int = 0) async throws -> Data {
        let safeVolume = min(100, max(0, volume))
        let sources = [
            "volume_get": "JSON.stringify(m.soundVolume())",
            "volume_set": "m.soundVolume = \(safeVolume); JSON.stringify(m.soundVolume())",
            "state": "JSON.stringify(m.playerState())",
            "open": "m.activate(); JSON.stringify(true)",
            "pause": "m.pause(); JSON.stringify(true)",
            "resume": "m.play(); JSON.stringify(true)",
            "next": "m.nextTrack(); JSON.stringify(true)",
            "previous": "m.backTrack(); JSON.stringify(true)",
            "snapshot": "JSON.stringify(m.currentTrack.exists() ? {title:m.currentTrack.name(),artist:m.currentTrack.artist(),album:m.currentTrack.album(),duration:m.currentTrack.duration(),position:m.playerPosition(),playing:m.playerState() === 'playing'} : null)"
        ]
        guard let source = sources[action] else { throw MusicFailure.message("Unsupported Music command.") }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-l", "JavaScript", "-e", "const m = Application('com.apple.Music'); " + source]
                let output = Pipe(), errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                do {
                    try process.run()
                    // Commands return only tiny JSON payloads. Bound a stalled Music event.
                    let deadline = Date().addingTimeInterval(10)
                    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
                    if process.isRunning {
                        process.terminate()
                        continuation.resume(throwing: MusicFailure.message("Music took too long to respond. Try again."))
                        return
                    }
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let error = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    guard process.terminationStatus == 0 else {
                        let message = error.contains("-1743") ? "Allow Pixie to control Music in System Settings → Privacy & Security → Automation, then ask again." : "Apple Music couldn’t complete the command. Check for a dialog in Music and try again."
                        continuation.resume(throwing: MusicFailure.message(message)); return
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func snapshot() async throws -> MusicTrack? {
        try JSONDecoder().decode(MusicTrack?.self, from: await musicCommand("snapshot"))
    }

    private func startMonitoring() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard !refreshing, !busy else { return }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty else {
            publish(nil); timer?.invalidate(); timer = nil; return
        }
        refreshing = true
        Task { @MainActor in
            defer { refreshing = false }
            do {
                let current = try await snapshot()
                refreshFailures = 0
                publish(current)
            } catch {
                refreshFailures += 1
                // Music briefly rejects metadata requests while changing tracks.
                if refreshFailures >= 3 { timer?.invalidate(); timer = nil; onStatus?(error.localizedDescription, true) }
            }
        }
    }

    private func publish(_ current: MusicTrack?) {
        if current?.identity != track?.identity { artwork = nil; artworkIdentity = "" }
        track = current
        onTrack?(current, artwork)
        if let current, artworkIdentity != current.identity {
            artworkIdentity = current.identity
            Task { @MainActor in
                // Resolve artwork only when title, artist and album match the actual track.
                if let match = try? await findSong(title: current.title, artist: current.artist),
                   match.collectionName == current.album, let url = match.artworkUrl100,
                   track?.identity == current.identity { loadArtwork(url, identity: current.identity) }
            }
        }
    }

    private func loadArtwork(_ url: String, identity: String) {
        guard let url = URL(string: url.replacingOccurrences(of: "100x100bb", with: "600x600bb")), url.scheme == "https", url.host?.hasSuffix("mzstatic.com") == true else { return }
        Task { @MainActor in
            if let (data, _) = try? await URLSession.shared.data(from: url), track?.identity == identity, let image = NSImage(data: data) {
                artwork = image; onTrack?(track, image)
            }
        }
    }

    private func pressSongPlay(catalogID: Int, title: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                // Records why an attempt could not click, so failures are diagnosable. No titles or content.
                let passStarted = ProcessInfo.processInfo.systemUptime
                func miss(_ reason: String) {
                    Diagnostics.shared.record("music_press_miss", category: reason, number: Int((ProcessInfo.processInfo.systemUptime - passStarted) * 1000))
                    continuation.resume(returning: false)
                }
                guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { miss("not_running"); return }
                // Hit-testing an inactive Music window can report its scroll area rather than the row.
                if !process.isActive { process.activate() }
                let root = AXUIElementCreateApplication(process.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 1)
                // Stop walking as soon as the exact catalog row is found. Music
                // may expose hundreds of unrelated lyric/playlist nodes.
                guard let row = Self.firstDescendant(root, matching: {
                    let identifier = Self.string($0, kAXIdentifierAttribute)
                    return identifier.contains("AlbumTrackLockup") && identifier.contains("-\(catalogID),")
                }) else { miss("no_row"); return }
                // Music's More menu varies with library state and AXPress can report
                // success without starting playback. Double-click the identified row.
                // Read its live frame; never use a guessed or hardcoded screen location.
                guard let label = Self.firstDescendant(row, matching: { Self.string($0, kAXRoleAttribute) == kAXStaticTextRole }) else { miss("no_label"); return }
                var rawPosition: CFTypeRef?, rawSize: CFTypeRef?
                guard AXUIElementCopyAttributeValue(label, kAXPositionAttribute as CFString, &rawPosition) == .success,
                      AXUIElementCopyAttributeValue(label, kAXSizeAttribute as CFString, &rawSize) == .success,
                      let rawPosition, let rawSize,
                      CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { miss("no_frame"); return }
                var origin = CGPoint.zero, size = CGSize.zero
                guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin),
                      AXValueGetValue(rawSize as! AXValue, .cgSize, &size), size.width > 0, size.height > 0 else { miss("empty_frame"); return }
                let point = CGPoint(x: origin.x + min(size.width / 2, 100), y: origin.y + size.height / 2)
                // Refuse to click if another window covers the song (including Pixie).
                var hit: AXUIElement?
                guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
                      let hit else { miss("no_hit"); return }
                var hitPID: pid_t = 0
                AXUIElementGetPid(hit, &hitPID)
                guard hitPID == process.processIdentifier else { miss(process.isActive ? "covered" : "covered_inactive"); return }
                // Music can keep rows from a previous page in its AX tree. Their frames then point at
                // whatever is on screen now, so require the hit element to sit inside the song row.
                // AX element objects from a hit-test never compare equal to ones from the tree walk, so compare
                // screen geometry: the element under the pointer must sit inside the song row's frame.
                guard let rowFrame = Self.frame(row), let hitFrame = Self.frame(hit),
                      rowFrame.insetBy(dx: -2, dy: -2).contains(hitFrame) else {
                    miss((process.isActive ? "not_row_" : "not_row_inactive_") + Self.string(hit, kAXRoleAttribute)); return
                }
                Diagnostics.shared.record("music_press_hit", category: (process.isActive ? "" : "inactive_") + Self.string(hit, kAXRoleAttribute), number: Int((ProcessInfo.processInfo.systemUptime - passStarted) * 1000))
                guard let source = CGEventSource(stateID: .hidSystemState) else { miss("no_event_source"); return }
                for count in 1...2 {
                    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { continuation.resume(returning: false); return }
                        event.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                        event.post(tap: .cghidEventTap)
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                continuation.resume(returning: true)
            }
        }
    }

    private static func string(_ element: AXUIElement, _ key: String) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value as? String ?? ""
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?, rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(rawPosition as! AXValue, .cgPoint, &origin), AXValueGetValue(rawSize as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func firstDescendant(_ root: AXUIElement, matching predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        // Search windows only: the menu bar adds hundreds of nodes and never holds the song.
        var start: [AXUIElement] = [root]
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement], !list.isEmpty { start = list }
        var queue: [(AXUIElement, Int)] = start.map { ($0, 0) }
        var cursor = 0
        // A page that is still loading can stall each AX call: keep every call short and the whole walk bounded.
        let deadline = ProcessInfo.processInfo.systemUptime + 1.5
        while cursor < queue.count && cursor < 1800 && ProcessInfo.processInfo.systemUptime < deadline {
            let (node, depth) = queue[cursor]; cursor += 1
            AXUIElementSetMessagingTimeout(node, 0.25)
            if predicate(node) { return node }
            guard depth < 18 else { continue }
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(node, kAXChildrenAttribute as CFString, &value) == .success, let children = value as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return nil
    }
}
