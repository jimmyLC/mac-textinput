import Foundation

/// Chinese words indexed by syllables in a trie, and English words by frequency rank.
public final class Lexicon {
    struct Entry {
        let word: String
        let score: Float      // log probability
        let tones: [UInt8]
    }
    struct Node {
        var children: [UInt16: Int32] = [:]
        var entries: [Entry] = []
    }

    private(set) var nodes: [Node] = [Node()]
    private(set) var baseIDs: [String: UInt16] = [:]
    private(set) var partialSyllables: Set<String> = []   // every subset of a valid syllable
    private(set) var englishRank: [String: Int] = [:]
    private(set) var userEnglish: [String: String] = [:]  // lowercase -> stored spelling
    private(set) var bestCompletion: [String: String] = [:]   // English prefix -> most frequent longer word
    private(set) var userEntries: [UserEntry] = []

    /// A personal-dictionary entry offered by Tab: starts with English letters or Chinese syllables.
    struct UserEntry {
        let text: String
        let letters: String?     // lowercase letters of the entry, spaces removed, when it starts in English
        let bases: [UInt16]      // syllables of the leading Chinese part
    }

    public init() {}

    /// `tsv` rows are `word<TAB>log-prob<TAB>reading|reading`, syllables joined with "-".
    public func loadChinese(tsv: String) {
        for line in tsv.split(separator: "\n") {
            let f = line.split(separator: "\t")
            guard f.count >= 3, let score = Float(f[1]) else { continue }
            for reading in f[2].split(separator: "|") {
                insert(word: String(f[0]), score: score, syllables: reading.split(separator: "-"))
            }
        }
        for i in nodes.indices where nodes[i].entries.count > 1 {
            nodes[i].entries.sort { $0.score > $1.score }
        }
    }

    /// `text` rows are `word<TAB>count` or `word`, most frequent first.
    public func loadEnglish(text: String, limit: Int = 120_000) {
        var rank = englishRank.count
        for line in text.split(separator: "\n").prefix(limit) {
            let word = line.split(separator: "\t").first.map { $0.lowercased() } ?? ""
            guard !word.isEmpty, englishRank[word] == nil else { continue }
            englishRank[word] = rank
            rank += 1
            // Most frequent first, so the first word seen for a prefix is the best one.
            if rank <= 20_000, word.count >= 3 {
                var prefix = ""
                for ch in word.dropLast().prefix(8) {
                    prefix.append(ch)
                    if prefix.count >= 2, bestCompletion[prefix] == nil { bestCompletion[prefix] = word }
                }
            }
        }
    }

    /// Personal-dictionary English word: always allowed, keeps its capitalisation.
    public func addUserEnglish(_ word: String) {
        userEnglish[word.lowercased()] = word
        addUserEntry(word, reading: nil)
    }

    /// Any personal entry for Tab completion: English, Chinese or mixed ("Claude Code", "產品ID").
    /// `reading` covers its leading Chinese characters, syllables joined with "-".
    public func addUserEntry(_ text: String, reading: String?) {
        let startsChinese = text.first.map { !$0.isASCII } ?? false
        let letters = startsChinese ? nil : text.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let bases = (reading ?? "").split(separator: "-").compactMap { baseIDs[Zhuyin.split($0).base] }
        userEntries.removeAll { $0.text == text }
        userEntries.append(UserEntry(text: text, letters: letters, bases: bases))
    }

    public func removeUserEntry(_ text: String) {
        userEntries.removeAll { $0.text == text }
        userEnglish.removeValue(forKey: text.lowercased())
    }

    /// The most frequent known word one edit away from a misspelling; nil for known or short words.
    public func spellingFix(for word: String, top: Int = 30_000) -> String? {
        let w = word.lowercased()
        guard w.count >= 4, englishRank[w] == nil, userEnglish[w] == nil,
              w.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        let chars = Array(w)
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        var best: (String, Int)?
        func consider(_ c: String) {
            if let r = englishRank[c], r < top, r < (best?.1 ?? .max) { best = (c, r) }
        }
        for i in 0...chars.count {
            if i < chars.count { consider(String(chars[..<i] + chars[(i + 1)...])) }
            if i + 1 < chars.count { var c = chars; c.swapAt(i, i + 1); consider(String(c)) }
            for l in letters {
                consider(String(chars[..<i]) + String(l) + String(chars[i...]))
                if i < chars.count { var c = chars; c[i] = l; consider(String(c)) }
            }
        }
        return best?.0
    }

    /// Personal-dictionary Chinese word, scored like a very common word.
    public func addUserChinese(_ word: String, reading: String, score: Float = -3) {
        insert(word: word, score: score, syllables: reading.split(separator: "-"))
        addUserEntry(word, reading: reading)
        // Keep best-first order for the node just touched.
        var node = 0
        for s in reading.split(separator: "-") {
            guard let id = baseIDs[Zhuyin.split(s).base], let next = nodes[node].children[id] else { return }
            node = Int(next)
        }
        nodes[node].entries.sort { $0.score > $1.score }
    }

    private func insert(word: String, score: Float, syllables: [Substring]) {
        guard !syllables.isEmpty, syllables.count <= 8, word.count == syllables.count else { return }
        var node = 0
        var tones: [UInt8] = []
        tones.reserveCapacity(syllables.count)
        for s in syllables {
            let (base, tone) = Zhuyin.split(s)
            tones.append(tone)
            let id = baseID(base)
            if let next = nodes[node].children[id] {
                node = Int(next)
            } else {
                nodes.append(Node())
                let next = Int32(nodes.count - 1)
                nodes[node].children[id] = next
                node = Int(next)
            }
        }
        nodes[node].entries.append(Entry(word: word, score: score, tones: tones))
    }

    private func baseID(_ base: String) -> UInt16 {
        if let id = baseIDs[base] { return id }
        let id = UInt16(baseIDs.count)
        baseIDs[base] = id
        // Register all subsets, so an unfinished syllable can be recognised while typing.
        let parts = Array(base)
        for mask in 1..<(1 << parts.count) {
            partialSyllables.insert(String(parts.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { $0.element }))
        }
        return id
    }
}
