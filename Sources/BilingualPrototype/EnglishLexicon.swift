import Foundation

/// In-memory evidence index. Word data is injected by the caller; no third-party
/// dictionary is bundled by this prototype.
struct EnglishLexicon {
    private let words: Set<String>
    private let prefixes: Set<String>
    private let ordered: [String]   // input order (callers pass most frequent first)
    private let rank: [String: Int]

    init<S: Sequence>(words source: S) where S.Element == String {
        var words = Set<String>()
        var prefixes = Set<String>()
        var ordered: [String] = []
        for candidate in source {
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
