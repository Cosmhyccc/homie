import Foundation

/// homie's instant lane. Common, unambiguous commands run straight to a tool with no model
/// call, so they finish in well under a second on any Mac. Anything unclear goes to the model.
struct LocalIntent {
    let tool: String               // empty: nothing to run, just say `say`
    let args: [String: Any]
    let say: String                // spoken once the tool confirms success
    var already: String? = nil     // spoken when it was already that way
}

enum LocalRouter {
    /// Which music app a bare "pause" or "next song" means. nil when it's unclear.
    enum Music { case spotify, appleMusic }

    // MARK: Intent

    static func intent(_ raw: String, music: Music? = nil, now: Date = Date(), calendar: Calendar = .current) -> LocalIntent? {
        let text = normalize(raw)
        guard !text.isEmpty, text.split(separator: " ").count <= 12 else { return nil }

        // Timers
        if let seconds = timer(text) {
            return LocalIntent(tool: "schedule_alert", args: ["title": "Timer", "seconds": seconds, "at": ""],
                               say: "Bet, timer's set for \(spoken(seconds)).")
        }

        // "set a timer for 3 minutes for the eggs", "a 10 minute pasta timer"
        if let titled = titledTimer(text) {
            return LocalIntent(tool: "schedule_alert", args: ["title": titled.title, "seconds": titled.seconds, "at": ""],
                               say: "Bet, \(titled.title.lowercased()) timer's set for \(spoken(titled.seconds)).")
        }

        if let marking = markIntent(text) { return marking }
        if text.contains(" and ") || text.contains(" then ") || text.contains(" after ") { return nil }   // multi-step: model plans it

        if let canvas = canvas3D(text) { return canvas }

        // Time and date
        if text.range(of: #"^(what time is it|what's the time|whats the time|what is the time|time check)$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "", args: [:], say: "It's \(now.formatted(date: .omitted, time: .shortened)).")
        }
        if text.range(of: #"^(what's|whats|what is) (the date|today's date|todays date)( today)?$|^what day is (it|today)$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "", args: [:], say: "It's \(now.formatted(.dateTime.weekday(.wide).month(.wide).day())).")
        }


        // Read-outs: homie reads your data and says it itself, no model pass.
        if let day = calendarDay(text) {
            return LocalIntent(tool: "read_calendar", args: ["start_date": "", "day_offset": day, "days": 1], say: "")
        }
        if text.range(of: #"^(what's|whats|what is) on my (to ?-?do|todo|reminders?) ?(list)?$|^(what are|read|read me|tell me|show me|list) (all )?my (reminders|to ?-?dos|todos|tasks)$|^what (reminders|to ?-?dos|todos|tasks) do i have$|^(do i have )?any reminders$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "read_reminders", args: ["list_name": ""], say: "")
        }
        if text.range(of: #"^(what|which) (timers?|alarms?) do i have( set| running)?$|^(do i have|are there|is there) (any |a )?(timers?|alarms?)( running| set| going)?$|^any (timers?|alarms?)( running| set| going)?$|^how (much time is|much time's|long is|long's) left( on (my|the) timer)?$|^(list|show|check) (me )?(my |the )?(timers?|alarms?)$|^what are my (timers|alarms)$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "list_alerts", args: [:], say: "")
        }

        // Mac settings
        if let setting = macSetting(text) { return setting }

        // homie's size and drawings
        if text.range(of: #"^(make yourself |get |go )?(bigger|big|giant|huge)( eyes)?$|^giant eyes$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "set_pixie_size", args: ["size": "giant"], say: "Big mode.")
        }
        if text.range(of: #"^(make yourself |get |go )?(smaller|small|tiny|little)$|^shrink( back)?$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "set_pixie_size", args: ["size": "small"], say: "Back to tiny.")
        }
        if text.range(of: #"^(clear|erase|remove|wipe)( all)? (the |my |your )?(drawings?|ink|doodles?|scribbles?)$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "clear_screen_drawings", args: [:], say: "Wiped.")
        }

        // Screenshots
        if text.range(of: #"^(take|grab|snap|get) (a |me a )?screen ?shot$|^screen ?shot$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "take_screenshot", args: ["kind": "full"], say: "Got it, screenshot saved.")
        }
        if text.range(of: #"screen ?shot (of )?(a |this |the )?window$"#, options: .regularExpression) != nil {
            return LocalIntent(tool: "take_screenshot", args: ["kind": "window"], say: "Pick the window.")
        }

        // Music transport, only when we know which app
        if let music, let action = transport(text) {
            switch music {
            case .spotify:
                return LocalIntent(tool: "control_spotify", args: ["action": action], say: transportSay[action] ?? "Done.")
            case .appleMusic:
                return LocalIntent(tool: "control_apple_music", args: ["action": action], say: transportSay[action] ?? "Done.")
            }
        }

        // "play <song> by <artist>": straight to Apple Music. Spotify needs a search-then-click plan, so the model does it.
        if music != .spotify, !text.contains("spotify"), !text.contains("youtube"),
           let regex = try? NSRegularExpression(pattern: #"^(?:play|put on|throw on|bump) (?:the song |me )?(.+?) by (.+?)(?: on apple music| on music)?$"#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let songRange = Range(match.range(at: 1), in: text), let artistRange = Range(match.range(at: 2), in: text) {
            let song = String(text[songRange]), artist = String(text[artistRange])
            if song.split(separator: " ").count <= 8, artist.split(separator: " ").count <= 5 {
                return LocalIntent(tool: "play_apple_music", args: ["song": display(song), "artist": display(artist)], say: "Let's go.")
            }
        }

        // "play <song or artist>" when Apple Music is the player: same tool, no artist.
        if music == .appleMusic, !text.contains("spotify"), !text.contains("youtube"), !text.contains(" by "),
           let what = capture(text, #"^(?:play|put on|throw on|bump) (?:the song |me |some )?(.+?)(?: on apple music| on music)?$"#),
           what.split(separator: " ").count <= 6,
           what.range(of: #"^(something|anything|music|songs?|a song|it|that|this|my |the next|next|previous|a playlist|playlists?|albums?|radio|podcasts?|stuff)\b"#, options: .regularExpression) == nil,
           what.range(of: #"\b(playlist|album|radio|station|podcast|episode|mix|songs)$"#, options: .regularExpression) == nil {
            return LocalIntent(tool: "play_apple_music", args: ["song": display(what), "artist": ""], say: "Let's go.")
        }

        // Web search
        if let match = capture(text, #"^(?:search youtube for|look up on youtube|find on youtube|youtube) (.+)$"#) ?? capture(text, #"^(?:search for|find|look up) (.+) on youtube$"#) {
            return LocalIntent(tool: "search_web", args: ["query": match, "site": "youtube", "browser": ""], say: "Here's YouTube for \(match).")
        }
        if let match = capture(text, #"^(?:google|search google for|search the web for|search for|search|look up) (.+)$"#) {
            return LocalIntent(tool: "search_web", args: ["query": match, "site": "web", "browser": ""], say: "Pulled it up.")
        }

        // Open and quit
        if let target = capture(text, #"^(?:open|launch|start|pull up|bring up|go to)(?: up)? (?:the )?(?:app )?(.+?)(?: app)?$"#), isAppName(target) {
            if let url = website(target) {
                return LocalIntent(tool: "open_website", args: ["url": url, "browser": ""], say: "\(target.capitalized)'s up.")
            }
            guard !text.hasPrefix("go to") else { return nil }
            return LocalIntent(tool: "open_app", args: ["app": target], say: "\(display(target))'s open.")
        }
        // "close it" / "minimize this window" / "make this full screen": the front window's own buttons.
        let thisWindow = #"(?:it|this|that|this window|that window|the window|the front window)"#
        if text.range(of: #"^(?:can you |please )?close "# + thisWindow + "$", options: .regularExpression) != nil {
            return LocalIntent(tool: "window_action", args: ["action": "close"], say: "Closed.")
        }
        if text.range(of: #"^(?:can you |please )?(?:minimi[sz]e|hide) "# + thisWindow + "$", options: .regularExpression) != nil {
            return LocalIntent(tool: "window_action", args: ["action": "minimize"], say: "Tucked away.")
        }
        if text.range(of: #"^(?:can you |please )?(?:make |go |put )?(?:"# + thisWindow + #" )?full ?screen(?: "# + thisWindow + ")?$", options: .regularExpression) != nil {
            return LocalIntent(tool: "window_action", args: ["action": "fullscreen"], say: "Full screen.")
        }
        if let target = capture(text, #"^(?:quit|close|kill) (?:the )?(?:app )?(.+?)(?: app)?$"#), isAppName(target),
           !["this", "it", "that", "the window", "window", "this window", "tab", "this tab", "the tab"].contains(target) {
            return LocalIntent(tool: "quit_app", args: ["app": target], say: "Closed \(display(target)).")
        }
        return nil
    }

    /// Pointing at the screen: "circle this", "underline the deadline", "circle the Send button", "point at Settings",
    /// "where's the share button". homie finds the words or control on screen itself (ScreenMarks); no model needed.
    static func markIntent(_ text: String) -> LocalIntent? {
        if let m = text.range(of: #"^(can you |please )?(circle|underline|box|highlight) (this|that|it)$"#, options: .regularExpression) {
            let verb = String(text[m]).split(separator: " ").map(String.init).first { ["circle", "underline", "box", "highlight"].contains($0) } ?? "circle"
            return LocalIntent(tool: "mark_screen", args: ["marks": "\(verb) it"], say: "Got it.")
        }
        if let m = text.range(of: #"^where('s| is) the (.{2,30}) (button|icon|tab|link|menu|toggle|switch)$"#, options: .regularExpression) {
            let target = String(text[m]).replacingOccurrences(of: #"^where('s| is) the "#, with: "", options: .regularExpression)
            return LocalIntent(tool: "mark_screen", args: ["marks": "arrow \(target)"], say: "Right there.")
        }
        guard let m = text.range(of: #"^(can you |please )?(circle|underline|box|highlight|point at|point to) (the )?(.{2,40})$"#, options: .regularExpression) else { return nil }
        let phrase = String(text[m]).replacingOccurrences(of: #"^(can you |please )?"#, with: "", options: .regularExpression)
        let verb = phrase.hasPrefix("point") ? "arrow" : String(phrase.split(separator: " ").first ?? "circle")
        let target = phrase.replacingOccurrences(of: #"^(circle|underline|box|highlight|point at|point to) (the )?"#, with: "", options: .regularExpression)
        guard !["this", "that", "it", "everything", "all", "me"].contains(target) else { return nil }
        return LocalIntent(tool: "mark_screen", args: ["marks": "\(verb) \(target)"], say: verb == "arrow" ? "Right there." : "There.")
    }

    /// The 3D canvas by name: shapes, molecules, the solar system. Math surfaces go to the model (it turns speech into an expression).
    static func canvas3D(_ text: String) -> LocalIntent? {
        let ask = #"^(can you |could you |please )?(show|draw|make|render|build|give|display)( me| us)? (a |an |the |some )?(3d |three d )?"#
        let shapes = "sphere|ball|cube|box|torus|donut|doughnut|cone|cylinder|pyramid|capsule|helix|spiral|spring|dna helix|double helix|dna|saturn|jupiter|earth|mars|the moon|moon|atom"
        let molecules = "water|carbon dioxide|co2|methane|ammonia|benzene|ethanol|oxygen"
        func first(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : String(text[Range(m.range(at: $0), in: text)!]) }
        }
        if let m = first(ask + "(\(shapes))( model)?( in 3d| in three d)?$") {
            let shape = m[6]
            return LocalIntent(tool: "show_3d", args: ["kind": "shape", "subject": shape, "labels": "", "title": ""],
                               say: shape.contains("dna") || shape == "double helix" ? "Here's DNA's double helix. Drag it to spin it." : "Here you go. Drag it to spin it.")
        }
        if let m = first(ask + "(model of |molecule of )?(a |an )?(\(molecules))( molecule)?( model)?( in 3d)?$") ?? first("^what does (a |an )?(\(molecules)) molecule look like$").map({ ["", "", "", "", "", "", "", "", $0[2]] }),
           let name = m.dropFirst(6).first(where: { molecules.split(separator: "|").map(String.init).contains($0) }),
           text.contains("molecule") || text.contains("model") || text.contains("3d") {
            return LocalIntent(tool: "show_3d", args: ["kind": "molecule", "subject": name, "labels": "", "title": ""], say: "Here's \(name). Drag it to spin it.")
        }
        if first(ask + "(solar system|planets)( in 3d)?$") != nil {
            return LocalIntent(tool: "show_3d", args: ["kind": "planets", "subject": "", "labels": "", "title": ""], say: "Here's the solar system. Not to scale, obviously.")
        }
        if first(#"^(close|hide) (the |your |that )?(3d |three d )?(canvas|model|visualization|viz)$"#) != nil {
            return LocalIntent(tool: "show_3d", args: ["kind": "close", "subject": "", "labels": "", "title": ""], say: "Closed.")
        }
        return nil
    }

    /// How long to wait in silence before treating the user as done.
    /// A complete instant command commits fast; a sentence ending mid-thought gets extra room.
    static func endpointDelay(_ partial: String) -> Double {
        let text = normalize(partial)
        guard let last = text.split(separator: " ").last.map(String.init) else { return 0.7 }
        let dangling: Set<String> = ["and", "then", "um", "uh", "so", "to", "the", "a", "an", "for", "with", "of", "my", "like", "but",
                                     "or", "on", "in", "at", "by", "play", "open", "set", "turn", "make", "can", "could", "what's", "whats", "is",
                                     // mid-thought: "tell me something interesting about…" (cut off in Saif's test)
                                     "about", "from", "into", "if", "when", "because", "that", "which", "who", "as", "than", "how",
                                     "what", "why", "where", "your", "his", "her", "their", "our", "this", "these", "those", "some",
                                     "any", "more", "really", "very", "just", "also", "me", "something", "kind", "sort", "are", "was"]
        // "what is this" / "what's that" / "who is this" are whole questions (asked about what they circled), not cut-offs.
        let words = text.split(separator: " ").map(String.init)
        if ["this", "that", "these", "those", "it"].contains(last), words.count >= 2,
           ["is", "are", "was", "what's", "whats", "who's", "whos", "about", "read", "explain", "translate", "mean", "means", "fix"].contains(words[words.count - 2]) { return 0.6 }
        // "google best tacos near me", "turn it up for me": a complete instant command can end on a word that usually dangles.
        let completesCommand = ["me", "it", "this", "that", "more", "some", "up", "on"].contains(last) && (intent(partial, music: .spotify) ?? intent(partial, music: nil)) != nil
        if dangling.contains(last), !completesCommand { return 1.2 }
        if let fast = intent(partial, music: .spotify) ?? intent(partial, music: nil) {
            // "what's on my calendar" may still get a "tomorrow": give read-outs without a day the normal wait.
            if ["read_calendar", "read_reminders", "list_alerts"].contains(fast.tool), !["today", "tomorrow", "tonight"].contains(last) { return 0.6 }
            return 0.35
        }
        return 0.6
    }

    /// What to say after the tool ran. nil means it didn't clearly work: let the model explain the result.
    static func reply(_ intent: LocalIntent, result: [String: Any], now: Date = Date(), calendar: Calendar = .current) -> String? {
        let status = result["status"] as? String ?? ""
        let unclear: Set<String> = ["", "error", "failed", "not_running", "app_learned", "needs_confirmation", "not_found", "cancelled"]
        if unclear.contains(status) { return nil }
        if status == "looking" { return "One sec, finding it." }   // the vision pointer marks it in a few seconds
        switch intent.tool {
        case "read_calendar": return calendarLine(result, offset: intent.args["day_offset"] as? Int ?? 0, now: now, calendar: calendar)
        case "read_reminders": return remindersLine(result)
        case "list_alerts": return alertsLine(result, now: now)
        default: break
        }
        if result["already"] as? Bool == true { return intent.already ?? intent.say }
        return intent.say
    }

    // MARK: Read-outs

    private static func calendarDay(_ text: String) -> Int? {
        let day = #"(?: (today|tonight|tomorrow))?"#
        let patterns = [
            #"^(?:what's|whats|what is) (?:on )?(?:my |the )?(?:calendar|schedule|agenda)(?: look like)?(?: for)?"# + day + "$",
            #"^(?:what do i have|what have i got|what's happening|whats happening|what's going on|whats going on)(?: going on| on| planned)?(?: on my (?:calendar|schedule))?"# + day + "$",
            #"^(?:(?:do i have|have i got) )?(?:any )?(?:meetings|events|plans|anything)(?: on)?"# + day + "$",
            #"^(?:read|check|show)(?: me)? my (?:calendar|schedule)"# + day + "$",
            #"^(?:what's|whats|what does|how's|hows|how does) my day(?: look| looks| looking)?(?: like)?"# + day + "$"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
            let word = Range(match.range(at: 1), in: text).map { String(text[$0]) } ?? ""
            // "what do i have" alone is too vague; the calendar wording or a day makes it clear.
            if word.isEmpty, !text.contains("calendar"), !text.contains("my day"), !text.contains("schedule"), !text.contains("agenda"), !text.contains("meetings") { return nil }
            return word == "tomorrow" ? 1 : 0
        }
        return nil
    }

    static func clock(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        if minute == 0 && hour == 12 { return "noon" }
        if minute == 0 && hour == 0 { return "midnight" }
        let h = hour % 12 == 0 ? 12 : hour % 12
        return (minute == 0 ? "\(h)" : String(format: "%d:%02d", h, minute)) + (hour < 12 ? " AM" : " PM")
    }

    private static func list(_ items: [String], more: Int) -> String {
        var items = items
        if more > 0 { items.append("\(more) more") }
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (items.count > 2 ? "," : "") + " and " + items.last!
    }

    static func calendarLine(_ result: [String: Any], offset: Int, now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard let events = result["events"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let label = offset == 1 ? "tomorrow" : "today"
        // Today: only what's still ahead.
        let upcoming = events.filter { event in
            guard offset == 0, let end = (event["end"] as? String).flatMap(iso.date(from:)) else { return true }
            return end > now
        }
        if upcoming.isEmpty {
            return events.isEmpty ? (offset == 1 ? "Your calendar's clear tomorrow." : "Nothing on your calendar today.") : "You're done for today, nothing else on the calendar."
        }
        let shown = upcoming.prefix(4).map { event -> String in
            let title = (event["title"] as? String ?? "Something").trimmingCharacters(in: .whitespaces)
            if event["all_day"] as? Bool == true { return title + " all day" }
            guard let start = (event["start"] as? String).flatMap(iso.date(from:)) else { return title }
            return title + " at " + clock(start, calendar: calendar)
        }
        let total = max(upcoming.count, (result["total"] as? Int ?? 0) - (events.count - upcoming.count))
        let count = total == 1 ? "one thing" : "\(total) things"
        let lead = offset == 0 && upcoming.count < events.count ? "You've got \(count) left today: " : "You've got \(count) \(label): "
        return lead + list(Array(shown), more: total - shown.count) + "."
    }

    static func remindersLine(_ result: [String: Any]) -> String? {
        guard let tasks = result["tasks"] as? [[String: Any]] else { return nil }
        let total = result["total"] as? Int ?? tasks.count
        if total == 0 { return "Your to-do list is empty. Nice." }
        let shown = tasks.prefix(5).compactMap { ($0["title"] as? String)?.trimmingCharacters(in: .whitespaces) }
        return (total == 1 ? "Just one thing: " : "You've got \(total) things: ") + list(shown, more: total - shown.count) + "."
    }

    static func alertsLine(_ result: [String: Any], now: Date = Date()) -> String? {
        guard let alerts = result["alerts"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        let due = alerts.compactMap { alert -> (String, Date)? in
            guard let date = (alert["due_at"] as? String).flatMap(iso.date(from:)), date > now else { return nil }
            return (alert["title"] as? String ?? "Timer", date)
        }.sorted { $0.1 < $1.1 }
        if due.isEmpty { return "No timers running." }
        let parts = due.prefix(3).map { title, date -> String in
            let left = Int(date.timeIntervalSince(now).rounded())
            let rounded = left >= 120 ? (left + 30) / 60 * 60 : left   // "4 minutes", not "4 minutes and 12 seconds"
            let name = title == "Timer" ? "your timer" : title
            return left > 3 * 3600 ? "\(name) at \(clock(date))" : "\(name) has \(spoken(max(1, rounded))) left"
        }
        let line = list(Array(parts), more: due.count - parts.count) + "."
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    /// A timer with a name: "3 minutes for the eggs", "a 10 minute pasta timer".
    private static func titledTimer(_ text: String) -> (title: String, seconds: Int)? {
        let options: [(String, Int, Int)] = [
            (#"^(?:set|start|make)? ?(?:a |an |me a )?timer (?:for |of )?(.+?) (?:for|called|named) (?:the |my |a )?([a-z ]{2,30})$"#, 1, 2),
            (#"^(?:set|start|make)? ?(?:a |an |me a )?(.+? (?:minutes?|mins?|hours?|seconds?)) ([a-z]+(?: [a-z]+)?) timer$"#, 1, 2),
            (#"^(?:set|start|make)? ?(?:a |an |me a )?(.+? (?:minutes?|mins?|hours?|seconds?)) timer (?:for|called) (?:the |my )?([a-z ]{2,30})$"#, 1, 2)]
        for (pattern, durationGroup, titleGroup) in options {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let durationRange = Range(match.range(at: durationGroup), in: text),
                  let titleRange = Range(match.range(at: titleGroup), in: text),
                  let seconds = timer("timer for " + text[durationRange]) else { continue }
            let title = String(text[titleRange])
            guard !["when", "while", "until", "after", "before", "the", "it"].contains(where: { title.hasPrefix($0 + " ") || title == $0 }) else { return nil }
            return (display(title), seconds)
        }
        return nil
    }

    // MARK: Repairs for the model's own tool calls

    /// Small, safe fixes for mistakes a 4B model makes often. Never changes what the user asked for.
    static func repair(_ name: String, _ args: [String: Any], said: String = "", now: Date = Date(), calendar: Calendar = .current) -> [String: Any] {
        var args = args
        for (key, value) in LocalTools.defaults[name] ?? [:] where args[key] == nil { args[key] = value }
        let words = said.lowercased()
        // Only keep a browser or list the user actually named; small models fill in the frontmost app.
        for key in ["browser", "list_name"] {
            if let value = args[key] as? String, !value.isEmpty, !words.contains(value.lowercased()) { args[key] = "" }
        }
        switch name {
        case "schedule_alert":
            // Timer and clock time both filled in: the model usually computed `at` from the duration.
            if let seconds = args["seconds"] as? Int, seconds > 0, !(args["at"] as? String ?? "").isEmpty { args["at"] = "" }
            if args["at"] == nil { args["at"] = "" }
            if args["seconds"] == nil { args["seconds"] = 0 }
        case "mac_setting":
            if (args["action"] as? String) != "set" { args["level"] = -1 }
        case "read_calendar":
            // Today's date plus an offset means "relative to today": drop the date. Any other date already is the day.
            if let date = args["start_date"] as? String, !date.isEmpty {
                let formatter = DateFormatter(); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
                formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
                if date == formatter.string(from: now) { args["start_date"] = "" } else { args["day_offset"] = 0 }
            }
        case "open_website", "search_web":
            if args["browser"] == nil { args["browser"] = "" }
        default: break
        }
        return args
    }

    // MARK: Pieces

    static func normalize(_ raw: String) -> String {
        var text = raw.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"(\d):(\d)"#, with: "$1§$2", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9'%.§\- ]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "§", with: ":")
            .replacingOccurrences(of: #"\.(?![a-z])"#, with: " ", options: .regularExpression)   // keep dots inside domains
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let leading = [#"^(hey |yo |ok |okay |hi )?(homie|pixie)\b ?"#, #"^(yo|hey|ok|okay|so|um|uh|alright) "#,
                       #"^(can|could|would|will) you (please )?"#, #"^please "#, #"^i (want|need) you to "#,
                       #"^(go ahead and|just|quickly) "#]
        var changed = true
        while changed {
            changed = false
            for pattern in leading {
                let next = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
                if next != text { text = next; changed = true }
            }
        }
        for pattern in [#" (please|for me|real quick|right now|thanks|thank you|homie|pixie)$"#] {
            while let range = text.range(of: pattern, options: .regularExpression) { text.removeSubrange(range) }
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static let numbers: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
        "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "ninety": 90]

    private static func number(_ words: String) -> Int? {
        if let value = Int(words) { return value }
        var total = 0
        for word in words.split(separator: " ") {
            guard let value = numbers[String(word)] else { return nil }
            total += value
        }
        return total > 0 ? total : nil
    }

    /// "set a timer for 10 minutes", "5 minute timer", "timer for an hour and a half".
    static func timer(_ text: String) -> Int? {
        let body: String
        if let match = capture(text, #"^(?:set|start|make|put on)? ?(?:a |an |me a )?timer (?:for |of )?(.+)$"#) { body = match }
        else if let match = capture(text, #"^(?:set|start)? ?(?:a |an )?(.+?) timer$"#) { body = match }
        else { return nil }
        var rest = body.replacingOccurrences(of: "-", with: " ")
        if rest.hasSuffix(" and a half") || rest.hasSuffix(" and half") {
            rest = rest.replacingOccurrences(of: #" and (a )?half$"#, with: "", options: .regularExpression)
            guard let base = duration(rest) else { return nil }
            let unit = rest.contains("hour") ? 1800 : rest.contains("minute") ? 30 : 0
            return unit > 0 ? valid(base + unit) : nil
        }
        if rest == "half an hour" || rest == "half hour" { return 1800 }
        // Speech recognition sometimes writes "two minutes" as "2:00" (minutes:seconds).
        if let clock = capture(rest, #"^(\d{1,3}:\d{2})(?: minutes?)?$"#) {
            let parts = clock.split(separator: ":").compactMap { Int($0) }
            if parts.count == 2, parts[1] < 60 { return valid(parts[0] * 60 + parts[1]) }
        }
        return duration(rest).flatMap(valid)
    }
    private static func duration(_ text: String) -> Int? {
        let units: [(String, Int)] = [("hour", 3600), ("hr", 3600), ("minute", 60), ("min", 60), ("second", 1), ("sec", 1)]
        var total = 0, matched = false
        // "1 hour 30 minutes" means "1 hour and 30 minutes".
        let text = text.replacingOccurrences(of: #"\b(hours?|hrs?|minutes?|mins?) (?!and )(?=\S)"#, with: "$1 and ", options: .regularExpression)
        for part in text.components(separatedBy: " and ") {
            guard let unit = units.first(where: { part.range(of: "\\b\($0.0)s?$", options: .regularExpression) != nil }) else { return nil }
            let amount = part.replacingOccurrences(of: "\\s*\(unit.0)s?$", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard let value = number(amount) else { return nil }
            total += value * unit.1; matched = true
        }
        return matched ? total : nil
    }
    private static func valid(_ seconds: Int) -> Int? { (1...604_800).contains(seconds) ? seconds : nil }

    static func spoken(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) hour" + (h == 1 ? "" : "s")) }
        if m > 0 { parts.append("\(m) minute" + (m == 1 ? "" : "s")) }
        if s > 0 { parts.append("\(s) second" + (s == 1 ? "" : "s")) }
        return parts.joined(separator: " and ")
    }

    private static func macSetting(_ text: String) -> LocalIntent? {
        func make(_ setting: String, _ action: String, _ level: Int = -1, _ say: String, already: String? = nil) -> LocalIntent {
            LocalIntent(tool: "mac_setting", args: ["setting": setting, "action": action, "level": level], say: say, already: already)
        }
        let on = #"^(turn on|enable|switch on|switch to|switch it to|put it in|set it to|go|put on|activate|use|make it|go to)? ?"#
        if text.range(of: on + #"dark ?mode( on)?$"#, options: .regularExpression) != nil { return make("dark_mode", "on", -1, "Dark mode, on.", already: "You're already in dark mode.") }
        if text.range(of: #"^(turn off|disable|switch off) dark ?mode$|^dark ?mode off$"#, options: .regularExpression) != nil
            || text.range(of: on + #"light ?mode( on)?$"#, options: .regularExpression) != nil {
            return make("dark_mode", "off", -1, "Light mode, on.", already: "You're already in light mode.")
        }
        if text.range(of: #"^toggle dark ?mode$"#, options: .regularExpression) != nil { return make("dark_mode", "toggle", -1, "Flipped it.") }

        let wifi = #"(the )?wi ?-?fi"#
        if text.range(of: #"^(turn|switch) on "# + wifi + #"$|^(turn |switch )?"# + wifi + #" (back )?on$|^(enable|connect) "# + wifi + "$", options: .regularExpression) != nil { return make("wifi", "on", -1, "Wi-Fi's on.", already: "Wi-Fi's already on.") }
        if text.range(of: #"^(turn|switch) off "# + wifi + #"$|^(turn |switch )?"# + wifi + #" off$|^(disable|disconnect) "# + wifi + "$", options: .regularExpression) != nil { return make("wifi", "off", -1, "Wi-Fi's off.", already: "Wi-Fi's already off.") }

        if text.range(of: #"^(unmute|un mute)( the)?( sound| volume| audio| mac| computer)?$|^turn (the )?sound (back )?on$"#, options: .regularExpression) != nil { return make("mute", "off", -1, "Sound's back.") }
        if text.range(of: #"^mute( the| my)?( sound| volume| audio| mac| computer)?$|^turn (the )?sound off$"#, options: .regularExpression) != nil { return make("mute", "on", -1, "Muted.") }

        if let level = capture(text, #"^(?:set |turn |change )?(?:the )?(?:volume|sound) (?:to |at )?(\d{1,3})(?: ?%| percent)?$"#).flatMap({ Int($0) }), level <= 100 {
            return make("volume", "set", level, "Volume's at \(level).")
        }
        let bit = #"( a (little|bit|little bit|tad|touch))?( more)?$"#
        if text.range(of: #"^(max|full) volume$|^(turn |crank )?(the )?volume (all the way up|to (the )?max)$|^turn (it|the volume|the sound) all the way up$"#, options: .regularExpression) != nil {
            return make("volume", "set", 100, "Volume's maxed.")
        }
        if text.range(of: #"^((turn |crank )?(the )?volume up|turn (it|the volume|the sound) up|(a (little|bit|tad) )?louder|make it louder|crank it( up)?|pump it up)"# + bit, options: .regularExpression) != nil {
            return make("volume", "up", -1, "Louder.")
        }
        if text.range(of: #"^((turn )?(the )?volume down|turn (it|the volume|the sound) down|(a (little|bit|tad) )?quieter|make it quieter|softer|lower the volume)"# + bit, options: .regularExpression) != nil {
            return make("volume", "down", -1, "Quieter.")
        }

        if let level = capture(text, #"^(?:set |turn |change )?(?:the )?(?:screen )?brightness (?:to |at )?(\d{1,3})(?: ?%| percent)?$"#).flatMap({ Int($0) }), level <= 100 {
            return make("brightness", "set", level, "Brightness at \(level).")
        }
        if text.range(of: #"^(max|full) brightness$|^(turn |crank )?(the )?(screen )?brightness (all the way up|to (the )?max)$"#, options: .regularExpression) != nil {
            return make("brightness", "set", 100, "Brightness maxed.")
        }
        if text.range(of: #"^((turn )?(the )?(screen )?brightness up|(make (it|the screen) )?brighter|turn up (the )?brightness)"# + bit, options: .regularExpression) != nil {
            return make("brightness", "up", -1, "Brighter.")
        }
        if text.range(of: #"^((turn )?(the )?(screen )?brightness down|(make (it|the screen) )?(dimmer|darker)|dim (it|the screen)|turn down (the )?brightness)"# + bit, options: .regularExpression) != nil {
            return make("brightness", "down", -1, "Dimmer.")
        }
        return nil
    }

    private static let transportSay = ["pause": "Paused.", "resume": "Back on.", "next": "Skipped.", "previous": "Running it back."]
    private static func transport(_ text: String) -> String? {
        let thing = #"( the| this| my)?( music| song| track| it| spotify| apple music)?"#
        if text.range(of: "^(pause|stop)" + thing + "$", options: .regularExpression) != nil, text != "stop" { return "pause" }
        if text == "pause" { return "pause" }
        if text.range(of: "^(resume|unpause|continue|play)" + thing + "$|^keep playing$", options: .regularExpression) != nil { return "resume" }
        if text.range(of: #"^(next|skip)( it| this| that)?( song| track| one)?$|^(play the )?next (song|track|one)$"#, options: .regularExpression) != nil { return "next" }
        if text.range(of: #"^previous( song| track)?$|^(go back|back)( a| to the previous| one)? (song|track)$|^(play the )?(previous|last) (song|track)$"#, options: .regularExpression) != nil { return "previous" }
        return nil
    }

    private static let sites: [String: String] = [
        "youtube": "https://youtube.com", "gmail": "https://mail.google.com", "google": "https://google.com", "reddit": "https://reddit.com",
        "netflix": "https://netflix.com", "twitter": "https://x.com", "x": "https://x.com", "instagram": "https://instagram.com",
        "facebook": "https://facebook.com", "linkedin": "https://linkedin.com", "amazon": "https://amazon.com", "github": "https://github.com",
        "wikipedia": "https://wikipedia.org", "tiktok": "https://tiktok.com", "google docs": "https://docs.google.com", "google drive": "https://drive.google.com",
        "youtube music": "https://music.youtube.com", "twitch": "https://twitch.tv", "hacker news": "https://news.ycombinator.com"]

    private static func website(_ target: String) -> String? {
        if let site = sites[target] { return site }
        if target.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|org|net|io|ai|dev|app|co|edu|gov|tv|me|so|xyz|gg)$"#, options: .regularExpression) != nil {
            return "https://" + target
        }
        return nil
    }
    /// Short names only: "open my last email" or "open the file from yesterday" need the model.
    private static func isAppName(_ target: String) -> Bool {
        let words = target.split(separator: " ")
        let vague: Set<String> = ["my", "file", "files", "folder", "document", "email", "message", "messages from", "tab", "window", "link", "it", "that", "this", "something", "new", "last", "a"]
        return (1...3).contains(words.count) && !words.contains { vague.contains(String($0)) } && target.range(of: "[0-9]{3,}", options: .regularExpression) == nil
    }
    private static func display(_ target: String) -> String {
        target.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
    static func capture(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let value = text[range].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}

/// The tool list homie's model sees: short plain descriptions a small model follows reliably,
/// and only tools it can actually use (screen clicks and drawings need max's screen look).
enum LocalTools {
    /// The notch size tool, shared by local homie and max.
    static let sizeTool: [String: Any] = ["type": "function", "name": "set_pixie_size", "description": "Resize Pixie's notch face when asked: giant expands into large original pixel eyes with square pupils; small hides the music player and restores the original tiny pixel eyes without stopping music; an active conversation retains its compact captions. Use for make yourself bigger, giant eyes, little Pixie, shrink back. No confirmation needed.", "parameters": ["type": "object", "properties": ["size": ["type": "string", "enum": ["giant", "small"]]], "required": ["size"], "additionalProperties": false], "strict": true]
    static let hidden: Set<String> = ["click_on_screen", "scroll_screen", "draw_on_screen", "draw_screen_path"]
    static let descriptions: [String: String] = [
        "play_apple_music": "Play a song in Apple Music. Only when the user says Apple Music, or Apple Music is already their player.",
        "control_apple_music": "Pause, resume, skip, go back, show or open Apple Music.",
        "set_music_volume": "Change Apple Music's own volume. mode set/increase/decrease, amount 0-100 (10 for a bit louder or quieter).",
        "open_website": "Open a website. url like https://example.com. browser empty unless the user names one.",
        "search_web": "Search the web or YouTube in the browser. site web or youtube. browser empty unless the user names one.",
        "quit_app": "Quit an app the user named.",
        "window_action": "Close, minimize or full-screen the window the user is looking at.",
        "search_spotify": "Play music on Spotify: opens Spotify search for a song, artist or playlist. Default for play requests unless the user uses Apple Music.",
        "control_spotify": "Pause, resume, next, previous or show Spotify.",
        "switch_arc_tab": "Switch to an open Arc browser tab by its title.",
        "read_calendar": "Read calendar events. Today: start_date empty, day_offset 0. Tomorrow: start_date empty, day_offset 1. A date: start_date YYYY-MM-DD, day_offset 0. days how many days.",
        "create_note": "Make a new Apple Notes note with a title and text.",
        "open_app": "Open a Mac app by name, like Notes, Spotify or Calendar.",
        "inspect_app": "List the buttons and fields in an open app. Returns control IDs for click_app_control and type_in_app.",
        "click_app_control": "Click a control by ID from the latest inspect_app. Never buy, delete or send without the user's yes.",
        "type_in_app": "Type text into the focused field of an inspected app. Does not press return.",
        "send_chat_message": "Last step of messaging: press send on text you already typed with type_in_app. Never the first step; open_app and inspect_app first. expected_text is that exact text.",
        "create_reminder": "Add a new to-do to Reminders, like add milk to my reminders or remind me to call mom at 5. due_at ISO8601 with timezone, or empty. list_name empty unless the user names a list.",
        "read_reminders": "Read what is on the to-do list (does not add anything). list_name empty for all.",
        "complete_reminder": "Mark a reminder done by its ID from read_reminders.",
        "schedule_alert": "Timer or alarm. Timer: seconds = duration, at empty. Alarm at a clock time: at = ISO8601 time, seconds 0.",
        "list_alerts": "List homie's pending timers and alarms with IDs.",
        "cancel_alert": "Cancel a timer or alarm by ID from list_alerts.",
        "mac_setting": "Change a setting. dark_mode, wifi, mute: action on/off/toggle. brightness, volume: up/down, or set with level 0-100. level is -1 unless action is set.",
        "arrange_windows": "Place app windows, for example one left and one right for side by side. Apps must be open.",
        "take_screenshot": "Take a screenshot. kind full, selection or window.",
        "find_file": "Find files by name. choice 0 searches and lists up to 5. Then call again with a choice number to open or reveal it.",
        "press_keys": "Press a key or shortcut in an app, like return, escape, cmd+t. Never press return to send or buy without the user's yes.",
        "empty_trash": "Empty the Trash. First confirmed false to get the count and ask; confirmed true only after the user says yes.",
        "clear_screen_drawings": "Clear the drawings on screen.",
        "set_pixie_size": "Make homie big (giant) or small in the notch."
    ]
    /// Parameters the model may skip; repair fills these in. Every one it doesn't write saves ~6-8 tokens (~0.3s).
    static let defaults: [String: [String: Any]] = [
        "open_website": ["browser": ""],
        "search_web": ["site": "web", "browser": ""],
        "read_calendar": ["start_date": "", "day_offset": 0, "days": 1],
        "create_reminder": ["due_at": "", "list_name": ""],
        "read_reminders": ["list_name": ""],
        "schedule_alert": ["title": "Timer", "seconds": 0, "at": ""],
        "mac_setting": ["level": -1],
        "find_file": ["choice": 0, "action": "open"],
        "take_screenshot": ["kind": "full"],
        "set_music_volume": ["amount": 10],
        "play_apple_music": ["artist": ""],
        "show_3d": ["labels": "", "title": ""],
    ]
    static func localize(_ tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard let name = tool["name"] as? String, !hidden.contains(name) else { return nil }
            var tool = tool
            if let short = descriptions[name] { tool["description"] = short }
            if let optional = defaults[name], var parameters = tool["parameters"] as? [String: Any],
               let required = parameters["required"] as? [String] {
                parameters["required"] = required.filter { optional[$0] == nil }
                tool["parameters"] = parameters
                tool["strict"] = false
            }
            return tool
        }
    }

    /// Simple actions that finish the request on their own. When one succeeds, homie says a short line itself
    /// instead of running the model a second time just to say "done" (~1-2s saved).
    static let finished: [String: String] = [
        "create_reminder": "Added to your reminders.", "complete_reminder": "Checked off.", "schedule_alert": "Set.",
        "cancel_alert": "Cancelled.", "create_note": "Note's saved.", "mac_setting": "Done.", "take_screenshot": "Screenshot saved.",
        "set_pixie_size": "Done.", "clear_screen_drawings": "Wiped.", "show_3d": "Here it is. Drag it to spin it.", "quit_app": "Closed it.", "window_action": "Done.", "search_web": "Pulled it up.",
        "open_website": "It's up.", "arrange_windows": "Arranged.", "play_apple_music": "Let's go.", "control_apple_music": "Done.",
        "control_spotify": "Done.", "set_music_volume": "Done."]
    /// An action needs a matching word in what the user actually said. Small models sometimes call a random tool
    /// ("tell me a joke" → play a song); an ungrounded call is dropped and the model answers in words instead.
    static let grounding: [String: String] = [
        "play_apple_music": "play|put on|listen|hear|song|music|track|album|bump|throw on|queue",
        "search_spotify": "play|put on|listen|hear|song|music|track|album|spotify|bump|throw on|queue",
        "control_apple_music": "pause|stop|resume|skip|next|previous|back|play|music|song|track|apple music",
        "control_spotify": "pause|stop|resume|skip|next|previous|back|play|music|song|track|spotify",
        "set_music_volume": "volume|louder|quieter|softer|turn|music",
        "create_note": "note|write|jot",
        "create_reminder": "remind|reminder|to ?-?do|list|forget|add",
        "schedule_alert": "timer|alarm|wake|remind|minute|second|hour",
        "cancel_alert": "cancel|stop|delete|remove|clear|turn off",
        "empty_trash": "trash|bin",
        "send_chat_message": "send|text|message|tell|dm|reply|say",
        "type_in_app": "type|write|send|text|message|tell|dm|reply|say|enter|fill",
        "mac_setting": "dark|light|wi-?fi|mute|volume|louder|quieter|softer|bright|dim|sound|loud|quiet",
        "take_screenshot": "screen ?shot|capture|snap|grab",
        "quit_app": "quit|close|kill|exit",
        "window_action": "close|minimi|hide|full ?screen|window",
        "open_app": "open|launch|start|go to|pull up|bring up|show|switch|use|type|send|text|message",
        "open_website": "open|go to|pull up|bring up|show|website|site|\\.com|visit|read",
        "search_web": "search|google|look up|find|youtube|what|who|how|where|when|why",
        "arrange_windows": "left|right|side|arrange|split|window|move|put|half",
        "set_pixie_size": "big|small|giant|tiny|size|shrink|grow|huge|large",
        "find_file": "find|file|where|locate|search|open|folder|document",
        "press_keys": "press|hit|key|shortcut|tab|enter|return|escape|command|cmd",
        "click_app_control": "click|press|tap|select|choose|open|send|play|hit",
        "switch_arc_tab": "tab|switch|go to|arc"]
    static func grounded(_ tool: String, said: String) -> Bool {
        guard let pattern = grounding[tool] else { return true }   // reads and lookups are always fine
        return said.lowercased().range(of: pattern, options: .regularExpression) != nil
    }
    /// Calls that can't work as written, pointed at the step that can. Small models invent alert IDs.
    static func redirect(_ name: String, _ args: [String: Any]) -> (String, [String: Any]) {
        if name == "cancel_alert", !((args["id"] as? String) ?? "").hasPrefix("pixie.alert.") { return ("list_alerts", [:]) }
        return (name, args)
    }
    /// The part of a streamed reply that may be shown and spoken: everything before leaked tool-call markup.
    static func visible(_ text: String) -> String {
        let cut = ["<tool_call", "<function", "<parameter", "</tool_call", "</function"].compactMap { text.range(of: $0)?.lowerBound }.min()
        return cut.map { String(text[..<$0]).trimmingCharacters(in: .whitespacesAndNewlines) } ?? text
    }
    /// Text that must never be read aloud: leaked tool-call markup or the bracketed time/app note.
    static func leaked(_ phrase: String) -> Bool {
        ["<tool_call", "<function", "</", "<parameter", "frontmost app:"].contains { phrase.contains($0) }
    }
    static func doneLine(tool: String, result: [String: Any], said: String) -> String? {
        let words = " " + LocalRouter.normalize(said) + " "
        guard let line = finished[tool], !words.contains(" and "), !words.contains(" then "), !words.contains(" after "),
              !words.contains(" also ") else { return nil }
        let status = result["status"] as? String ?? ""
        guard !["", "error", "failed", "not_running", "app_learned", "needs_confirmation", "not_found", "cancelled"].contains(status) else { return nil }
        return line
    }
}
