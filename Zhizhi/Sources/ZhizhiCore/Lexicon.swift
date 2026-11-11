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
    private(set) var charactersInWords: Set<Character> = []
    private var originalScores: [String: Float] = [:]     // word + reading, before any boost
    private var pairKeys: [UInt64] = []                   // sorted: first word's id << 32 | second word's id
    private var pairScores: [Float] = []                  // log10 P(second | first), same order
    var hasPairs: Bool { !pairKeys.isEmpty }

    /// A personal-dictionary entry offered by Tab: starts with English letters or Chinese syllables.
    struct UserEntry {
        let text: String
        let letters: String?     // lowercase letters of the entry, spaces removed, when it starts in English
        let bases: [UInt16]      // syllables of the leading Chinese part
    }

    public init() {}

    /// `tsv` rows are `word<TAB>log-prob<TAB>reading|reading`, syllables joined with "-".
    public func loadChinese(tsv: String) {
        var rows: [(word: Substring, score: Float, readings: [Substring])] = []
        // How often each character is read each way, taken from the multi-character words that hold it:
        // 會 is ㄏㄨㄟˋ in 會議, 社會, 機會 and ㄎㄨㄞˋ only in 會計.
        var seen: [Character: [Substring: Float]] = [:]
        for line in tsv.split(separator: "\n") {
            let f = line.split(separator: "\t")
            guard f.count >= 3, let score = Float(f[1]) else { continue }
            let readings = f[2].split(separator: "|")
            rows.append((f[0], score, readings))
            guard f[0].count > 1 else { continue }
            charactersInWords.formUnion(f[0])
            let weight = pow(10, score) / Float(readings.count)
            for reading in readings {
                let syllables = reading.split(separator: "-")
                guard syllables.count == f[0].count else { continue }
                for (character, syllable) in zip(f[0], syllables) { seen[character, default: [:]][syllable, default: 0] += weight }
            }
        }
        for row in rows {
            for (index, reading) in row.readings.enumerated() {
                var score = row.score
                // A character with several readings: each reading gets its share of the character's frequency,
                // so a rare reading (會 as ㄎㄨㄞˋ) no longer outranks the common character of that sound (快).
                if row.word.count == 1, row.readings.count > 1, let character = row.word.first {
                    let counts = seen[character] ?? [:]
                    // Used on its own (嗎, 和, 的) a character has its main reading, the first one listed.
                    let alone = pow(10, row.score)
                    let prior: Float = index == 0 ? alone : 1e-7
                    let total = row.readings.enumerated().reduce(Float(0)) { $0 + (counts[$1.element] ?? 0) + ($1.offset == 0 ? alone : 1e-7) }
                    let share = ((counts[reading] ?? 0) + prior) / total
                    score += max(log10(share), Self.rareReadingFloor)
                }
                insert(word: String(row.word), score: score, syllables: reading.split(separator: "-"))
            }
        }
        for i in nodes.indices where nodes[i].entries.count > 1 {
            nodes[i].entries.sort { $0.score > $1.score }
        }
    }

    /// The most a rare reading is pushed down (log10), so it can still be typed and picked.
    static let rareReadingFloor: Float = -3

    // MARK: - Word pairs

    /// A stable 32-bit id for a word (FNV-1a over UTF-8); never 0.
    static func wordID(_ word: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in word.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    /// log10 P(second | first) when the pair was seen often enough to be kept.
    func pairScore(_ first: UInt32, _ second: UInt32) -> Float? {
        let key = UInt64(first) << 32 | UInt64(second)
        var low = 0, high = pairKeys.count
        while low < high {
            let mid = (low + high) / 2
            if pairKeys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low < pairKeys.count && pairKeys[low] == key ? pairScores[low] : nil
    }

    /// `tsv` rows are `first<TAB>second<TAB>count`.
    public func loadPairs(tsv: String) {
        var rows: [(UInt64, Float, UInt32)] = []
        var after: [UInt32: Float] = [:]      // how often each word was seen with any word after it
        rows.reserveCapacity(1_600_000)
        for line in tsv.split(separator: "\n") {
            let f = line.split(separator: "\t")
            guard f.count >= 3, let count = Float(f[2]) else { continue }
            let first = Self.wordID(String(f[0])), second = Self.wordID(String(f[1]))
            rows.append((UInt64(first) << 32 | UInt64(second), count, first))
            after[first, default: 0] += count
        }
        rows.sort { $0.0 < $1.0 }
        pairKeys = rows.map { $0.0 }
        pairScores = rows.map { log10($0.1 / after[$0.2]!) }
    }

    /// The pairs as one block of bytes: a count, the keys, the scores. Loads in a blink.
    public var pairData: Data {
        var data = Data()
        var count = UInt64(pairKeys.count)
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        pairKeys.withUnsafeBytes { data.append(contentsOf: $0) }
        pairScores.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    public func loadPairs(data: Data) {
        guard data.count >= 8 else { return }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard count > 0, data.count == 8 + count * 12 else { return }
        pairKeys = [UInt64](repeating: 0, count: count)
        pairScores = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            pairKeys.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[8..<(8 + count * 8)])) }
            pairScores.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(8 + count * 8)...])) }
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

    /// Undoes `addUserChinese`.
    public func removeUserChinese(_ word: String, reading: String) {
        removeUserEntry(word)
        guard let node = node(for: reading) else { return }
        nodes[node].entries.removeAll { $0.word == word }
    }

    /// A reading for any word: the stored one, or else its characters' most likely readings.
    /// Stops at the first character with none. Walks the whole trie, so it is for the App, not typing.
    public func suggestedReading(for word: String) -> String {
        var found: [String: (score: Float, reading: String)] = [:]
        let wanted = Set(word.map(String.init)).union([word])
        let names = Dictionary(uniqueKeysWithValues: baseIDs.map { ($1, $0) })
        func walk(_ node: Int, _ path: [String]) {
            for entry in nodes[node].entries where wanted.contains(entry.word) {
                if entry.score > found[entry.word]?.score ?? -.infinity {
                    let reading = zip(path, entry.tones).map { $0 + Zhuyin.display(tone: $1) }.joined(separator: "-")
                    found[entry.word] = (entry.score, reading)
                }
            }
            guard path.count < word.count else { return }
            for (base, child) in nodes[node].children {
                if let name = names[base] { walk(Int(child), path + [name]) }
            }
        }
        walk(0, [])
        if let whole = found[word] { return whole.reading }
        var parts: [String] = []
        for character in word {
            guard let part = found[String(character)] else { break }
            parts.append(part.reading)
        }
        return parts.joined(separator: "-")
    }

    public func hasEntry(word: String, reading: String) -> Bool {
        guard let node = node(for: reading) else { return false }
        return nodes[node].entries.contains { $0.word == word }
    }

    /// Raises a word above its original score by `amount`. Repeating replaces, it does not add up.
    /// Keeps the entry's tones: only the word's rank among its homophones changes.
    public func setBoost(word: String, reading: String, amount: Float) {
        guard let node = node(for: reading),
              let index = nodes[node].entries.firstIndex(where: { $0.word == word }) else { return }
        let key = word + "\t" + reading
        let original = originalScores[key] ?? nodes[node].entries[index].score
        originalScores[key] = original
        let entry = nodes[node].entries[index]
        nodes[node].entries[index] = Entry(word: word, score: original + amount, tones: entry.tones)
        nodes[node].entries.sort { $0.score > $1.score }
    }

    private func node(for reading: String) -> Int? {
        var node = 0
        for s in reading.split(separator: "-") {
            guard let id = baseIDs[Zhuyin.split(s).base], let next = nodes[node].children[id] else { return nil }
            node = Int(next)
        }
        return node
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
