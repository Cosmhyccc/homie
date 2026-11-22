import Foundation

// xcrun swiftc -parse-as-library Sources/LocalRouter.swift Tests/LocalRouterTests.swift -o /private/tmp/local-router-tests && /private/tmp/local-router-tests
@main struct LocalRouterTests {
    static var failures = 0
    static func expect(_ said: String, _ tool: String?, _ args: [String: String] = [:], music: LocalRouter.Music? = nil) {
        let intent = LocalRouter.intent(said, music: music)
        guard let tool else {
            if let intent { failures += 1; print("FALSE FIRE  \"\(said)\" -> \(intent.tool) \(intent.args)") }
            return
        }
        guard let intent, intent.tool == tool else { failures += 1; print("MISS  \"\(said)\" -> \(intent.map { $0.tool } ?? "model"), wanted \(tool)"); return }
        for (key, value) in args where "\(intent.args[key] ?? "")" != value {
            failures += 1; print("ARGS  \"\(said)\" \(key)=\(intent.args[key] ?? "nil"), wanted \(value)")
        }
    }

    static func main() {
        // Timers
        expect("Set a timer for 10 minutes.", "schedule_alert", ["seconds": "600", "at": ""])
        expect("Hey homie, set a timer for five minutes", "schedule_alert", ["seconds": "300"])
        expect("timer for 90 seconds", "schedule_alert", ["seconds": "90"])
        expect("start a 25 minute timer", "schedule_alert", ["seconds": "1500"])
        expect("set a timer for an hour and a half", "schedule_alert", ["seconds": "5400"])
        expect("set a timer for 1 hour and 15 minutes", "schedule_alert", ["seconds": "4500"])
        expect("can you set a timer for twenty five minutes please", "schedule_alert", ["seconds": "1500"])
        expect("set a timer for half an hour", "schedule_alert", ["seconds": "1800"])
        expect("Set a timer for 2:00.", "schedule_alert", ["seconds": "120"])
        expect("set a timer for 1:30", "schedule_alert", ["seconds": "90"])
        expect("set a timer", nil)
        expect("set a timer for when the pasta is done", nil)
        expect("set an alarm for 7am", nil)

        // Settings
        expect("turn on dark mode", "mac_setting", ["setting": "dark_mode", "action": "on", "level": "-1"])
        expect("Dark mode.", "mac_setting", ["setting": "dark_mode", "action": "on"])
        expect("switch to light mode", "mac_setting", ["setting": "dark_mode", "action": "off"])
        expect("turn off dark mode", "mac_setting", ["setting": "dark_mode", "action": "off"])
        expect("turn off wifi", "mac_setting", ["setting": "wifi", "action": "off"])
        expect("turn on the Wi-Fi", "mac_setting", ["setting": "wifi", "action": "on"])
        expect("mute", "mac_setting", ["setting": "mute", "action": "on"])
        expect("unmute the sound", "mac_setting", ["setting": "mute", "action": "off"])
        expect("set volume to 30%", "mac_setting", ["setting": "volume", "action": "set", "level": "30"])
        expect("volume 50", "mac_setting", ["setting": "volume", "action": "set", "level": "50"])
        expect("turn it up", "mac_setting", ["setting": "volume", "action": "up"])
        expect("make it quieter", "mac_setting", ["setting": "volume", "action": "down"])
        expect("make the screen brighter", "mac_setting", ["setting": "brightness", "action": "up"])
        expect("set brightness to 80", "mac_setting", ["setting": "brightness", "action": "set", "level": "80"])
        expect("why is dark mode bad for your eyes", nil)
        expect("what's my wifi password", nil)

        // Apps and web
        expect("open spotify", "open_app", ["app": "spotify"])
        expect("Hey Pixie, open Notes.", "open_app", ["app": "notes"])
        expect("launch the calculator app", "open_app", ["app": "calculator"])
        expect("open youtube", "open_website", ["url": "https://youtube.com"])
        expect("go to github.com", "open_website", ["url": "https://github.com"])
        expect("open figma.com", "open_website", ["url": "https://figma.com"])
        expect("quit slack", "quit_app", ["app": "slack"])
        expect("close spotify", "quit_app", ["app": "spotify"])
        expect("close this window", "window_action", ["action": "close"])
        expect("close it", "window_action", ["action": "close"])
        expect("minimize this", "window_action", ["action": "minimize"])
        expect("make this full screen", "window_action", ["action": "fullscreen"])
        expect("full screen it", "window_action", ["action": "fullscreen"])
        expect("close this tab", nil)
        expect("open my last email", nil)
        expect("open the file I was working on yesterday", nil)
        expect("open spotify and play drake", nil)
        expect("open a new tab", nil)
        expect("go to the settings", nil)
        expect("google best tacos near me", "search_web", ["query": "best tacos near me", "site": "web"])
        expect("search for flights to new york", "search_web", ["query": "flights to new york"])
        expect("search youtube for lofi beats", "search_web", ["query": "lofi beats", "site": "youtube"])
        expect("find skate videos on youtube", "search_web", ["query": "skate videos", "site": "youtube"])
        expect("find my resume", nil)

        // Music
        expect("pause", "control_spotify", ["action": "pause"], music: .spotify)
        expect("pause the music", "control_apple_music", ["action": "pause"], music: .appleMusic)
        expect("next song", "control_spotify", ["action": "next"], music: .spotify)
        expect("skip", "control_spotify", ["action": "next"], music: .spotify)
        expect("play", "control_spotify", ["action": "resume"], music: .spotify)
        expect("go back a song", "control_apple_music", ["action": "previous"], music: .appleMusic)
        expect("pause", nil)
        expect("stop", nil, music: .spotify)
        expect("play drake", "search_spotify", ["query": "drake"], music: .spotify)
        expect("play billie jean by michael jackson", "play_apple_music", ["song": "Billie Jean", "artist": "Michael Jackson"], music: .appleMusic)
        // Spotify on this Mac (music nil = installed, nothing playing) or said out loud: open it in Spotify (Nov 22 bug)
        expect("play billie jean by michael jackson", "search_spotify", ["query": "billie jean michael jackson"])
        expect("play billie jean by michael jackson", "search_spotify", ["query": "billie jean michael jackson"], music: .spotify)
        expect("open billie jean in spotify", "search_spotify", ["query": "billie jean"], music: .appleMusic)
        expect("play it on spotify", nil)
        expect("play billie jean on apple music", "play_apple_music", ["song": "Billie Jean"])
        expect("Hey homie, play Blinding Lights by The Weeknd.", "play_apple_music", ["song": "Blinding Lights", "artist": "The Weeknd"], music: .appleMusic)
        expect("play billie jean by michael jackson on spotify", "search_spotify", ["query": "billie jean michael jackson"])
        expect("play drake", "search_spotify", ["query": "drake"])
        expect("play drake", "play_apple_music", ["song": "Drake", "artist": ""], music: .appleMusic)
        expect("put on blinding lights", "play_apple_music", ["song": "Blinding Lights"], music: .appleMusic)
        expect("play some music", nil, music: .appleMusic)
        expect("play my workout playlist", nil, music: .appleMusic)
        expect("play something chill", nil, music: .appleMusic)
        expect("play drake on spotify", "search_spotify", ["query": "drake"], music: .appleMusic)
        expect("open up spotify", "open_app")
        expect("play lofi on youtube", nil, music: .appleMusic)
        expect("play", "control_apple_music", ["action": "resume"], music: .appleMusic)
        expect("play the next song", "control_apple_music", ["action": "next"], music: .appleMusic)

        // Misc
        expect("take a screenshot", "take_screenshot", ["kind": "full"])
        expect("screenshot this window", "take_screenshot", ["kind": "window"])
        expect("make yourself bigger", "set_pixie_size", ["size": "giant"])
        expect("shrink back", "set_pixie_size", ["size": "small"])
        expect("clear the drawings", "clear_screen_drawings")
        expect("what time is it", "")
        expect("what's the date today", "")
        expect("how are you", nil)
        expect("tell me a joke", nil)
        expect("what's on my calendar tomorrow", "read_calendar", ["day_offset": "1"])
        expect("what's on my calendar", "read_calendar", ["day_offset": "0"])
        expect("what do I have going on today", "read_calendar", ["day_offset": "0"])
        expect("what's my schedule look like tomorrow", "read_calendar", ["day_offset": "1"])
        expect("do I have any meetings today", "read_calendar", ["day_offset": "0"])
        expect("what do I have", nil)
        expect("am I free at 3 tomorrow", nil)
        expect("what's on my calendar next week", nil)
        expect("what's on my to do list", "read_reminders", ["list_name": ""])
        expect("what's on my to-do list", "read_reminders")
        expect("read me my reminders", "read_reminders")
        expect("what reminders do I have on my work list", nil)
        expect("what timers do I have", "list_alerts")
        expect("how much time is left on my timer", "list_alerts")
        expect("cancel my timer", nil)
        expect("set a timer for 3 minutes for the eggs", "schedule_alert", ["seconds": "180", "title": "Eggs"])
        expect("start a 10 minute pasta timer", "schedule_alert", ["seconds": "600", "title": "Pasta"])
        expect("set a timer for 5 minutes for when the pasta is done", nil)
        expect("remind me to call mom at 5", nil)

        // Repairs
        let timer = LocalRouter.repair("schedule_alert", ["title": "t", "seconds": 600, "at": "2026-11-17T15:22:00-06:00"])
        precondition(timer["at"] as? String == "")
        let alarm = LocalRouter.repair("schedule_alert", ["title": "t", "seconds": 0, "at": "2026-11-18T07:00:00-06:00"])
        precondition(alarm["at"] as? String == "2026-11-18T07:00:00-06:00")
        precondition(LocalRouter.repair("mac_setting", ["setting": "dark_mode", "action": "on", "level": 1])["level"] as? Int == -1)
        precondition(LocalRouter.repair("mac_setting", ["setting": "volume", "action": "set", "level": 40])["level"] as? Int == 40)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "America/Chicago")!
        let nov17 = ISO8601DateFormatter().date(from: "2026-11-17T21:00:00Z")!
        let tomorrow = LocalRouter.repair("read_calendar", ["start_date": "2026-11-17", "day_offset": 1, "days": 1], now: nov17, calendar: utc)
        precondition(tomorrow["start_date"] as? String == "" && tomorrow["day_offset"] as? Int == 1)
        let dated = LocalRouter.repair("read_calendar", ["start_date": "2026-11-18", "day_offset": 1, "days": 1], now: nov17, calendar: utc)
        precondition(dated["start_date"] as? String == "2026-11-18" && dated["day_offset"] as? Int == 0)
        precondition(LocalRouter.repair("search_web", ["query": "x", "site": "web", "browser": "Safari"], said: "search google for x")["browser"] as? String == "")
        precondition(LocalRouter.repair("search_web", ["query": "x", "site": "web", "browser": "Chrome"], said: "search x in chrome")["browser"] as? String == "Chrome")
        precondition(LocalRouter.repair("create_reminder", ["title": "milk", "due_at": "", "list_name": "Personal"], said: "add milk")["list_name"] as? String == "")
        precondition(LocalRouter.spoken(5400) == "1 hour and 30 minutes")

