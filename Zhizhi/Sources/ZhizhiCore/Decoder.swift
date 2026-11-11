import Foundation

/// One decoded piece of the composition.
public struct Segment: Equatable {
    public enum Kind: Int { case chinese = 0, english = 1, other = 2, pending = 3 }
    public var kind: Kind
    public var range: Range<Int>      // keys covered
    public var text: String
    public var syllableEnds: [Int] = []   // Chinese: the key index after each syllable

    public init(kind: Kind, range: Range<Int>, text: String, syllableEnds: [Int] = []) {
        self.kind = kind; self.range = range; self.text = text; self.syllableEnds = syllableEnds
    }
}

/// A key range fixed by the user: a picked candidate or a flipped language.
public struct Constraint: Equatable {
    public enum Fix: Equatable {
        case text(String, Segment.Kind)
        case language(Segment.Kind)
    }
    public var range: Range<Int>
    public var fix: Fix
    /// Fixed Chinese text: each syllable's end, relative to the range, so the cursor and backspace still work per character.
    public var syllableEnds: [Int] = []
    /// Set when the local AI chose this text instead of the user: what it replaced.
    public var correctedFrom: String?
    /// Chosen by the user from the candidate list, which is what learning listens to.
    public var picked = false
    public init(range: Range<Int>, fix: Fix) { self.range = range; self.fix = fix }
}

public enum LanguagePreference { case chineseFirst, habit, englishFirst }

/// Re-reads a whole key buffer as the cheapest mix of Chinese words, English words, numbers
/// and literals. Every key re-decodes, so a judgement can change until the text is committed.
public final class Decoder {
    /// Tunable costs. Costs are negative log probabilities (lower wins).
    public struct Costs {
        public var tonelessSyllable: Float = 4.0   // omitted tone inside a multi-syllable word
        public var wrongTone: Float = 4.0          // one wrong tone inside a multi-syllable word
        public var neutralForFirst: Float = 0.5    // neutral vs first tone: rarely a real mistake
        public var languageSwitch: Float = 2.0
        public var englishBase: Float = 7.0
        public var englishPerRank: Float = 0.9     // times ln(rank + 1)
        public var unknownCapitalised: Float = 9.0
        public var unknownLowercase: Float = 30.0
        public var unknownAfterEnglish: Float = 13.0
        public var pendingSyllable: Float = 6.0
        public var pendingAfterEnglish: Float = 6.0   // extra: letters right after English are probably English
        public var englishAfterSpace: Float = 3.0     // 1-3 letters after a space that closed a toned syllable: show them as English now
        public var tonelessMinScore: Float = -6.5     // omitted tones only form common words
        public var number: Float = 15.0
        public var token: Float = 6.0
        public var joinedToken: Float = 8.0
        public var perTokenKey: Float = 2.0           // long key runs must not become one token
        public var strayLetter: Float = 12.0          // a mistyped letter next to real text
        public var literalPunctuation: Float = 14.0
        public var space: Float = 0.5
        public var pairWeight: Float = 0.15           // how much a word pair counts against the word alone (0 = off)
        public var pairLimit: Float = 2.0             // the most a pair may lower a word's cost: it settles close calls only
        public var complementDe: Float = 2.5          // 跑得 then 很快: the complement reading of 得
        public var beam: Float = 18.0                 // readings this much worse than the best so far are dropped
        public var wordsPerSpan = 5                   // same-sound words kept per stretch of keys, for pairs to choose among
        public var listMarker: Float = 2.0            // "2." at the start of a line or after a space, as in a numbered list
        public init() {}
    }

    public var costs = Costs()
    public var preference = LanguagePreference.chineseFirst
    public var autoSpace = true
    public var punctuationWidth = Settings.PunctuationWidth.follow
    public var commonWordsThreeLetters = 20_000
    public var commonWordsLonger = 60_000
    public var commonWordsTwoLetters = 3_000

    private let lexicon: Lexicon

    public init(lexicon: Lexicon) { self.lexicon = lexicon }

