import Foundation

/// Chooses a provisional interpretation of the same raw keys. The caller owns
/// the buffer and must never discard it based on this advisory result.
enum BilingualDecision: Equatable {
    case chinese
    case english
    case undecided
}

struct BilingualEvidence {
    let rawKeys: String
    let englishIsWord: Bool
    let englishIsPrefix: Bool
    let validZhuyin: Bool
    let boundary: Bool
}

enum BilingualResolver {
    static func decide(_ input: BilingualEvidence) -> BilingualDecision {
        guard !input.rawKeys.isEmpty else { return .undecided }
        if !input.boundary { return .undecided }
        if input.englishIsWord && !input.validZhuyin { return .english }
        if input.validZhuyin && !input.englishIsWord && !input.englishIsPrefix { return .chinese }
        // Competing interpretations, unknown words, and incomplete prefixes
        // require more evidence or an explicit choice.
        return .undecided
    }
}
