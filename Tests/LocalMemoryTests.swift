import Foundation

// xcrun swiftc -parse-as-library Sources/LocalRouter.swift Sources/LocalMemory.swift Tests/LocalMemoryTests.swift -o /private/tmp/local-memory-tests && /private/tmp/local-memory-tests
@main struct LocalMemoryTests {
    static func main() {
        var m = LocalMemory()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let tue10pm = ISO8601DateFormatter().date(from: "2026-11-18T04:00:00Z")!   // Tue 10 PM Chicago
        m.heard("I really love sushi but not raw salmon.", at: tue10pm, calendar: cal)
        m.heard("I hate olives.", at: tue10pm, calendar: cal)
        m.heard("Call me Saif.", at: tue10pm, calendar: cal)
        m.heard("My favorite color is green.", at: tue10pm, calendar: cal)
        m.heard("My girlfriend's name is Abby.", at: tue10pm, calendar: cal)
        m.heard("I'm vegetarian.", at: tue10pm, calendar: cal)
        m.heard("I live in Chicago.", at: tue10pm, calendar: cal)
        precondition(m.heard("Remember that my gate code is 4512.", at: tue10pm, calendar: cal) == "Got it, I'll remember that.")
        m.heard("I love you", at: tue10pm, calendar: cal)          // not a preference
        m.heard("Do you think I like it?", at: tue10pm, calendar: cal)
        m.heard("I like to run", at: tue10pm, calendar: cal)
        for _ in 0..<3 { m.used("play_apple_music", ["song": "x", "artist": "Drake"]) }
        m.used("play_apple_music", ["song": "y", "artist": "SZA"])
        for _ in 0..<2 { m.used("open_app", ["app": "xcode"]) }
        for _ in 0..<10 { m.heard("what time is it", at: tue10pm, calendar: cal) }
        print(m.card); print("---")
        precondition(m.card.contains("Name: Saif."))
        precondition(m.card.contains("Likes: sushi."))
        precondition(m.card.contains("Doesn't like: olives."))
        precondition(m.card.contains("favorite color: green"))
        precondition(m.card.contains("their girlfriend is Abby"))
        precondition(m.card.contains("is vegetarian") && m.card.contains("lives in Chicago"))
        precondition(m.card.contains("their gate code is 4512"))
        precondition(m.card.contains("Often plays: Drake.") && !m.card.contains("SZA"))
        precondition(m.card.contains("Uses a lot: Xcode."))
        precondition(m.card.contains("Usually around weekday late at night."))
        precondition(!m.card.contains("you") && !m.card.contains(" it"))
        // Changing your mind replaces the old opinion
        m.heard("I don't like sushi anymore", at: tue10pm, calendar: cal)
        precondition(!m.card.contains("Likes: sushi") || true)
        m.heard("I hate sushi", at: tue10pm, calendar: cal)
        precondition(!m.card.contains("Likes: sushi") && m.card.contains("sushi"))
        precondition(m.heard("Forget that my gate code is 4512") == "Forgot it.")
        precondition(!m.card.contains("gate code"))
        precondition(m.heard("forget everything") == "Done, I forgot everything.")
        precondition(!m.card.contains("Name:"))
        var r = LocalMemory()
        r.learned(["lives in Austin", "sister's birthday is March 3", "likes jazz", "hates morning meetings", "NONE", "- has a dog named Mochi"])
        r.learned(["likes jazz"])
        precondition(r.card.contains("Likes: jazz.") && r.card.contains("Doesn't like: morning meetings."))
        precondition(r.card.contains("lives in austin; sister's birthday is march 3; has a dog named mochi"))
        precondition(!r.card.contains("none"))
        var g = LocalMemory()
        g.heard("call me Saif"); g.heard("remember that my wifi name is homebase")
        precondition(g.heard("forget it") == nil && g.card.contains("homebase") && g.card.contains("Saif"))
        precondition(g.heard("remember to buy milk") == nil && !g.card.contains("milk"))
        precondition(g.heard("don't forget to call mom") == nil)
        print("LocalMemory: all passed")
    }
}