    private struct Edge {
        var end: Int
        var kind: Segment.Kind
        var text: String
        var cost: Float
        var keepsLanguage = false   // spaces and punctuation do not change the language context
        var syllableEnds: [Int] = []
        var word: UInt32 = 0        // Chinese words: id for word-pair lookups; 0 for everything else
        var score: Float = 0        // Chinese words: the lexicon score (log10 probability) behind `cost`
    }

    /// One way to have read the keys up to a position: its cost, the language and the last Chinese word.
    private struct State {
        var cost: Float
        var context: Int
        var word: UInt32
        var previousPosition: Int32
        var previousState: Int32
        var edge: Int32
    }

    private struct Span { var end: Int; var base: UInt16; var tone: UInt8 }

    private static let symbols: [Character: (half: String, full: String)] = [
        "<": (",", "，"), ">": (".", "。"), "?": ("?", "？"), "!": ("!", "！"), ":": (":", "："),
        "\"": ("\"", "」"), "{": ("{", "『"), "}": ("}", "』"), "[": ("[", "「"), "]": ("]", "」"),
        "(": ("(", "（"), ")": (")", "）"), "~": ("~", "～"), "_": ("_", "_"), "+": ("+", "＋"),
        "=": ("=", "＝"), "|": ("|", "｜"), "\\": ("\\", "、"), "'": ("'", "’"), "`": ("`", "`"),
        "@": ("@", "@"), "#": ("#", "#"), "$": ("$", "$"), "%": ("%", "%"), "^": ("^", "……"), "&": ("&", "&"), "*": ("*", "*"),
    ]

    /// Two-letter words common enough to win without English context; neither is a syllable.
    private static let twoLetterWords: Set<String> = ["ok"]

    public func decode(_ text: String, constraints: [Constraint] = []) -> [Segment] {
        decode(keys: Array(text), constraints: constraints)
    }

    /// `leading` is the language of the text already in the app, for punctuation width and context.
    public func decode(keys: [Character], constraints: [Constraint] = [], leading: Segment.Kind = .other) -> [Segment] {
        let n = keys.count
        guard n > 0 else { return [] }
        let kinds = 3   // language context: chinese, english, none
        var fixedAt = [Constraint?](repeating: nil, count: n)
        for c in constraints { for i in c.range where i < n { fixedAt[i] = c } }
        var spans = (0..<n).map { syllableSpans(keys, from: $0) }
        // Digits right before a percent sign are a number ("大於10%"), never toneless Zhuyin ("大於辦%").
        var percentDigit = [Bool](repeating: false, count: n)
        var k = n - 1
        while k > 0 {
            if keys[k] == "%", keys[k - 1].isNumber {
                var j = k - 1
                while j >= 0, keys[j].isNumber { percentDigit[j] = true; j -= 1 }
                // "好" + tone 3 + "10%": the first digit of a run of three or more may still be the tone of the word before.
                if k - (j + 1) >= 3, "3467".contains(keys[j + 1]) { percentDigit[j + 1] = false }
                k = j
            } else { k -= 1 }
        }
        if percentDigit.contains(true) {
            for i in 0..<n { spans[i].removeAll { span in (i..<span.end).contains { percentDigit[$0] } } }
        }

        // Every way to reach each position, one per (language, last Chinese word): the last word lets
        // the next one be chosen by what usually follows it ("這" then "份", not "分").
        var states = [[State]](repeating: [], count: n + 1)
        states[0] = [State(cost: 0, context: leading == .pending ? Segment.Kind.chinese.rawValue : leading.rawValue,
                           word: 0, previousPosition: -1, previousState: -1, edge: -1)]
        var edgeStore: [Edge] = []
        edgeStore.reserveCapacity(n * 12)

        for i in 0..<n where !states[i].isEmpty {
            let floor = states[i].reduce(Float.infinity) { min($0, $1.cost) } + costs.beam
            var edgesFor = [[Int32]?](repeating: nil, count: kinds)
            for (index, state) in states[i].enumerated() where state.cost <= floor {
                let previous = Segment.Kind(rawValue: state.context)!
                if edgesFor[state.context] == nil {
                    var list: [Int32] = []
                    for edge in edges(from: i, keys: keys, spans: spans, context: previous, fixedAt: fixedAt) {
                        edgeStore.append(edge)
                        list.append(Int32(edgeStore.count - 1))
                    }
                    edgesFor[state.context] = list
                }
                for edgeIndex in edgesFor[state.context]! {
                    let edge = edgeStore[Int(edgeIndex)]
                    var cost = state.cost + edge.cost
                    if edge.word != 0, state.word != 0 {
                        var gain: Float = 0
                        if let pair = lexicon.pairScore(state.word, edge.word) { gain = pairGain(pair: pair, alone: edge.score) }
                        // What the user chose in this very spot counts for more than what the corpus saw.
                        if let own = lexicon.ownPairGain(state.word, edge.word) { gain = max(gain, own) }
                        // 跑得 + 很快: a verb with 得 followed by a degree word is the complement 得, not 的.
                        if lexicon.verbDe.contains(state.word), lexicon.degree.contains(edge.word) { gain = max(gain, costs.complementDe) }
                        cost -= gain
                    }
                    let language = edge.kind == .pending ? Segment.Kind.chinese : edge.kind
                    var next = previous
                    if !edge.keepsLanguage {
                        if previous != .other, previous != language { cost += costs.languageSwitch }
                        next = language
                    }
                    let candidate = State(cost: cost, context: next.rawValue, word: edge.word,
                                          previousPosition: Int32(i), previousState: Int32(index), edge: edgeIndex)
                    if let same = states[edge.end].firstIndex(where: { $0.context == candidate.context && $0.word == candidate.word }) {
                        if cost < states[edge.end][same].cost { states[edge.end][same] = candidate }
                    } else {
                        states[edge.end].append(candidate)
                    }
                }
            }
        }

        guard var at = states[n].indices.min(by: { states[n][$0].cost < states[n][$1].cost }) else {
            return [Segment(kind: .other, range: 0..<n, text: String(keys))]
        }
        var result: [Segment] = []
        var pos = n
        while pos > 0 {
            let state = states[pos][at]
            let e = edgeStore[Int(state.edge)]
            result.append(Segment(kind: e.kind, range: Int(state.previousPosition)..<pos, text: e.text, syllableEnds: e.syllableEnds))
            pos = Int(state.previousPosition)
            at = Int(state.previousState)
        }
        return Self.dropStrayLetters(result.reversed())
    }

