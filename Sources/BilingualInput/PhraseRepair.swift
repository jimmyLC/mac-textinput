import Foundation

/// Fixes wrong tones in typed Zhuyin: when the typed syllables do not form a known
/// phrase but the same sounds with one tone changed form a likely one ("ㄋㄧˇ-ㄏㄠˋ"
/// → 你好), that phrase is suggested. Works on readings only; never sees typed text.
struct PhraseRepair {
    struct Suggestion: Equatable {
        let word: String
        let readings: [String]   // corrected syllables, tone 1 carries no mark
    }

    private struct Entry { let word: String; let readings: [String]; let score: Double }
    private var byBase: [String: [Entry]] = [:]   // toneless syllables joined by "-"
    private var known: Set<String> = []           // exact toned readings
    private var charScore: [String: Double] = [:]   // best single-character score per toned syllable
    private let minScore: Double
    private let margin: Double

    /// `lines` are lexicon rows `word<TAB>score<TAB>reading|reading` (score = log probability).
    init<S: Sequence>(lines: S, minScore: Double = -6.5, margin: Double = 1.5) where S.Element == Substring {
        self.minScore = minScore
        self.margin = margin
        for line in lines {
            let f = line.split(separator: "\t")
            guard f.count >= 3, let score = Double(f[1]) else { continue }
            if f[0].count == 1 {
                for r in f[2].split(separator: "|") { charScore[String(r), default: -99] = max(charScore[String(r)] ?? -99, score) }
                continue
            }
            for reading in f[2].split(separator: "|") {
                let syllables = reading.split(separator: "-").map(String.init)
                guard syllables.count >= 2, syllables.count <= 5 else { continue }
                known.insert(syllables.joined(separator: "-"))
                let base = syllables.map(Self.stripTone).joined(separator: "-")
                byBase[base, default: []].append(Entry(word: String(f[0]), readings: syllables, score: score))
            }
        }
    }

    static func stripTone(_ s: String) -> String { String(s.filter { !ZhuyinKeyboard.tones.contains($0) }) }
    static func tone(_ s: String) -> Character? { s.last.flatMap { ZhuyinKeyboard.tones.contains($0) ? $0 : nil } }

    /// `typed` syllables with tone marks (tone 1 unmarked). Nil when they already form a
    /// known phrase or no single-tone change gives a likely one.
    func suggest(_ typed: [String]) -> Suggestion? {
        guard typed.count >= 2, !known.contains(typed.joined(separator: "-")) else { return nil }
        let base = typed.map(Self.stripTone).joined(separator: "-")
        var best: Entry?
        for entry in byBase[base] ?? [] where entry.score >= minScore {
            var diffs = 0, neutralOnly = false
            for (a, b) in zip(typed, entry.readings) where a != b {
                diffs += 1
                let tones = [Self.tone(a), Self.tone(b)]
                neutralOnly = tones.contains(where: { $0 == "˙" }) && tones.contains(where: { $0 == nil })
            }
            guard diffs == 1, !neutralOnly else { continue }
            if best == nil || entry.score > best!.score { best = entry }
        }
        // The phrase must clearly beat reading the typed syllables as separate characters,
        // otherwise ordinary word boundaries would be "corrected".
        let separate = typed.reduce(0.0) { $0 + (charScore[$1] ?? -12) }
        guard let best, best.score - separate >= margin else { return nil }
        return Suggestion(word: best.word, readings: best.readings)
    }

    static let keysByZhuyin: [Character: Character] = {
        var m = [Character: Character]()
        for (k, v) in ZhuyinKeyboard.keyMap { m[v] = k }
        return m
    }()

    /// Typing keys for a syllable ("ㄋㄧˇ" → "su3", unmarked tone 1 → trailing space).
    static func keys(for syllable: String) -> String {
        var out = ""
        for ch in syllable { if let k = keysByZhuyin[ch] { out.append(k) } }
        if tone(syllable) == nil { out.append(" ") }
        return out
    }

    /// Syllable (tone mark appended, tone 1 unmarked) for keys such as "su3" or "ji ".
    static func syllable(fromKeys keys: String) -> String? {
        var out = ""
        for ch in keys {
            guard let z = ZhuyinKeyboard.keyMap[ch] else { return nil }
            if z != "ˉ" { out.append(z) }
        }
        return out.isEmpty ? nil : out
    }
}
