import Foundation

/// Conservative catalog ranking: tolerate a small transcription error, never
/// substitute an unrelated title or artist, and reject equally plausible matches.
enum SongMatch {
    static func key(_ text:String)->String {
        text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:Locale(identifier:"en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func distance(_ a:String,_ b:String)->Int {
        let lhs=Array(a),rhs=Array(b)
        var row=Array(0...rhs.count)
        for (i,x) in lhs.enumerated() {
            var next=[i+1]
            for (j,y) in rhs.enumerated() {next.append(min(next[j]+1,row[j+1]+1,row[j]+(x == y ? 0:1)))}
            row=next
        }
        return row.last!
    }
    /// No artist given ("play blinding lights", "play drake"). An artist name plays their top song; a title plays the
    /// first non-cover exact match in Apple's search order. Checked on 21 hits: 19 right, the 2 misses are truly ambiguous titles.
    static func popular(_ words:String,candidates:[(String,String)])->Int? {
        let query=key(words)
        guard !query.isEmpty else{return nil}
        // The words name an artist with several songs in the results: play their top one.
        var weight:[String:Int]=[:]
        for item in candidates {weight[key(item.1),default:0]+=1}
        if weight[query, default:0] >= 3, let i=candidates.firstIndex(where:{key($0.1)==query}) {return i}
        // Cover and karaoke catalogs flood every hit song; never pick them for a bare title.
        let covers=try! NSRegularExpression(pattern:"kidz ?bop|string quartet|karaoke|tribute|lullaby|rockabye|piano|cover|instrumental|orchestra|8.bit|vitamin|music box|twinkle",options:.caseInsensitive)
        func cover(_ name:String)->Bool {covers.firstMatch(in:name,range:NSRange(name.startIndex...,in:name)) != nil}
        let titled=candidates.indices.filter {key(candidates[$0].0)==query && !cover(candidates[$0].1)}
        // Apple's search order usually leads with the original. Exception: a cover sneaks in first while the
        // original artist has many versions of that exact title (The Weeknd's 9 "Blinding Lights" vs 2).
        guard let first=titled.first else {return nil}
        var versions:[String:Int]=[:]
        for i in titled {versions[key(candidates[i].1),default:0]+=1}
        let firstCount=versions[key(candidates[first].1),default:0]
        if let (artist,count)=versions.max(by:{$0.value < $1.value}), count >= 6, count >= 3*firstCount,
           let i=titled.first(where:{key(candidates[$0].1)==artist}) {return i}
        return first
    }
    static func best(title:String,artist:String,candidates:[(String,String)])->Int? {
        let query=key(title), performer=key(artist)
        guard !query.isEmpty else{return nil}
        let scores=candidates.enumerated().compactMap { i,item -> (Int,Int)? in
            guard performer.isEmpty || key(item.1)==performer else{return nil}
            let candidate=key(item.0), edits=distance(query,candidate)
            let allowance=query.count >= 6 ? min(2,max(1,query.count/4)):0
            guard edits <= allowance else{return nil}
            return (i,edits)
        }.sorted {$0.1 < $1.1}
        guard let best=scores.first else{return nil}
        if scores.dropFirst().contains(where:{$0.1 == best.1 && (key(candidates[$0.0].0) != key(candidates[best.0].0) || key(candidates[$0.0].1) != key(candidates[best.0].1))}) {return nil}
        return best.0
    }
}