    /// How much cheaper a word gets after the word before it: mixes the pair's probability with the word's own.
    private func pairGain(pair: Float, alone: Float) -> Float {
        let w = costs.pairWeight
        guard w > 0 else { return 0 }
        return min(costs.pairLimit, max(0, log10(1 + w / (1 - w) * pow(10, pair - alone))))
    }

    /// A single lowercase letter that nothing could read, standing between Chinese words ("沒c反應"),
    /// is a slip of the finger: it is left out of the text. Letters at the end are still being typed and stay,
    /// and a letter the user flipped to English (Shift) is English, not a stray.
    private static func dropStrayLetters(_ segments: [Segment]) -> [Segment] {
        var out = segments
        for i in out.indices where i > 0 && i < out.count - 1 {
            let s = out[i]
            guard s.kind == .other, s.range.count == 1, s.text.count == 1, let c = s.text.first,
                  c.isASCII, c.isLetter, c.isLowercase,
                  out[i - 1].kind == .chinese, out[i + 1].kind == .chinese else { continue }
            out[i].text = ""
        }
        return out
    }

    /// The text shown for decoded segments, with a space between Chinese and English.
    public func render(_ segments: [Segment]) -> String {
        var out = ""
        var previous: Segment.Kind?
        for s in segments {
            let isLanguage = s.kind != .other
            let language: Segment.Kind = s.kind == .pending ? .chinese : s.kind
            if autoSpace, isLanguage, let p = previous, p != language, out.last != " " { out.append(" ") }
            out += s.text
            previous = isLanguage ? language : (s.text == " " ? nil : previous)
        }
        return out
    }

    // MARK: - Candidates and offers

    public struct Candidate: Equatable {
        public var text: String
        public var range: Range<Int>
    }

