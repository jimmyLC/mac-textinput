import Foundation

enum SegmentKind: Equatable { case chinese, english, undecided }

/// A slice of the raw keys with its provisional reading. Concatenating every
/// segment's `keys` always reproduces the input exactly.
struct BilingualSegment: Equatable {
    let keys: String
    let kind: SegmentKind
}

struct BilingualAnalyzer {
    let lexicon: EnglishLexicon
    let zhuyin: ZhuyinSyllableIndex

    /// Split `raw` at spaces and lower→UPPER case changes, then classify each piece.
    /// A trailing space on a piece counts as a boundary (and as tone 1 for Zhuyin).
    func analyze(_ raw: String) -> [BilingualSegment] {
        let all = pieces(of: raw)
        return all.enumerated().map { BilingualSegment(keys: $1, kind: classify($1, isLast: $0 == all.count - 1)) }
    }

    func pieces(of raw: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previous: Character?
        for ch in raw {
            if let p = previous, p.isLowercase || p.isNumber, ch.isUppercase, !current.isEmpty {
                result.append(current); current = ""
            }
            current.append(ch)
            if ch == " " { result.append(current); current = "" }
            previous = ch
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// A piece is bounded when followed by a space or by another piece.
    func classify(_ piece: String, isLast: Bool = true) -> SegmentKind {
        let trailingSpace = piece.hasSuffix(" ")
        let body = trailingSpace ? String(piece.dropLast()) : piece
        guard !body.isEmpty else { return .undecided }
        if Self.looksLikeURLOrEmail(body) { return .english }
        // Capitals and non-Zhuyin keys cannot be Zhuyin.
        let zh = zhuyin.parse(body)  // a trailing space is tone 1, already implied
        let letters = body.allSatisfy { $0.isASCII && $0.isLetter }
        let decision = BilingualResolver.decide(BilingualEvidence(
            rawKeys: body,
            englishIsWord: letters && lexicon.contains(body),
            englishIsPrefix: letters && lexicon.containsPrefix(body),
            validZhuyin: zh == .complete,
            boundary: trailingSpace || !isLast))
        switch decision {
        case .chinese: return .chinese
        case .english: return .english
        case .undecided:
            // Boundary-less pieces that cannot be Zhuyin or an English prefix are
            // still ambiguous input to the caller, but a capitalised word is English.
            if letters, body.first!.isUppercase, !(zh == .complete) { return .english }
            return .undecided
        }
    }

    static func looksLikeURLOrEmail(_ s: String) -> Bool {
        s.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://\S+$"#, options: .regularExpression) != nil
            || s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}
