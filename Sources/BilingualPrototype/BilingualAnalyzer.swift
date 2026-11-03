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

extension BilingualAnalyzer {
    /// "su3cl3hello" -> ("su3cl3", "hello"): complete Zhuyin ending in an explicit tone
    /// key, followed by a lexicon word. Returns the split with the longest English tail.
    func splitTrailingEnglish(_ body: String) -> (head: String, tail: String)? {
        let chars = Array(body)
        for i in 1..<max(chars.count, 1) {
            guard "3467".contains(chars[i - 1]) else { continue }
            let tail = String(chars[i...])
            guard tail.count >= 2, tail.allSatisfy({ $0.isASCII && $0.isLowercase }),
                  lexicon.contains(tail) else { continue }
            let head = String(chars[..<i])
            if zhuyin.parse(head) == .complete { return (head, tail) }
        }
        return nil
    }
}

extension BilingualAnalyzer {
    /// English completion to offer while `body` is still being typed, or nil when the
    /// keys look like Chinese (a toneless Zhuyin parse that is not itself an English word).
    func completion(for body: String) -> String? {
        guard body.count >= 3, body.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return nil }
        if zhuyin.parse(body) == .complete && !lexicon.contains(body) { return nil }
        return lexicon.completion(for: body)
    }
}

extension BilingualAnalyzer {
    /// Whether the composition should already be displayed as English while still typing:
    /// all lowercase letters and a word, or (3+ letters) a word prefix that is not Zhuyin.
    func showsAsEnglish(_ body: String) -> Bool {
        guard body.count >= 2, body.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        if lexicon.contains(body) { return true }
        return body.count >= 3 && lexicon.containsPrefix(body) && zhuyin.parse(body) != .complete
    }
}

extension BilingualAnalyzer {
    /// Whether the lowercase letters typed so far already form an English word, so the run
    /// switches to English. Two-letter words are ambiguous with common Zhuyin syllables
    /// ("up" is also ㄧㄣ, 因), so they need English context or must not be a Zhuyin syllable at all.
    func startsEnglish(_ tail: String, previousRunEnglish: Bool) -> Bool {
        // Common words only: the word list also holds rare tokens ("su") that must not trigger English.
        guard tail.count >= 2, tail.allSatisfy({ $0.isASCII && $0.isLowercase }),
              lexicon.isCommon(tail, top: tail.count == 2 ? 3_000 : 60_000) else { return false }
        if tail.count >= 3 { return true }
        return previousRunEnglish || (zhuyin.parse(tail) != .complete && !zhuyin.isSyllable(tail))
    }
}

extension BilingualAnalyzer {
    /// English offer shown next to Zhuyin that is still being typed (Tab accepts it).
    func offer(for tail: String) -> String? {
        guard !tail.isEmpty, tail.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return nil }
        return lexicon.completion(for: tail, top: 20_000)
    }
}