    /// Words and characters ending at `cursor`, longest first, then most likely. Exact tones first.
    public func candidates(keys: [Character], segments: [Segment], cursor: Int) -> [Candidate] {
        var starts: [Int] = []
        for s in segments where s.kind == .chinese && s.range.lowerBound < cursor {
            starts.append(s.range.lowerBound)
            starts += s.syllableEnds.filter { $0 < cursor }
        }
        var results: [(Candidate, Float)] = []
        var seen = Set<String>()
        for start in Set(starts).sorted() {
            var collected: [(String, Float)] = []
            collect(node: 0, at: start, end: cursor, keys: keys, typed: [], into: &collected)
            for (word, score) in collected.sorted(by: { $0.1 > $1.1 }) where seen.insert(word).inserted {
                results.append((Candidate(text: word, range: start..<cursor), score))
            }
        }
        return results.sorted {
            $0.0.text.count != $1.0.text.count ? $0.0.text.count > $1.0.text.count : $0.1 > $1.1
        }.map { $0.0 }
    }

    private func collect(node: Int, at pos: Int, end: Int, keys: [Character], typed: [UInt8], into out: inout [(String, Float)]) {
        guard pos < end else { return }
        for span in syllableSpans(keys, from: pos) where span.end <= end {
            guard let child = lexicon.nodes[node].children[span.base] else { continue }
            let tones = typed + [span.tone]
            if span.end == end {
                for entry in lexicon.nodes[Int(child)].entries {
                    let matches = zip(tones, entry.tones).allSatisfy { $0 == Zhuyin.Tone.none || $0 == $1 }
                    if matches { out.append((entry.word, entry.score)) }
                }
            }
            collect(node: Int(child), at: span.end, end: end, keys: keys, typed: tones, into: &out)
        }
    }

    func bestCharacterAnyTone(_ keys: [Character]) -> String? {
        for span in syllableSpans(keys, from: 0) where span.end == keys.count {
            if let child = lexicon.nodes[0].children[span.base], let entry = lexicon.nodes[Int(child)].entries.first {
                return entry.word
            }
        }
        return nil
    }

    public struct Offer: Equatable {
        public var text: String        // what Tab would produce
        public var range: Range<Int>   // the keys it replaces
        public init(text: String, range: Range<Int>) { self.text = text; self.range = range }
    }

    /// One-edit spelling fix keeping the typed capitalisation.
    public func spellingFix(for typed: String) -> String? {
        guard let fix = lexicon.spellingFix(for: typed) else { return nil }
        if typed.count > 1, typed == typed.uppercased() { return fix.uppercased() }
        if typed.first?.isUppercase == true { return fix.prefix(1).uppercased() + fix.dropFirst() }
        return fix
    }

    /// The single Tab offer for the keys before `cursor`: personal entries first, then English.
    public func offer(keys: [Character], cursor: Int) -> Offer? {
        var start = cursor
        while start > 0, keys[start - 1].isASCII, keys[start - 1].isLetter { start -= 1 }
        let tail = String(keys[start..<cursor]).lowercased()
        if tail.count >= 2 {
            for entry in lexicon.userEntries {
                if let letters = entry.letters, letters.count > tail.count, letters.hasPrefix(tail) {
                    return Offer(text: entry.text, range: start..<cursor)
                }
            }
        }
        if let fix = chineseOffer(keys: keys, cursor: cursor) { return fix }
        // The letters are read as Zhuyin but are also a common word: offer that word first.
        if tail.count >= 2, let rank = lexicon.englishRank[tail], rank < commonWordsThreeLetters,
           decode(keys: Array(keys[..<cursor])).last?.kind != .english {
            return Offer(text: String(keys[start..<cursor]), range: start..<cursor)
        }
        if tail.count >= 2, let word = lexicon.bestCompletion[tail] {
            let typed = String(keys[start..<cursor])
            let text = typed.first!.isUppercase ? typed + word.dropFirst(typed.count) : word
            return Offer(text: text, range: start..<cursor)
        }
        return nil
    }

