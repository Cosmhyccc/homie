import Foundation

/// Resolves names against real bundles. It never guesses a path from a fuzzy name.
struct InstalledApp: Equatable {
    let url: URL
    let bundleID: String
    let names: [String]
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum AppMatch {
    case found(InstalledApp)
    case choose([InstalledApp])
    case missing
}

final class AppResolver {
    private let defaults: UserDefaults
    private let key = "confirmedAppNames.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func normalized(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasSuffix(".app") { text = String(text.dropLast(4)) }
        return text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    private static func copyBase(_ text: String) -> String {
        var value = text.lowercased().replacingOccurrences(of: #"\.app$"#, with: "", options: .regularExpression)
        // Finder-style copies only, not arbitrary product/version numbers.
        value = value.replacingOccurrences(of: #"(?:\s+copy(?:\s+\d+)?|\s+\(?\d+\)?)$"#, with: "", options: .regularExpression)
        return normalized(value)
    }

    func match(_ query: String, in inventory: [InstalledApp]) -> AppMatch {
        let query = Self.normalized(query)
        guard !query.isEmpty else { return .missing }
        let saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let id = saved[query], let app = Self.unique(inventory.filter { $0.bundleID == id }).first { return .found(app) }
        let exact = Self.unique(inventory.filter { $0.names.contains { Self.normalized($0) == query } })
        if exact.count == 1 { return .found(exact[0]) }
        if exact.count > 1 { return .choose(exact) }
        // Product branding often includes the vendor while the installed bundle
        // uses the shorter name (Apple Music, Apple Notes, Apple Calendar).
        if query.hasPrefix("apple") {
            let short=String(query.dropFirst(5))
            let branded=Self.unique(inventory.filter { $0.bundleID.hasPrefix("com.apple.") && $0.names.contains {Self.normalized($0)==short} })
            if branded.count == 1 {return .found(branded[0])}
            if branded.count > 1 {return .choose(branded)}
        }
        let copies = Self.unique(inventory.filter { $0.names.contains { Self.copyBase($0) == query } })
        if copies.count == 1 { return .found(copies[0]) }
        if copies.count > 1 { return .choose(copies) }
        var ranked: [(InstalledApp, Double)] = []
        for app in Self.unique(inventory) {
            let scores: [Double] = app.names.map { Self.similarity(query, Self.normalized($0)) }
            let score = scores.max() ?? 0
            if score >= 0.65 { ranked.append((app, score)) }
        }
        ranked.sort { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending
        }
        guard let best = ranked.first else { return .missing }
        // Typos/partial names always require the person's choice, even if only one looks plausible.
        return .choose(Array(ranked.filter { $0.1 >= best.1 - 0.18 }.prefix(5).map { $0.0 }))
    }

    func remember(_ query: String, app: InstalledApp) {
        guard !app.bundleID.isEmpty else { return }
        var saved = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        saved[Self.normalized(query)] = app.bundleID
        defaults.set(saved, forKey: key)
        // Retain explicitly learned locations too (for apps outside Applications).
        var paths = defaults.dictionary(forKey: "confirmedAppPaths.v1") as? [String: String] ?? [:]
        paths[app.bundleID] = app.url.path
        defaults.set(paths, forKey: "confirmedAppPaths.v1")
    }

    func rememberedApps() -> [InstalledApp] {
        let paths = defaults.dictionary(forKey: "confirmedAppPaths.v1") as? [String: String] ?? [:]
        return paths.compactMap { id, path in
            guard let app = Self.installedApp(at: URL(fileURLWithPath: path)), app.bundleID == id else { return nil }
            return app
        }
    }

    static func installedApp(at url: URL) -> InstalledApp? {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier, let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let names = [url.deletingPathExtension().lastPathComponent,
                     bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                     bundle.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap { $0 }
        return InstalledApp(url: url, bundleID: id, names: names)
    }

    private static func unique(_ apps: [InstalledApp]) -> [InstalledApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleID.isEmpty ? $0.url.path : $0.bundleID).inserted }
    }

    private static func similarity(_ a: String, _ b: String) -> Double {
        guard min(a.count, b.count) >= 3 else { return 0 }
        if b.hasPrefix(a), a.count >= 4 { return 0.85 }
        let left = Array(a), right = Array(b)
        var previous = Array(0...right.count)
        for (i, x) in left.enumerated() {
            var row = [i + 1]
            for (j, y) in right.enumerated() {
                row.append(min(row[j] + 1, previous[j + 1] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = row
        }
        return 1 - Double(previous.last!) / Double(max(left.count, right.count))
    }

    static func scan(roots: [URL]? = nil) -> [InstalledApp] {
        let roots = roots ?? ["/Applications", NSHomeDirectory() + "/Applications", "/System/Applications", "/System/Library/CoreServices/Applications"].map { URL(fileURLWithPath: $0) }
        var apps: [InstalledApp] = []
        for root in roots {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { continue }
            for case let url as URL in files {
                // macOS marks some legitimate aliases (including Safari) hidden.
                // Skip dot-directories, not every Finder-hidden application.
                if url.lastPathComponent.hasPrefix(".") { files.skipDescendants(); continue }
                guard url.pathExtension.lowercased() == "app" else { continue }
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else { continue }
                let names = [url.deletingPathExtension().lastPathComponent,
                             bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                             bundle.object(forInfoDictionaryKey: "CFBundleName") as? String].compactMap { $0 }
                apps.append(InstalledApp(url: url, bundleID: id, names: names))
            }
        }
        // Prefer the original copy when the same identity occurs more than once.
        return apps.sorted { a, b in
            if a.url.pathComponents.count != b.url.pathComponents.count { return a.url.pathComponents.count < b.url.pathComponents.count }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.url.path < b.url.path
        }
    }
}
