import Foundation

/// Standard (標準) Zhuyin keyboard layout and syllable validity. The valid
/// syllable set is injected (derived from the Chinese lexicon readings), so this
/// file holds no dictionary data.
enum ZhuyinKeyboard {
    static let keyMap: [Character: Character] = [
        "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
        "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
        "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
        "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
        "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
        "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
        "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
        "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
        "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
        "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ", "-": "ㄦ",
        "6": "ˊ", "3": "ˇ", "4": "ˋ", "7": "˙", " ": "ˉ",
    ]
    static let tones: Set<Character> = ["ˊ", "ˇ", "ˋ", "˙", "ˉ"]
}

enum ZhuyinParse: Equatable {
    case complete    // whole string splits into valid syllables
    case prefix      // valid so far, last syllable still being typed
    case invalid
}

/// Decides whether raw keys are plausibly Zhuyin. Syllable validity alone is far
/// too permissive ("hello" splits into ㄘ|ㄍㄠ|ㄠ|ㄟ), so a toneless syllable only
/// counts when it belongs to a multi-syllable lexicon word; a lone syllable must
/// carry an explicit tone, unless it is the entire input.
struct ZhuyinSyllableIndex {
    private let syllables: Set<String>
    private let syllablePrefixes: Set<String>
    private let words: Set<String>          // "ㄊㄧㄢ-ㄊㄧㄢ" (toneless, >= 2 syllables)
    private let wordPrefixes: Set<String>

    /// `readings` are lexicon reading fields such as "ㄋㄧˇ-ㄏㄠˇ|ㄋㄧˊ".
    init<S: Sequence>(readings: S) where S.Element == String {
        var syllables = Set<String>()
        var words = Set<String>()
        for field in readings {
            for reading in field.split(separator: "|") {
                let parts = reading.split(separator: "-").map { String($0.filter { !ZhuyinKeyboard.tones.contains($0) }) }
                guard parts.allSatisfy({ !$0.isEmpty }) else { continue }
                syllables.formUnion(parts)
                if parts.count >= 2 { words.insert(parts.joined(separator: "-")) }
            }
        }
        self.syllables = syllables
        self.words = words
        func prefixes(_ values: Set<String>) -> Set<String> {
            var result = Set<String>()
            for v in values { var p = ""; for ch in v.dropLast() { p.append(ch); result.insert(p) } }
            return result
        }
        syllablePrefixes = prefixes(syllables)
        wordPrefixes = prefixes(words)
    }

    /// Whether the keys spell exactly one valid (toneless) syllable, e.g. "co" = ㄏㄟ (黑).
    func isSyllable(_ keys: String) -> Bool {
        let symbols = keys.compactMap { ZhuyinKeyboard.keyMap[$0] }
        return !keys.isEmpty && symbols.count == keys.count && syllables.contains(String(symbols))
    }

    /// A pending syllable may be typed out of order (e.g. `url` -> ㄐㄧㄠ).
    /// Preserve it until a tone or an explicit English choice disambiguates it.
    func couldBeSyllable(_ keys: String) -> Bool {
        guard !keys.isEmpty else { return false }
        var groups: [Int: Character] = [:]
        for key in keys {
            guard let symbol = ZhuyinKeyboard.keyMap[key] else { return false }
            let group: Int
            if "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ".contains(symbol) { group = 0 }
            else if "ㄧㄨㄩ".contains(symbol) { group = 1 }
            else if "ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ".contains(symbol) { group = 2 }
            else { return false }
            // Repeated groups are more likely an English word than one pending syllable.
            guard groups[group] == nil else { return false }
            groups[group] = symbol
        }
        let symbols = String((0...2).compactMap { groups[$0] })
        return syllables.contains(symbols) || syllablePrefixes.contains(symbols)
    }

    func parse(_ keys: String) -> ZhuyinParse {
        guard !keys.isEmpty else { return .invalid }
        var symbols: [Character] = []
        for key in keys {
            guard let symbol = ZhuyinKeyboard.keyMap[key] else { return .invalid }
            symbols.append(symbol)
        }
        let n = symbols.count
        var reachable = [Bool](repeating: false, count: n + 1)
        reachable[0] = true
        var partial = false
        for start in 0..<n where reachable[start] {
            walk(symbols, from: start, wholeInput: start == 0, bare: [], count: 0,
                 reachable: &reachable, partial: &partial)
        }
        if reachable[n] { return .complete }
        return partial ? .prefix : .invalid
    }

    /// Extend one lexicon-word group syllable by syllable from `from`.
    private func walk(_ s: [Character], from: Int, wholeInput: Bool, bare: [String], count: Int,
                      reachable: inout [Bool], partial: inout Bool) {
        let n = s.count
        var text = ""
        var j = from
        while j < n, !ZhuyinKeyboard.tones.contains(s[j]) {
            text.append(s[j]); j += 1
            let isSyllable = syllables.contains(text)
            let canGrow = syllablePrefixes.contains(text) || isSyllable
            if j == n, (syllablePrefixes.contains(text) || (isSyllable && bare.isEmpty)) { partial = true }
            if isSyllable {
                // Toneless end at j, or toned end at j + 1.
                var ends: [(Int, Bool)] = [(j, false)]
                if j < n, ZhuyinKeyboard.tones.contains(s[j]) { ends.append((j + 1, true)) }
                for (end, toned) in ends {
                    let group = bare + [text]
                    let joined = group.joined(separator: "-")
                    if group.count == 1 {
                        if toned || (wholeInput && end == n) { reachable[end] = true }
                    } else if words.contains(joined) {
                        reachable[end] = true
                    }
                    if end == n, wordPrefixes.contains(joined) || words.contains(joined) { partial = true }
                    if end < n, count < 8, wordPrefixes.contains(joined) {
                        walk(s, from: end, wholeInput: false, bare: group, count: count + 1,
                             reachable: &reachable, partial: &partial)
                    }
                    if end < n, group.count == 1 && toned {
                        // A toned single syllable can also start a longer word.
                        walk(s, from: end, wholeInput: false, bare: group, count: count + 1,
                             reachable: &reachable, partial: &partial)
                    }
                }
            }
            if !canGrow { break }
        }
    }
}