    /// A personal Chinese entry whose first syllables (at least two) were just typed.
    private func chineseOffer(keys: [Character], cursor: Int) -> Offer? {
        let entries = lexicon.userEntries.filter { $0.bases.count >= 2 }
        guard !entries.isEmpty else { return nil }
        var typed: [(start: Int, base: UInt16)] = []
        var pos = cursor
        // Walk back over complete syllables (shortest spans ending exactly at the current position).
        while pos > 0, typed.count < 8 {
            var found: (start: Int, base: UInt16)?
            for start in stride(from: pos - 1, through: max(0, pos - 4), by: -1) {
                if let span = syllableSpans(keys, from: start).first(where: { $0.end == pos }) {
                    found = (start, span.base)
                    break
                }
            }
            guard let hit = found else { break }
            typed.insert(hit, at: 0)
            pos = hit.start
        }
        for k in stride(from: typed.count, through: 2, by: -1) {
            let suffix = typed.suffix(k)
            let bases = suffix.map { $0.base }
            for entry in entries where entry.bases.count >= k && Array(entry.bases.prefix(k)) == bases {
                if entry.bases.count > k || entry.text.count > k {
                    return Offer(text: entry.text, range: suffix.first!.start..<cursor)
                }
            }
        }
        return nil
    }

    // MARK: - Edges

    /// The reading of `word` over a key range, as "ㄋㄧˇ-ㄏㄠˇ". A syllable typed with no tone
    /// takes the tone stored for the word, or first tone for a word the lexicon does not have.
    func reading(of word: String, keys: [Character], range: Range<Int>) -> String? {
        let count = word.count
        var path: [Span] = []
        func walk(at position: Int) -> Bool {
            if path.count == count { return position == range.upperBound }
            guard position < range.upperBound else { return false }
            for span in syllableSpans(keys, from: position) where span.end <= range.upperBound {
                path.append(span)
                if walk(at: span.end) { return true }
                path.removeLast()
            }
            return false
        }
        guard walk(at: range.lowerBound) else { return nil }
        var node = 0
        var known: [UInt8]?
        for span in path {
            guard let next = lexicon.nodes[node].children[span.base] else { node = -1; break }
            node = Int(next)
        }
        if node >= 0 { known = lexicon.nodes[node].entries.first(where: { $0.word == word })?.tones }
        let names = Dictionary(uniqueKeysWithValues: lexicon.baseIDs.map { ($1, $0) })
        var syllables: [String] = []
        for (i, span) in path.enumerated() {
            guard let base = names[span.base] else { return nil }
            let tone = span.tone != Zhuyin.Tone.none ? span.tone : (known?[i] ?? Zhuyin.Tone.first)
            syllables.append(base + Zhuyin.display(tone: tone))
        }
        return syllables.joined(separator: "-")
    }

    /// Same-sound single characters for one syllable, most likely first. Exact tone when typed;
    /// only characters that also occur inside words, which drops rare and simplified forms.
    func alternatives(keys: [Character], range: Range<Int>) -> [Character] {
        guard let span = syllableSpans(keys, from: range.lowerBound).first(where: { $0.end == range.upperBound }),
              let node = lexicon.nodes[0].children[span.base] else { return [] }
        var result: [Character] = []
        for entry in lexicon.nodes[Int(node)].entries where entry.word.count == 1 {
            guard span.tone == Zhuyin.Tone.none || entry.tones[0] == span.tone,
                  let character = entry.word.first, lexicon.charactersInWords.contains(character) else { continue }
            result.append(character)
            if result.count == Self.alternativesPerCharacter { break }
        }
        return result
    }

    private func syllableSpans(_ keys: [Character], from i: Int) -> [Span] {
        var result: [Span] = []
        var symbols: [Character] = []
        var j = i
        while j < keys.count, symbols.count < 3, let s = Zhuyin.symbolForKey[keys[j]] {
            symbols.append(s)
            j += 1
            guard let canonical = Zhuyin.canonical(symbols) else { break }
            guard let id = lexicon.baseIDs[canonical] else { continue }
            if j < keys.count, let tone = Zhuyin.toneForKey[keys[j]] {
                result.append(Span(end: j + 1, base: id, tone: tone))
            } else {
                result.append(Span(end: j, base: id, tone: Zhuyin.Tone.none))
            }
        }
        return result
    }

