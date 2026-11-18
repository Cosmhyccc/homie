import Foundation

struct CatalogSong: Codable {
    let trackId: Int
    let trackName: String
    let artistName: String
    let collectionName: String?
    let trackViewUrl: String
    let artworkUrl100: String?
}

enum MusicFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum SongCatalog {
    /// Songs already matched on this Mac, so a replay skips Apple's lookup (~0.7 s). Local file only, never uploaded.
    private static let cacheURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pixie/Local/songs.json")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var memory: [String: CatalogSong]?
    private static func cacheKey(_ title: String, _ artist: String) -> String { SongMatch.key(title) + "|" + SongMatch.key(artist) }
    static func cached(_ title: String, _ artist: String) -> CatalogSong? {
        lock.lock(); defer { lock.unlock() }
        if memory == nil { memory = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode([String: CatalogSong].self, from: $0) } ?? [:] }
        return memory?[cacheKey(title, artist)]
    }
    private static func remember(_ song: CatalogSong, _ title: String, _ artist: String) {
        lock.lock(); defer { lock.unlock() }
        var all = memory ?? [:]
        if all.count >= 400 { all.removeAll() }   // simple bound; songs re-learn on next play
        all[cacheKey(title, artist)] = song
        memory = all
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: cacheURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
        }
    }
    static func findSong(title: String, artist: String) async throws -> CatalogSong {
        if let hit = cached(title, artist) { return hit }
        let song = try await lookup(title: title, artist: artist)
        remember(song, title, artist)
        return song
    }
    private static func lookup(title: String, artist: String) async throws -> CatalogSong {
        func search(_ term:String) async throws -> [CatalogSong] {
            var url=URLComponents(string:"https://itunes.apple.com/search")!
            url.queryItems=[URLQueryItem(name:"term",value:term),URLQueryItem(name:"entity",value:"song"),URLQueryItem(name:"country",value:"us"),URLQueryItem(name:"limit",value:"100")]
            var request=URLRequest(url:url.url!);request.timeoutInterval=8
            let (data,response)=try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw MusicFailure.message("Apple’s catalog search is unavailable. Try again shortly.")}
            struct Results:Decodable {let results:[CatalogSong]}
            return try JSONDecoder().decode(Results.self,from:data).results
        }
        var songs=try await search(title+" "+artist)
        if artist.isEmpty, let i=SongMatch.popular(title,candidates:songs.map {($0.trackName,$0.artistName)}) {return songs[i]}
        if let i=SongMatch.best(title:title,artist:artist,candidates:songs.map {($0.trackName,$0.artistName)}) {return songs[i]}
        // Relax retrieval, not acceptance: a misspelled word must not hide the
        // correct catalog candidate. Ranking still checks the full title/artist.
        let words=title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).split(separator:" ").map(String.init)
        // Search independent anchors so a misspelled longest word cannot hide
        // the candidate. Bound requests and collect all before ranking ambiguity.
        let anchors=Array(Set(words.filter {$0.count >= 3})).sorted { $0.count > $1.count }.prefix(3)
        if words.count > 1 {
            let recovered = try await withThrowingTaskGroup(of: [CatalogSong].self) { group in
                for anchor in anchors {
                    group.addTask { try await search(artist.isEmpty ? anchor : artist+" "+anchor) }
                }
                var matches: [CatalogSong] = []
                for try await result in group { matches += result }
                return matches
            }
            songs += recovered
            if let i=SongMatch.best(title:title,artist:artist,candidates:songs.map {($0.trackName,$0.artistName)}) {return songs[i]}
        }
        throw MusicFailure.message("I couldn’t confidently match that title in Apple Music. Please confirm the title and artist.")
    }

}
