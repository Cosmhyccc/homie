import Foundation

/// Website navigation is separate from typing/submitting arbitrary app inputs.
enum WebDestination {
    static func url(_ input: String) throws -> URL {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 4096,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.whitespaces.contains($0) }) else {
            throw MusicFailure.message("Use a website address without spaces or control characters.")
        }
        let value = text.contains("://") ? text : "https://" + text
        guard let components = URLComponents(string: value),
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let url = components.url else {
            throw MusicFailure.message("Only http or https website addresses are supported.")
        }
        return url
    }

    static func search(query: String, site: String) throws -> URL {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 1000 else { throw MusicFailure.message("Give me a short search query.") }
        guard ["web", "youtube"].contains(site) else { throw MusicFailure.message("Search supports web or youtube.") }
        var parts = URLComponents(string: site == "youtube" ? "https://www.youtube.com/results" : "https://www.google.com/search")!
        parts.queryItems = [URLQueryItem(name: site == "youtube" ? "search_query" : "q", value: query)]
        return parts.url!
    }
}