    private func edges(from i: Int, keys: [Character], spans: [[Span]], context: Segment.Kind, fixedAt: [Constraint?]) -> [Edge] {
        if let fixed = fixedAt[i], case .text(let text, let kind) = fixed.fix {
            guard fixed.range.lowerBound == i else { return [] }
            return [Edge(end: fixed.range.upperBound, kind: kind, text: text, cost: 0, syllableEnds: fixed.syllableEnds.map { $0 + i },
                         word: kind == .chinese ? Lexicon.wordID(text) : 0)]
        }
        var out: [Edge] = []
        chineseEdges(from: i, keys: keys, spans: spans, into: &out)
        pendingEdge(from: i, keys: keys, context: context, into: &out)
        englishEdges(from: i, keys: keys, context: context, into: &out)
        tokenEdges(from: i, keys: keys, into: &out)
        numberEdge(from: i, keys: keys, into: &out)
        listMarkerEdge(from: i, keys: keys, into: &out)
        literalEdge(from: i, keys: keys, context: context, into: &out)
        return out.filter { edge in
            for k in i..<edge.end where k < fixedAt.count {
                guard let f = fixedAt[k] else { continue }
                switch f.fix {
                case .text: return false            // would cut through a picked candidate
                case .language(let kind):
                    let language: Segment.Kind = edge.kind == .pending ? .chinese : edge.kind
                    if language != kind, !edge.keepsLanguage { return false }
                }
            }
            return true
        }
    }

    private func chineseEdges(from start: Int, keys: [Character], spans: [[Span]], into out: inout [Edge]) {
        var bestByEnd: [Int: [(cost: Float, word: String, ends: [Int], score: Float, id: UInt32)]] = [:]
        var chosen: [Int: [(cost: Float, word: String, ends: [Int], score: Float, id: UInt32)]] = [:]   // words the user has paired
        var typed: [UInt8] = []
        var ends: [Int] = []
        let keep = max(1, costs.wordsPerSpan)   // pairs and the 得 rule choose among them

        func walk(node: Int, at pos: Int) {
            guard pos < keys.count, typed.count < 8 else { return }
            for span in spans[pos] {
                guard let child = lexicon.nodes[node].children[span.base] else { continue }
                typed.append(span.tone)
                ends.append(span.end)
                for entry in lexicon.nodes[Int(child)].entries {
                    guard let penalty = tonePenalty(typed: typed, entry: entry.tones) else { continue }
                    if typed.contains(Zhuyin.Tone.none), entry.score < costs.tonelessMinScore { continue }
                    let cost = -entry.score + penalty
                    if lexicon.ownPairWords.contains(entry.id) {
                        chosen[span.end, default: []].append((cost, entry.word, ends, entry.score, entry.id))
                        continue
                    }
                    var list = bestByEnd[span.end] ?? []
                    if list.count == keep, cost >= list[list.count - 1].cost { continue }
                    if let same = list.firstIndex(where: { $0.word == entry.word }) {
                        if cost >= list[same].cost { continue }
                        list.remove(at: same)
                    }
                    let at = list.firstIndex(where: { cost < $0.cost }) ?? list.count
                    list.insert((cost, entry.word, ends, entry.score, entry.id), at: at)
                    if list.count > keep { list.removeLast() }
                    bestByEnd[span.end] = list
                }
                walk(node: Int(child), at: span.end)
                typed.removeLast()
                ends.removeLast()
            }
        }
        walk(node: 0, at: start)
        for list in [bestByEnd, chosen] {
            for (end, words) in list {
                for best in words {
                    out.append(Edge(end: end, kind: .chinese, text: best.word, cost: best.cost, syllableEnds: best.ends,
                                    word: best.id, score: best.score))
                }
            }
        }
    }

    /// Extra cost of reading `entry` from the typed tones, nil when not allowed.
    private func tonePenalty(typed: [UInt8], entry: [UInt8]) -> Float? {
        var penalty: Float = 0
        var wrong = 0
        for (t, e) in zip(typed, entry) {
            if t == Zhuyin.Tone.none {
                if typed.count < 2 { return nil }     // a lone syllable needs its tone
                penalty += costs.tonelessSyllable
            } else if t != e {
                let neutralPair = (t == Zhuyin.Tone.first && e == Zhuyin.Tone.neutral) || (t == Zhuyin.Tone.neutral && e == Zhuyin.Tone.first)
                if typed.count < 2 { return neutralPair ? costs.neutralForFirst : nil }
                if neutralPair { penalty += costs.neutralForFirst; continue }
                wrong += 1
                if wrong > 1 { return nil }
                penalty += costs.wrongTone
            }
        }
        return penalty
    }

