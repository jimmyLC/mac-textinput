import Foundation

/// In-memory evidence index. Word data is injected by the caller; no third-party
/// dictionary is bundled by this prototype.
struct EnglishLexicon {
    private let words: Set<String>
    private let prefixes: Set<String>

    init<S: Sequence>(words source: S) where S.Element == String {
        var words = Set<String>()
        var prefixes = Set<String>()
        for candidate in source {
            let word = candidate.lowercased()
            guard !word.isEmpty, word.unicodeScalars.allSatisfy({ (97...122).contains($0.value) }) else { continue }
            words.insert(word)
            var prefix = ""
            for character in word {
                prefix.append(character)
                prefixes.insert(prefix)
            }
        }
        self.words = words
        self.prefixes = prefixes
    }

    func contains(_ value: String) -> Bool { words.contains(value.lowercased()) }
    func containsPrefix(_ value: String) -> Bool { !value.isEmpty && prefixes.contains(value.lowercased()) }
}