        // Turn-taking
        precondition(LocalRouter.endpointDelay("dark mode") == 0.35)
        precondition(LocalRouter.endpointDelay("set a timer for 5 minutes") == 0.35)
        precondition(LocalRouter.endpointDelay("open spotify and") == 1.2)
        precondition(LocalRouter.endpointDelay("play") == 1.2)
        precondition(LocalRouter.endpointDelay("what is this") == 0.6)
        precondition(LocalRouter.endpointDelay("google best tacos near me") == 0.35)
        precondition(LocalRouter.endpointDelay("tell me") == 1.2)
        // Pointing at the screen
        precondition(LocalRouter.intent("circle this")?.args["marks"] as? String == "circle it")
        precondition(LocalRouter.intent("underline that")?.args["marks"] as? String == "underline it")
        precondition(LocalRouter.intent("circle the send button")?.args["marks"] as? String == "circle send button")
        precondition(LocalRouter.intent("underline the deadline")?.args["marks"] as? String == "underline deadline")
        precondition(LocalRouter.intent("point at settings")?.args["marks"] as? String == "arrow settings")
        precondition(LocalRouter.intent("where's the share button")?.args["marks"] as? String == "arrow share button")
        precondition(LocalRouter.intent("show me the weather")?.tool != "mark_screen")
        precondition(LocalRouter.intent("where is my phone")?.tool != "mark_screen")
        // Pointing phrasings from the iMovie test (Nov 22)
        precondition(LocalRouter.intent("hey homie where is the scissors and split tool")?.args["marks"] as? String == "arrow scissors and split tool")
        precondition(LocalRouter.intent("can you point out the timeline zoom slider")?.args["marks"] as? String == "arrow timeline zoom slider")
        precondition(LocalRouter.intent("hey where are titles")?.args["marks"] as? String == "arrow titles")
        precondition(LocalRouter.intent("hey where are titles")?.args["vision"] as? Bool == false)
        precondition(LocalRouter.intent("where is the crop")?.args["marks"] as? String == "arrow crop")
        precondition(LocalRouter.intent("hey homie can you point at the play button please")?.args["marks"] as? String == "arrow play button")
        precondition(LocalRouter.intent("circle the volume slider")?.args["marks"] as? String == "circle volume slider")
        precondition(LocalRouter.intent("show me where the crop tool is")?.args["marks"] as? String == "arrow crop tool")
        precondition(LocalRouter.intent("where do i find the export button")?.args["marks"] as? String == "arrow export button")
        precondition(LocalRouter.intent("show me the record button")?.args["marks"] as? String == "arrow record button")
        precondition(LocalRouter.intent("where is the nearest gas station")?.tool != "mark_screen")
        precondition(LocalRouter.intent("where's the eiffel tower")?.args["vision"] as? Bool == false)
        precondition(LocalRouter.intent("show me the solar system")?.tool != "mark_screen")
        // 3D canvas
        precondition(LocalRouter.intent("show me a DNA helix")?.args["subject"] as? String == "dna helix")
        precondition(LocalRouter.intent("show me a 3D cube")?.args["kind"] as? String == "shape")
        precondition(LocalRouter.intent("show me a water molecule")?.args["subject"] as? String == "water")
        precondition(LocalRouter.intent("what does a methane molecule look like")?.args["subject"] as? String == "methane")
        precondition(LocalRouter.intent("show me the solar system")?.args["kind"] as? String == "planets")
        precondition(LocalRouter.intent("show me saturn")?.args["subject"] as? String == "saturn")
        precondition(LocalRouter.intent("show me an atom")?.args["subject"] as? String == "atom")
        precondition(LocalRouter.intent("draw saturn in 3d")?.args["subject"] as? String == "saturn")
        precondition(LocalRouter.intent("close the canvas")?.args["kind"] as? String == "close")
        precondition(LocalRouter.intent("show me the water bill")?.tool != "show_3d")
        precondition(LocalRouter.intent("show me a picture of a cube")?.tool != "show_3d")
        precondition(LocalRouter.intent("draw a box around this")?.tool != "show_3d")
        precondition(LocalRouter.endpointDelay("what's that") == 0.6)
        precondition(LocalRouter.endpointDelay("what is") == 1.2)
        precondition(LocalRouter.endpointDelay("can you look at this") == 1.2)
        precondition(LocalRouter.endpointDelay("what's on my calendar tomorrow") == 0.35)
        precondition(LocalRouter.endpointDelay("what's on my calendar") == 0.6)
        precondition(LocalRouter.endpointDelay("remind me to call") == 0.6)

