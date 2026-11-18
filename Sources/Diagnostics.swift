import AppKit

/// Bounded local event history. Never accepts free-form messages, arguments or transcripts.
final class Diagnostics {
    /// Set by the app (e.g. to count exports in analytics); the local core never reports anywhere itself.
    var onExported: (() -> Void)?
    static let shared = Diagnostics()
    private let queue = DispatchQueue(label: "local.pixie.diagnostics")
    private let url: URL
    private let maximumBytes = 512 * 1024
    // Accessed only on queue. Preserve transitions while suppressing repeated UI refreshes.
    private var previousEvent: (event: String, category: String, number: Int?)?
    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pixie/Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        url = base.appendingPathComponent("events.jsonl")
    }
    func record(_ event: String, category: String = "", number: Int? = nil) {
        // Only developer-owned identifiers are retained; reject arbitrary prose/secret-shaped strings.
        func label(_ value: String) -> String {
            guard value.count <= 64, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == ".") }) else { return "redacted" }
            return value
        }
        let safeEvent = label(event), safeCategory = label(category)
        queue.async {
            if safeEvent == "voice_state", let previous = self.previousEvent,
               previous.event == safeEvent, previous.category == safeCategory, previous.number == number {
                return
            }
            var entry: [String: Any] = ["time": ISO8601DateFormatter().string(from: Date()), "event": safeEvent, "category": safeCategory]
            if let number { entry["value"] = number }
            guard var data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
            data.append(10)
            let current = (try? Data(contentsOf: self.url)) ?? Data()
            var retained = current
            if retained.count + data.count > self.maximumBytes {
                retained = Data(retained.suffix(self.maximumBytes / 2))
                if let newline = retained.firstIndex(of: 10) { retained = Data(retained.suffix(from: retained.index(after: newline))) }
                else { retained = Data() }
            }
            retained.append(data)
            do {
                try retained.write(to: self.url, options: .atomic)
                self.previousEvent = (safeEvent, safeCategory, number)
            } catch { return }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.url.path)
        }
    }
    @MainActor func export() {
        let panel = NSSavePanel()
        panel.title = "Export Pixie Diagnostics"
        panel.nameFieldStringValue = "Pixie-Diagnostics.txt"
        panel.message = "Contains technical events and errors, not conversation text, recordings, passwords or screenshots. Share this file with the Pixie team."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let events = queue.sync { (try? Data(contentsOf: url)) ?? Data() }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        var output = Data("Pixie diagnostics\nVersion: \(version) (\(build))\nSystem: \(ProcessInfo.processInfo.operatingSystemVersionString)\nNo conversation content is recorded.\n\n".utf8)
        output.append(events)
        do {
            try output.write(to: destination, options: .atomic)
            onExported?()
        }
        catch {
            let alert = NSAlert(); alert.messageText = "Couldn’t save diagnostics"
            alert.informativeText = "Choose another location and try again."; alert.runModal()
        }
    }
}
