import Foundation

/// What homie learns about you on this Mac: when you're around, what you like and don't, the music and apps you use.
/// Stored only in ~/Library/Application Support/Pixie/Local/memory.json (owner-only). Never uploaded.
/// The card it writes for the model changes rarely (coarse summaries), because every change means re-reading the prompt.
struct LocalMemory: Codable {
    struct Fact: Codable, Equatable { var kind: String; var text: String; var at: Date }   // kind: like, dislike, fact, name
    var facts: [Fact] = []
    var activity: [Int] = Array(repeating: 0, count: 7 * 24)   // weekday (0 = Sunday) × hour
    var artists: [String: Int] = [:]
    var apps: [String: Int] = [:]

    // MARK: Learning

    /// Learn from what the user said. Returns a line homie can say when it learned something on purpose ("remember …").
    @discardableResult
    mutating func heard(_ raw: String, at date: Date = Date(), calendar: Calendar = .current) -> String? {
        let parts = calendar.dateComponents([.weekday, .hour], from: date)
        if let weekday = parts.weekday, let hour = parts.hour { activity[(weekday - 1) * 24 + hour] += 1 }

        let text = LocalRouter.normalize(raw)
        if let thing = Self.capture(text, #"^forget (?:that |about |the fact that )?(.+)$"#) {
            if ["everything", "everything about me", "all of it", "it all", "what you know about me", "everything you know about me"].contains(thing) { facts.removeAll(); return "Done, I forgot everything." }
            // "forget it" means never mind; only forget something specific.
            guard thing.count >= 5, !["it", "that", "this", "about it", "about that", "it then", "that then"].contains(thing) else { return nil }
            let before = facts.count
            let theirs = Self.firstPerson(thing)
            facts.removeAll { fact in [thing, theirs].contains { fact.text.lowercased().contains($0) || $0.contains(fact.text.lowercased()) } }
            return facts.count < before ? "Forgot it." : nil
        }
        if let name = Self.capture(text, #"^(?:call me|my name is|my name's) ([a-z][a-z' -]{0,24})$"#) {
            facts.removeAll { $0.kind == "name" }
            add("name", Self.title(name), at: date); return nil
        }
        if let fact = Self.capture(text, #"^(?:remember|don't forget|dont forget) (?:that )?(.{3,120})$"#),
           fact.range(of: #"^(to|me|when|what|how|where|who|why|the time|that time|this|it)\b"#, options: .regularExpression) == nil {   // "remember to buy milk" is a reminder
            add("fact", Self.firstPerson(fact), at: date); return "Got it, I'll remember that."
        }
        for (pattern, kind) in [(#"\bi (?:really |absolutely |kinda |kind of )?(?:hate|can't stand|cant stand|don't like|dont like|do not like|dislike|am not a fan of|'m not a fan of|m not a fan of) (.{2,60})$"#, "dislike"),
                                (#"\bi (?:really |absolutely |kinda |kind of )?(?:love|like|enjoy|am into|'m into|m into|am obsessed with|'m obsessed with|m obsessed with) (.{2,60})$"#, "like")] {
            if let whole = Self.capture(text, pattern),
               case let thing = whole.replacingOccurrences(of: #" (but|because|cause|so|and i|and you|though)\b.*$"#, with: "", options: .regularExpression),
               !Self.vague(thing), thing.count >= 2 {
                // Saying the opposite later replaces the old opinion.
                facts.removeAll { ($0.kind == "like" || $0.kind == "dislike") && $0.text == thing }
                add(kind, thing, at: date); return nil
            }
        }
        if let match = Self.groups(text, #"^my (?:favorite|favourite) ([a-z ]{2,30}?) (?:is|are) (.{2,60})$"#) {
            facts.removeAll { $0.text.hasPrefix("favorite \(match[0]):") }
            add("fact", "favorite \(match[0]): \(match[1])", at: date); return nil
        }
        if let match = Self.groups(text, #"^my (wife|husband|girlfriend|boyfriend|partner|mom|mum|dad|sister|brother|son|daughter|best friend|dog|cat|boss)(?:'s name)? (?:is|is called|'s called) ([a-z][a-z' -]{0,24})$"#) {
            facts.removeAll { $0.text.hasPrefix("their \(match[0]) is") }
            add("fact", "their \(match[0]) is \(Self.title(match[1]))", at: date); return nil
        }
        if let what = Self.capture(text, #"^i(?:'m| am) (vegetarian|vegan|allergic to .{2,40}|lactose intolerant|gluten free|left handed|a student|a developer|a designer|an engineer|a founder|a nurse|a teacher|a doctor)$"#) {
            add("fact", "is " + what, at: date); return nil
        }
        if let place = Self.capture(text, #"^i (?:live|work|study) (?:in|at) (.{2,40})$"#) {
            let verb = text.hasPrefix("i live") ? "lives in" : text.hasPrefix("i work") ? "works at" : "studies at"
            facts.removeAll { $0.text.hasPrefix(verb) }
            add("fact", "\(verb) \(Self.title(place))", at: date); return nil
        }
        return nil
    }

    /// Facts the model picked out after a conversation ("lives in Austin", "likes jazz", "hates olives").
    mutating func learned(_ lines: [String], at date: Date = Date()) {
        for raw in lines {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " -•*.\t")).lowercased()
            guard line.count >= 4, line.count <= 120, line != "none", !line.hasPrefix("the user") || line.count > 12 else { continue }
            let text = line.replacingOccurrences(of: #"^(the )?user "#, with: "", options: .regularExpression)
            if let thing = Self.capture(text, #"^(?:likes|loves|enjoys|is into) (.+)$"#) {
                facts.removeAll { $0.kind == "dislike" && $0.text == thing }; add("like", thing, at: date)
            } else if let thing = Self.capture(text, #"^(?:hates|dislikes|doesn't like|does not like|can't stand) (.+)$"#) {
                facts.removeAll { $0.kind == "like" && $0.text == thing }; add("dislike", thing, at: date)
            } else if !facts.contains(where: { $0.text.lowercased() == text }) {
                add("fact", text, at: date)
            }
        }
    }

    static let reflectPrompt = "You pick out lasting facts about the user from what they said to their voice assistant. Write one short fact per line, third person, no names of the assistant, like: lives in Austin / sister's birthday is March 3 / likes jazz / hates olives / works as a nurse. Keep: where they live or work, people and pets, birthdays, allergies and diet, likes and dislikes, hobbies, routines, goals. Skip: requests and commands, questions, moods, anything temporary or about today only. If there is nothing lasting, write NONE."

    /// Learn from what homie did for the user.
    mutating func used(_ tool: String, _ args: [String: Any]) {
        if tool == "play_apple_music", let artist = args["artist"] as? String, !artist.isEmpty { artists[artist.lowercased(), default: 0] += 1 }
        if tool == "open_app", let app = args["app"] as? String, !app.isEmpty { apps[app.lowercased(), default: 0] += 1 }
        if artists.count > 200 { artists = artists.filter { $0.value > 1 } }
        if apps.count > 200 { apps = apps.filter { $0.value > 1 } }
    }

    private mutating func add(_ kind: String, _ text: String, at date: Date) {
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: " .,!?"))
        guard !text.isEmpty else { return }
        facts.removeAll { $0.kind == kind && $0.text == text }
        facts.append(Fact(kind: kind, text: text, at: date))
        if facts.count > 60 { facts.removeFirst(facts.count - 60) }
    }

    // MARK: The card the model reads

    var card: String {
        var lines: [String] = []
        if let name = facts.last(where: { $0.kind == "name" }) { lines.append("Name: \(name.text).") }
        if let when = activeTimes { lines.append("Usually around \(when).") }
        let likes = facts.filter { $0.kind == "like" }.suffix(12).map(\.text)
        let dislikes = facts.filter { $0.kind == "dislike" }.suffix(8).map(\.text)
        if !likes.isEmpty { lines.append("Likes: " + likes.joined(separator: ", ") + ".") }
        if !dislikes.isEmpty { lines.append("Doesn't like: " + dislikes.joined(separator: ", ") + ".") }
        let top = { (counts: [String: Int]) in counts.filter { $0.value >= 2 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(4).map { Self.title($0.key) } }
        if !top(artists).isEmpty { lines.append("Often plays: " + top(artists).joined(separator: ", ") + ".") }
        if !top(apps).isEmpty { lines.append("Uses a lot: " + top(apps).joined(separator: ", ") + ".") }
        let notes = facts.filter { $0.kind == "fact" }.suffix(15).map(\.text)
        if !notes.isEmpty { lines.append("Knows: " + notes.joined(separator: "; ") + ".") }
        return String(lines.joined(separator: "\n").prefix(1200))
    }

    /// Coarse on purpose ("weekday evenings"), so the card barely changes from day to day.
    var activeTimes: String? {
        let total = activity.reduce(0, +)
        guard total >= 12 else { return nil }
        let periods: [(String, [Int])] = [("mornings", Array(5..<12)), ("afternoons", Array(12..<17)), ("evenings", Array(17..<22)), ("late at night", [22, 23, 0, 1, 2, 3, 4])]
        func count(_ hours: [Int], days: [Int]) -> Int { days.reduce(0) { sum, day in sum + hours.reduce(0) { $0 + activity[day * 24 + $1] } } }
        let ranked = periods.map { ($0.0, count($0.1, days: Array(0..<7))) }.sorted { $0.1 > $1.1 }
        var when = ranked[0].0
        if ranked[1].1 * 2 >= ranked[0].1 { when += " and " + ranked[1].0 }
        let weekend = count(Array(0..<24), days: [0, 6]), weekday = total - weekend
        if weekday >= total * 85 / 100 { when = "weekday " + when }
        else if weekend >= total * 60 / 100 { when = "weekend " + when }
        return when
    }

    // MARK: Helpers

    private static func vague(_ thing: String) -> Bool {
        ["it", "that", "this", "you", "them", "him", "her", "to", "the idea", "how", "what", "when"].contains(thing)
            || thing.hasPrefix("to ") || thing.hasPrefix("it ") || thing.hasPrefix("that ") || thing.hasPrefix("this ") || thing.hasPrefix("you ")
            || thing.hasPrefix("how ") || thing.hasPrefix("when ")
    }
    private static func firstPerson(_ text: String) -> String {
        text.replacingOccurrences(of: #"\bi'm\b"#, with: "they're", options: .regularExpression)
            .replacingOccurrences(of: #"\bi am\b"#, with: "they are", options: .regularExpression)
            .replacingOccurrences(of: #"\bmy\b"#, with: "their", options: .regularExpression)
            .replacingOccurrences(of: #"\bi\b"#, with: "they", options: .regularExpression)
    }
    static func title(_ text: String) -> String {
        text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    private static func capture(_ text: String, _ pattern: String) -> String? { groups(text, pattern)?.first }
    private static func groups(_ text: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let values = (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } }
        return values.isEmpty || values.contains(where: \.isEmpty) ? nil : values
    }

    // MARK: Storage

    static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pixie/Local/memory.json")
    static func load() -> LocalMemory {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(LocalMemory.self, from: $0) } ?? LocalMemory()
    }
    func save() {
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}