        // Optional params and finishing lines
        let calendar = LocalRouter.repair("read_calendar", ["day_offset": 1])
        precondition(calendar["start_date"] as? String == "" && calendar["days"] as? Int == 1)
        precondition(LocalRouter.repair("search_web", ["query": "x"], said: "search x")["site"] as? String == "web")
        precondition(LocalTools.doneLine(tool: "create_reminder", result: ["status": "created"], said: "remind me to call mom at 5") != nil)
        precondition(LocalTools.doneLine(tool: "create_reminder", result: ["status": "error"], said: "remind me to call mom") == nil)
        precondition(LocalTools.doneLine(tool: "open_website", result: ["status": "opened"], said: "open nytimes and read me the headline") == nil)
        precondition(LocalTools.doneLine(tool: "read_calendar", result: ["status": "read"], said: "what's on my calendar") == nil)
        let local = LocalTools.localize([["name": "search_web", "description": "x", "strict": true,
                                          "parameters": ["type": "object", "properties": ["query": [:], "site": [:], "browser": [:]], "required": ["browser", "query", "site"]]]])
        precondition(((local[0]["parameters"] as? [String: Any])?["required"] as? [String]) == ["query"])

        // Grounding: an action needs a matching word in what was said
        precondition(!LocalTools.grounded("play_apple_music", said: "tell me a joke"))
        precondition(!LocalTools.grounded("play_apple_music", said: "send hi to abby on discord"))
        precondition(LocalTools.grounded("play_apple_music", said: "I want to hear Drake"))
        precondition(LocalTools.grounded("type_in_app", said: "send hi to abby on discord"))
        precondition(LocalTools.grounded("read_calendar", said: "anything"))
        precondition(!LocalTools.grounded("empty_trash", said: "clean up my desktop"))
        precondition(LocalTools.redirect("cancel_alert", ["id": "timer_id"]).0 == "list_alerts")
        precondition(LocalTools.redirect("cancel_alert", ["id": "pixie.alert.ABC"]).0 == "cancel_alert")
        precondition(LocalTools.leaked("<tool_call> <function=play_apple_music>") && LocalTools.leaked("[Nov 17 · frontmost app: Safari]") && !LocalTools.leaked("Paris!"))

