import Foundation
// xcrun swiftc -parse-as-library Sources/PhraseChunker.swift Tests/PhraseChunkerTests.swift -o /private/tmp/chunker-tests && /private/tmp/chunker-tests
@main struct PhraseChunkerTests { static func main() {
    func run(_ text: String) -> [String] {
        var c = PhraseChunker(); var out: [String] = []; var so = ""
        for ch in text { so.append(ch); out += c.feed(so) }   // stream one character at a time, like the model
        return out + c.feed(so, final: true)
    }
    let space = run("Did you know that there's a black hole in the center of our galaxy? It weighs four million suns.")
    print(space); precondition(space.first == "Did you know")
    let hole = run("A black hole is a region in space where gravity is so strong that nothing, not even light, escapes.")
    print(hole); precondition(hole.first == "A black hole is a region in space")
    let short = run("Hey, I'm sorry to hear that. Want some music?")
    print(short); precondition(short.first == "Hey, I'm sorry to hear that.")
    precondition(run("On it.") == ["On it."])
    // Joined back together, nothing is lost or reordered.
    precondition(hole.joined(separator: " ") == "A black hole is a region in space where gravity is so strong that nothing, not even light, escapes.")
    print("PhraseChunker: all passed")
}}