    /// Keys at the very end that may become a syllable: shown as Zhuyin symbols.
    private func pendingEdge(from i: Int, keys: [Character], context: Segment.Kind, into out: inout [Edge]) {
        let rest = keys[i...]
        guard rest.count <= 3 else { return }
        // "你好 ap": a space after a syllable that already has its tone key cannot be a tone itself,
        // so the letters after it are English from the first key instead of waiting for the third.
        if rest.allSatisfy({ $0.isASCII && $0.isLetter }), spaceClosesToneKey(keys, before: i) {
            out.append(Edge(end: keys.count, kind: .english, text: String(rest), cost: costs.englishAfterSpace))
            return
        }
        let symbols = rest.compactMap { Zhuyin.symbolForKey[$0] }
        guard symbols.count == rest.count, let canonical = Zhuyin.canonical(symbols),
              lexicon.partialSyllables.contains(canonical) else { return }
        let afterEnglish = context == .english && rest.allSatisfy { $0.isLetter }
        out.append(Edge(end: keys.count, kind: .pending, text: canonical,
                        cost: costs.pendingSyllable + (afterEnglish ? costs.pendingAfterEnglish : 0)))
    }

    /// True when keys[i-1] is a space that follows a tone key (3 4 6 7), so it is a word boundary and not the first tone.
    private func spaceClosesToneKey(_ keys: [Character], before i: Int) -> Bool {
        guard i >= 2, keys[i - 1] == " " else { return false }
        return Zhuyin.toneForKey[keys[i - 2]] != nil && keys[i - 2] != " "
    }

    private func englishCost(rank: Int) -> Float {
        var cost = costs.englishBase + costs.englishPerRank * log(Float(rank + 1))
        switch preference {
        case .englishFirst: cost -= 5
        case .habit, .chineseFirst: break
        }
        return cost
    }

    private func englishEdges(from i: Int, keys: [Character], context: Segment.Kind, into out: inout [Edge]) {
        guard keys[i].isASCII, keys[i].isLetter else { return }
        var j = i
        var word = ""
        var hasUpper = false
        while j < keys.count, keys[j].isASCII, keys[j].isLetter {
            if keys[j].isUppercase { hasUpper = true }
            word.append(keys[j])
            j += 1
            let lower = word.lowercased()
            let length = word.count
            let atWordEnd = j == keys.count || !(keys[j].isASCII && keys[j].isLetter)
            if let stored = lexicon.userEnglish[lower] {
                out.append(Edge(end: j, kind: .english, text: hasUpper ? word : stored, cost: englishCost(rank: 0)))
                continue
            }
            let rank = lexicon.englishRank[lower]
            if !hasUpper, Self.twoLetterWords.contains(lower) {
                out.append(Edge(end: j, kind: .english, text: word, cost: englishCost(rank: rank ?? 100)))
                continue
            }
            if hasUpper {
                let cost = rank.map(englishCost(rank:)) ?? (costs.unknownCapitalised + Float(length) * 0.5)
                out.append(Edge(end: j, kind: .english, text: word, cost: cost))
                continue
            }
            if let rank {
                let limit = length >= 4 ? commonWordsLonger : (length == 3 ? commonWordsThreeLetters : commonWordsTwoLetters)
                let afterEnglish = context == .english
                if rank < limit, length >= 3 || afterEnglish {
                    out.append(Edge(end: j, kind: .english, text: word, cost: englishCost(rank: rank)))
                    continue
                }
                if afterEnglish {
                    out.append(Edge(end: j, kind: .english, text: word, cost: englishCost(rank: rank) + 2))
                    continue
                }
            }
            // Not a word: a last resort so that nothing is ever undecodable.
            if atWordEnd {
                let base = context == .english ? costs.unknownAfterEnglish : costs.unknownLowercase
                out.append(Edge(end: j, kind: .english, text: word, cost: base + Float(length)))
            }
        }
    }