        precondition(LocalTools.visible("Here's a fun one! <tool_call>\n<function=search_web>\n<parameter=site>\nweb") == "Here's a fun one!")
        precondition(LocalTools.visible("Paris!") == "Paris!")
        precondition(LocalTools.visible("<tool_call><function=x>") == "")

        // Reply only on clear success
        let open = LocalRouter.intent("open notes")!
        precondition(LocalRouter.reply(open, result: ["status": "opened"]) != nil)
        precondition(LocalRouter.reply(open, result: ["status": "error", "message": "x"]) == nil)
        precondition(LocalRouter.reply(open, result: ["status": "app_learned"]) == nil)
        let dark = LocalRouter.intent("dark mode")!
        precondition(LocalRouter.reply(dark, result: ["status": "completed", "already": true]) == "You're already in dark mode.")
        precondition(LocalRouter.reply(dark, result: ["status": "completed"]) == "Dark mode, on.")

        // Read-outs
        let chicago = utc
        let at3 = ISO8601DateFormatter().date(from: "2026-11-17T21:00:00Z")!   // 3 PM Chicago
        let events: [[String: Any]] = [
            ["title": "Standup", "start": "2026-11-17T09:00:00-06:00", "end": "2026-11-17T09:15:00-06:00", "all_day": false],
            ["title": "Lunch with Abby", "start": "2026-11-17T12:00:00-06:00", "end": "2026-11-17T13:00:00-06:00", "all_day": false],
            ["title": "Gym", "start": "2026-11-17T18:30:00-06:00", "end": "2026-11-17T19:30:00-06:00", "all_day": false]]
        print(LocalRouter.calendarLine(["events": events, "total": 3], offset: 1, now: at3, calendar: chicago)!)
        precondition(LocalRouter.calendarLine(["events": events, "total": 3], offset: 1, now: at3, calendar: chicago) == "You've got 3 things tomorrow: Standup at 9 AM, Lunch with Abby at noon, and Gym at 6:30 PM.")
        precondition(LocalRouter.calendarLine(["events": events, "total": 3], offset: 0, now: at3, calendar: chicago) == "You've got one thing left today: Gym at 6:30 PM.")
        precondition(LocalRouter.calendarLine(["events": [], "total": 0], offset: 1, now: at3, calendar: chicago) == "Your calendar's clear tomorrow.")
        precondition(LocalRouter.calendarLine(["events": Array(events.prefix(2)), "total": 2], offset: 0, now: at3, calendar: chicago) == "You're done for today, nothing else on the calendar.")
        precondition(LocalRouter.remindersLine(["total": 2, "tasks": [["title": "Buy milk"], ["title": "Call mom"]]]) == "You've got 2 things: Buy milk and Call mom.")
        precondition(LocalRouter.remindersLine(["total": 0, "tasks": []]) == "Your to-do list is empty. Nice.")
        let soon = ISO8601DateFormatter().string(from: at3.addingTimeInterval(250))
        precondition(LocalRouter.alertsLine(["alerts": [["title": "Timer", "due_at": soon]]], now: at3) == "Your timer has 4 minutes left.")
        precondition(LocalRouter.alertsLine(["alerts": []], now: at3) == "No timers running.")
        let readout = LocalRouter.intent("what's on my calendar tomorrow")!
        precondition(LocalRouter.reply(readout, result: ["status": "read", "events": events, "total": 3], now: at3, calendar: chicago)?.hasPrefix("You've got 3 things") == true)

        print(failures == 0 ? "LocalRouter: all passed" : "LocalRouter: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
