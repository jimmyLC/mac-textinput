import Foundation

/// In-memory evidence index. Word data is injected by the caller; no third-party
/// dictionary is bundled by this prototype.
struct EnglishLexicon {
    private let words: Set<String>
    private let prefixes: Set<String>
    private let ordered: [String]   // input order (callers pass most frequent first)
    private let rank: [String: Int]
    private let shown: [String: String]   // lowercase -> user's spelling (e.g. "myjav" -> "MyJAV")

    /// `user` words are ranked ahead of everything else and keep their own capitalisation.
    init<S: Sequence>(words source: S, user: [String] = []) where S.Element == String {
        var shown = [String: String]()
        for w in user { shown[w.lowercased()] = w }
        self.shown = shown
        var words = Set<String>()
        var prefixes = Set<String>()
        var ordered: [String] = []
        for candidate in Array(user) + Array(source) {
            let word = candidate.lowercased()
            guard !word.isEmpty, word.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else { continue }
            if words.insert(word).inserted { ordered.append(word) }
            var prefix = ""
            for character in word {
                prefix.append(character)
                prefixes.insert(prefix)
            }
        }
        self.words = words
        self.prefixes = prefixes
        self.ordered = ordered
        var rank = [String: Int](minimumCapacity: ordered.count)
        for (i, w) in ordered.enumerated() { rank[w] = i }
        self.rank = rank
    }

    /// Most frequent known word one edit away (swap, drop, extra or wrong letter) from a
    /// misspelling, among the `top` most frequent words. Nil when `word` is itself a word.
    func correction(for word: String, top: Int = 30_000) -> String? {
        let w = word.lowercased()
        guard w.count >= 4, !words.contains(w), w.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else { return nil }
        let chars = Array(w)
        var candidates = Set<String>()
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        for i in 0...chars.count {
            if i < chars.count { candidates.insert(String(chars[..<i] + chars[(i + 1)...])) }                 // dropped letter
            if i + 1 < chars.count { var c = chars; c.swapAt(i, i + 1); candidates.insert(String(c)) }        // swapped pair
            for l in letters {
                candidates.insert(String(chars[..<i]) + String(l) + String(chars[i...]))                       // missing letter
                if i < chars.count { var c = chars; c[i] = l; candidates.insert(String(c)) }                    // wrong letter
            }
        }
        return candidates.compactMap { c in rank[c].flatMap { $0 < top ? (c, $0) : nil } }
            .min { $0.1 < $1.1 }?.0
    }

    /// Spelling to show for a word (user dictionary capitalisation when present).
    func display(_ word: String) -> String { shown[word.lowercased()] ?? word }

    func contains(_ value: String) -> Bool { words.contains(value.lowercased()) }
    func containsPrefix(_ value: String) -> Bool { !value.isEmpty && prefixes.contains(value.lowercased()) }

    /// True for words among the `top` most frequent ones (the list is ordered by frequency).
    func isCommon(_ value: String, top: Int) -> Bool {
        guard let r = rank[value.lowercased()] else { return false }
        return r < top
    }

    /// Most frequent word strictly longer than `prefix` that starts with it; the word
    /// itself only when nothing longer exists.
    func completion(for prefix: String, top: Int = Int.max) -> String? {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return nil }
        let pool = ordered.prefix(top)
        return pool.first { $0.count > p.count && $0.hasPrefix(p) } ?? (isCommon(p, top: top) ? p : nil)
    }
}
