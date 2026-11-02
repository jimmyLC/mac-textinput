import Foundation

/// In-memory evidence index. Word data is injected by the caller; no third-party
/// dictionary is bundled by this prototype.
struct EnglishLexicon {
    private let words: Set<String>
    private let prefixes: Set<String>
    private let ordered: [String]   // input order (callers pass most frequent first)

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
    }

    func contains(_ value: String) -> Bool { words.contains(value.lowercased()) }
    func containsPrefix(_ value: String) -> Bool { !value.isEmpty && prefixes.contains(value.lowercased()) }

    /// Most frequent word strictly longer than `prefix` that starts with it; the word
    /// itself only when nothing longer exists.
    func completion(for prefix: String) -> String? {
        let p = prefix.lowercased()
        guard !p.isEmpty else { return nil }
        return ordered.first { $0.count > p.count && $0.hasPrefix(p) } ?? (words.contains(p) ? p : nil)
    }
}