    /// URLs, e-mail addresses and letters joined by . - _ / are English as a whole.
    private func tokenEdges(from i: Int, keys: [Character], into out: inout [Edge]) {
        guard keys[i].isASCII, keys[i].isLetter || keys[i].isNumber else { return }
        var j = i
        while j < keys.count, keys[j] != " ", keys[j].isASCII { j += 1 }
        guard j - i >= 3 else { return }
        let token = String(keys[i..<j])
        if token.contains("://") {
            out.append(Edge(end: j, kind: .english, text: token, cost: costs.token))
            return
        }
        if token.contains("@") {
            out.append(Edge(end: j, kind: .english, text: token, cost: costs.token + Float(j - i)))
            return
        }
        let joiners: Set<Character> = [".", "-", "_", "/"]
        let parts = token.split(whereSeparator: { joiners.contains($0) })
        guard parts.count >= 2, joiners.contains(where: token.contains),
              !joiners.contains(token.last!), !joiners.contains(token.first!),
              token.allSatisfy({ $0.isLetter || $0.isNumber || joiners.contains($0) }),
              parts[0].count >= 2, parts[0].contains(where: { $0.isLetter }), parts.last!.contains(where: { $0.isLetter }),
              // A tone key after a joiner ("jt/6de") is Zhuyin, and real tokens hold a real word.
              parts.allSatisfy({ $0.first!.isLetter || $0.allSatisfy({ $0.isNumber }) }),
              parts.contains(where: { lexicon.englishRank[$0.lowercased()] != nil }) else { return }
        out.append(Edge(end: j, kind: .english, text: token, cost: costs.joinedToken + Float(j - i) * costs.perTokenKey))
    }

    /// "2." typed on its own (start of the text or after a space, then a space or nothing) is a list number,
    /// not ㄉㄡ. A tone key or letters after the dot keep the Zhuyin reading: "2.4" is still 豆.
    private func listMarkerEdge(from i: Int, keys: [Character], into out: inout [Edge]) {
        guard keys[i].isASCII, keys[i].isNumber, i + 1 < keys.count, keys[i + 1] == ".",
              i == 0 || keys[i - 1] == " ",
              i + 2 == keys.count || keys[i + 2] == " " else { return }
        out.append(Edge(end: i + 2, kind: .other, text: String(keys[i...(i + 1)]), cost: costs.listMarker, keepsLanguage: true))
    }

    private func numberEdge(from i: Int, keys: [Character], into out: inout [Edge]) {
        guard keys[i].isNumber else { return }
        var j = i
        while j < keys.count, keys[j].isNumber { j += 1 }
        for end in (i + 1)...j {
            out.append(Edge(end: end, kind: .other, text: String(keys[i..<end]),
                            cost: costs.number + Float(end - i) * 0.1 + (end == j ? 0 : 6), keepsLanguage: true))
        }
    }

    private func literalEdge(from i: Int, keys: [Character], context: Segment.Kind, into out: inout [Edge]) {
        let key = keys[i]
        if key == " " {
            out.append(Edge(end: i + 1, kind: .other, text: " ", cost: costs.space, keepsLanguage: true))
        } else if let symbol = Self.symbols[key] {
            let full: Bool
            switch punctuationWidth {
            case .follow: full = context == .chinese
            case .full: full = true
            case .half: full = false
            }
            let text = full ? symbol.full : symbol.half
            out.append(Edge(end: i + 1, kind: .other, text: text, cost: 1, keepsLanguage: true))
        } else if key.isLetter, key.isLowercase, key.isASCII {
            out.append(Edge(end: i + 1, kind: .other, text: String(key), cost: costs.strayLetter, keepsLanguage: true))
        } else if !key.isLetter, !key.isNumber {
            // Punctuation keys that are also Zhuyin keys: literal only when nothing else fits.
            out.append(Edge(end: i + 1, kind: .other, text: String(key), cost: costs.literalPunctuation, keepsLanguage: true))
        }
    }
}
