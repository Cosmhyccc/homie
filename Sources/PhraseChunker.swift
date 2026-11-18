import Foundation

/// Splits a growing streamed reply into speakable phrases. First phrase breaks early so Pixie starts talking fast.
struct PhraseChunker {
    private var consumed = 0
    private var emitted = 0
    mutating func feed(_ full: String, final: Bool = false) -> [String] {
        let chars = Array(full)
        guard consumed <= chars.count else { return [] }
        var out: [String] = []
        var start = consumed
        var i = consumed
        while i < chars.count {
            let c = chars[i]
            let followedBySpace = i + 1 < chars.count && (chars[i + 1] == " " || chars[i + 1] == "\n")
            let sentence = (".!?".contains(c) && followedBySpace) || c == "\n"
            let clause = ",;:—".contains(c) && followedBySpace && (i - start + 1) >= (emitted == 0 ? 18 : 70)
            // First phrase only: don't wait for punctuation. Break before a joining word once a few words are in,
            // "Did you know | that there's a black hole…" — homie starts talking ~0.5 s sooner on long answers.
            if emitted == 0, !sentence, !clause, c == " ", i - start >= 12, let word = Self.word(after: i, in: chars), Self.joiners.contains(word) {
                let phrase = Self.clean(String(chars[start..<i]))
                if !phrase.isEmpty { out.append(phrase); emitted += 1; start = i + 1 }
                i += 1; continue
            }
            if sentence || clause {
                let phrase = Self.clean(String(chars[start...i]))
                if !phrase.isEmpty { out.append(phrase); emitted += 1 }
                start = i + 1
            }
            i += 1
        }
        if final, start < chars.count { let rest = Self.clean(String(chars[start...])); if !rest.isEmpty { out.append(rest) }; start = chars.count }
        consumed = start
        return out
    }
    static let joiners: Set<String> = ["that", "where", "which", "because", "and", "but", "so", "when", "while", "who", "since", "if", "though", "although", "until"]
    /// The complete lowercase word starting after `index`, or nil while it's still being written.
    static func word(after index: Int, in chars: [Character]) -> String? {
        var j = index + 1, word = ""
        while j < chars.count, chars[j] != " ", chars[j] != "\n" { word.append(chars[j]); j += 1 }
        guard j < chars.count, !word.isEmpty else { return nil }
        return word.lowercased()
    }
    static func clean(_ text: String) -> String {
        String(text.replacingOccurrences(of: "[*#`_>]", with: "", options: .regularExpression)
            .unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) })   // never read emoji aloud
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
