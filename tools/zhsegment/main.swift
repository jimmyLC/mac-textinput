// zhsegment — ZhuyinLM-IME 繁體中文斷詞 + 詞接詞(bigram)計數器
//
// 用法:
//   zhsegment <lexicon.tsv> [--wiki] [--by-key] [--keep-ones] [--segment]
//              [--s2t <chars.tsv>] [--s2t-phrases <phrases.tsv>]
//
// 輸入:任意文字(UTF-8)。中文以「最長匹配」(forward maximum matching)斷詞,
//       詞典為 data/chinese-lexicon.tsv 的第一欄;英數以連續 run 為一個 token。
// 輸出(預設):「前詞\t後詞\t次數」,依次數由大到小。
//
// 選項
//   --wiki            僅取 MediaWiki XML 的 <text>…</text> 內文
//   --by-key          依 (前詞,後詞) 的 UTF-8 位元組序輸出(供外部 k-way merge)
//   --keep-ones       保留只出現一次的配對(除錯用)
//   --segment         輸出斷詞結果(每行一句,詞以 / 分隔)
//   --s2t FILE        簡→繁 字形對照表(逐字)
//   --s2t-phrases F   簡→繁 片語對照表(優先於字形,解決 里/裡、發/髮 等歧義)
//
// 設計重點:
//   - 詞 ID 以 UInt32 表示,bigram key 打包成 UInt64 → 記憶體約為 String 版 1/4。
//   - 定期清除 count == 1 的配對(雜訊),避免記憶體無上限成長。
//   - 未登錄字以單字 token 參與;OOV 與 OOV 相鄰的配對不計。
//   - stdin 以串流方式讀入(支援 GB 級語料),不整份載入記憶體。

import Foundation

// MARK: - Trie

final class TrieNode {
    var children: [UInt32: TrieNode] = [:]
    var isWord = false
}

/// 片語對照的 trie(節點可帶對應值)
final class PhraseNode {
    var children: [UInt32: PhraseNode] = [:]
    var value: [Unicode.Scalar]? = nil
}

final class Vocab {
    var words: [String] = []
    var ids: [String: UInt32] = [:]
    var isOOV: [Bool] = []

    @discardableResult
    func intern(_ w: String, oov: Bool) -> UInt32 {
        if let id = ids[w] { return id }
        let id = UInt32(words.count)
        words.append(w)
        ids[w] = id
        isOOV.append(oov)
        return id
    }
}

// MARK: - 工具

func isHan(_ v: UInt32) -> Bool {
    (0x3400...0x4DBF).contains(v) || (0x4E00...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
}
func isLatinLetter(_ v: UInt32) -> Bool {
    (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
}
func isDigit(_ v: UInt32) -> Bool { (0x30...0x39).contains(v) }

func scalarString(_ v: UInt32) -> String {
    if let s = UnicodeScalar(v) { return String(s) }
    return "\u{0}"
}

// MARK: - 斷詞器

final class Segmenter {
    let root: TrieNode
    let vocab = Vocab()
    var maxLen: Int
    var oovMap: [UInt32: UInt32] = [:]
    /// 簡體 → 繁體 字形對照
    var s2t: [UInt32: Unicode.Scalar] = [:]
    /// 簡體 → 繁體 片語對照(trie)
    var phraseRoot: PhraseNode? = nil
    var phraseFirstChars: Set<UInt32> = []
    var maxPhraseLen = 1

    init(root: TrieNode, maxLen: Int) {
        self.root = root
        self.maxLen = maxLen
    }

    private func oovID(for v: UInt32) -> UInt32 {
        if let id = oovMap[v] { return id }
        let id = vocab.intern(scalarString(v), oov: true)
        oovMap[v] = id
        return id
    }

    private func knownID(_ slice: ArraySlice<Unicode.Scalar>) -> UInt32 {
        let word = String(String.UnicodeScalarView(slice))
        if let id = vocab.ids[word] { return id }
        return vocab.intern(word, oov: false)
    }

    /// 簡繁轉換:先套片語(最長匹配),再套字形
    func convert(_ slice: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(slice.count)
        var i = 0
        let n = slice.count
        while i < n {
            let c = slice[i]
            if phraseRoot != nil, phraseFirstChars.contains(c.value) {
                var node = phraseRoot
                var best: [Unicode.Scalar]? = nil
                var bestLen = 0
                var j = i
                while j < n, j - i < maxPhraseLen {
                    guard let next = node?.children[slice[j].value] else { break }
                    node = next
                    j += 1
                    if let v = node?.value {
                        best = v
                        bestLen = j - i
                    }
                }
                if let v = best {
                    out.append(contentsOf: v)
                    i += bestLen
                    continue
                }
            }
            if let m = s2t[c.value] {
                out.append(m)
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// 回傳 (tokenID, isOOV) 序列;標點與空白不產生 token(自然成為邊界)
    func segment(_ scalars: [Unicode.Scalar]) -> [(UInt32, Bool)] {
        var out: [(UInt32, Bool)] = []
        var i = 0
        let n = scalars.count
        while i < n {
            let v = scalars[i].value
            if isHan(v) {
                var node = root
                var bestEnd = -1
                var j = i
                while j < n && j - i < maxLen {
                    guard let next = node.children[scalars[j].value] else { break }
                    node = next
                    j += 1
                    if node.isWord { bestEnd = j }
                }
                if bestEnd > i {
                    out.append((knownID(scalars[i..<bestEnd]), false))
                    i = bestEnd
                } else {
                    out.append((oovID(for: v), true))
                    i += 1
                }
            } else if isLatinLetter(v) {
                var j = i
                while j < n && isLatinLetter(scalars[j].value) { j += 1 }
                let word = String(String.UnicodeScalarView(scalars[i..<j])).lowercased()
                out.append((vocab.intern(word, oov: false), false))
                i = j
            } else if isDigit(v) {
                var j = i
                while j < n && isDigit(scalars[j].value) { j += 1 }
                let word = String(String.UnicodeScalarView(scalars[i..<j]))
                out.append((vocab.intern(word, oov: false), false))
                i = j
            } else {
                i += 1
            }
        }
        return out
    }
}

// MARK: - 載入詞典與對照表

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: zhsegment <lexicon.tsv> [options]\n".data(using: .utf8)!)
    exit(2)
}
let lexiconPath = args[1]
let wordsOnly = args.contains("--words")
let wikiMode = args.contains("--wiki")
let byKey = args.contains("--by-key")
let keepOnes = args.contains("--keep-ones")
let segmentOnly = args.contains("--segment")
let s2tPath = args.firstIndex(of: "--s2t").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
let s2tPhrasesPath = args.firstIndex(of: "--s2t-phrases").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }

guard let lexiconData = FileManager.default.contents(atPath: lexiconPath) else {
    FileHandle.standardError.write("cannot read lexicon: \(lexiconPath)\n".data(using: .utf8)!)
    exit(2)
}

func loadCharMap(_ path: String) -> [UInt32: Unicode.Scalar] {
    var map: [UInt32: Unicode.Scalar] = [:]
    guard let data = FileManager.default.contents(atPath: path) else { return map }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let parts = line.split(separator: "\t", maxSplits: 1)
        if parts.count != 2 { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let val = parts[1].trimmingCharacters(in: .whitespaces)
        guard key.count == 1, val.count == 1,
              let k = key.unicodeScalars.first, let v = val.unicodeScalars.first else { continue }
        map[k.value] = v
    }
    return map
}

func loadPhraseMap(_ path: String) -> (PhraseNode, Set<UInt32>, Int) {
    let root = PhraseNode()
    var firsts: Set<UInt32> = []
    var maxLen = 1
    guard let data = FileManager.default.contents(atPath: path) else { return (root, firsts, maxLen) }
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let parts = line.split(separator: "\t", maxSplits: 1)
        if parts.count != 2 { continue }
        let key = parts[0].trimmingCharacters(in: .whitespaces)
        let val = parts[1].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !val.isEmpty else { continue }
        let keyScalars = Array(key.unicodeScalars)
        let valScalars = Array(val.unicodeScalars)
        var node = root
        for s in keyScalars {
            if let next = node.children[s.value] {
                node = next
            } else {
                let child = PhraseNode()
                node.children[s.value] = child
                node = child
            }
        }
        node.value = valScalars
        if let first = keyScalars.first {
            firsts.insert(first.value)
        }
        maxLen = max(maxLen, keyScalars.count)
    }
    return (root, firsts, maxLen)
}

func makeSegmenter() -> Segmenter {
    let root = TrieNode()
    var maxWordLen = 1
    let seg = Segmenter(root: root, maxLen: 1)
    for line in String(decoding: lexiconData, as: UTF8.self).split(separator: "\n") {
        guard let tab = line.firstIndex(of: "\t") else { continue }
        let word = String(line[line.startIndex..<tab])
        guard !word.isEmpty else { continue }
        let scalars = Array(word.unicodeScalars)
        var node = root
        for scalar in scalars {
            if let next = node.children[scalar.value] {
                node = next
            } else {
                let child = TrieNode()
                node.children[scalar.value] = child
                node = child
            }
        }
        node.isWord = true
        maxWordLen = max(maxWordLen, scalars.count)
        seg.vocab.intern(word, oov: false)
    }
    seg.maxLen = maxWordLen
    if let s2tPath {
        seg.s2t = loadCharMap(s2tPath)
    }
    if let s2tPhrasesPath {
        let (pRoot, firsts, pMax) = loadPhraseMap(s2tPhrasesPath)
        seg.phraseRoot = pRoot
        seg.phraseFirstChars = firsts
        seg.maxPhraseLen = pMax
    }
    return seg
}

let segmenter = makeSegmenter()

// MARK: - 段落式斷詞(除錯 / 評估用)

if segmentOnly {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    for line in text.split(separator: "\n") {
        let scalars = segmenter.convert(Array(line.unicodeScalars))
        var tokens: [String] = []
        var i = 0
        while i < scalars.count {
            if isHan(scalars[i].value) {
                var j = i
                while j < scalars.count && isHan(scalars[j].value) { j += 1 }
                for tok in segmenter.segment(Array(scalars[i..<j])) {
                    tokens.append(segmenter.vocab.words[Int(tok.0)])
                }
                i = j
            } else if isLatinLetter(scalars[i].value) || isDigit(scalars[i].value) {
                var j = i
                while j < scalars.count && (isLatinLetter(scalars[j].value) || isDigit(scalars[j].value)) { j += 1 }
                tokens.append(String(String.UnicodeScalarView(scalars[i..<j])).lowercased())
                i = j
            } else {
                i += 1
            }
        }
        print(tokens.joined(separator: "/"))
    }
    exit(0)
}

// MARK: - 統計

var counts: [UInt64: Int32] = [:]
counts.reserveCapacity(1 << 22)
var unigrams: [UInt32: Int32] = [:]
var totalTokens: Int64 = 0
var totalChars: Int64 = 0
var totalSentences: Int64 = 0
var sincePrune: Int64 = 0

func pruneRare() {
    counts = counts.filter { $0.value > 1 }
    sincePrune = 0
}

/// 處理一段文字:以 CJK 連續 run 作為「句」(標點天然成為邊界),再斷詞、計 bigram
func process(text: String) {
    let raw = Array(text.unicodeScalars)
    var i = 0
    while i < raw.count {
        if isHan(raw[i].value) {
            var j = i
            while j < raw.count && isHan(raw[j].value) { j += 1 }
            if j - i >= 2 {
                let converted = segmenter.convert(Array(raw[i..<j]))
                let tokens = segmenter.segment(converted)
                if tokens.count >= 2 {
                    totalSentences += 1
                    for (idx, tok) in tokens.enumerated() {
                        unigrams[tok.0, default: 0] += 1
                        totalTokens += 1
                        guard idx > 0 else { continue }
                        let prev = tokens[idx - 1]
                        if prev.1 && tok.1 { continue }
                        let key = (UInt64(prev.0) << 32) | UInt64(tok.0)
                        counts[key, default: 0] += 1
                    }
                    sincePrune += Int64(tokens.count)
                    if sincePrune > 20_000_000 { pruneRare() }
                }
            }
            i = j
        } else {
            i += 1
        }
    }
    totalChars += Int64(raw.count)
}

/// MediaWiki XML:僅取 <text ...> ... </text> 內文,略過標記與其他元素
func processWiki(text: String) {
    var searchStart = text.startIndex
    while true {
        guard let openRange = text.range(of: "<text", range: searchStart..<text.endIndex) else { break }
        guard let gt = text[openRange.upperBound...].firstIndex(of: ">") else { break }
        let contentStart = text.index(after: gt)
        guard let closeRange = text.range(of: "</text>", range: contentStart..<text.endIndex) else { break }
        process(text: String(text[contentStart..<closeRange.lowerBound]))
        searchStart = closeRange.upperBound
    }
}

// MARK: - 串流讀取 stdin

var pending = ""
let chunkSize = 4 << 20
while true {
    let chunk = FileHandle.standardInput.readData(ofLength: chunkSize)
    if chunk.isEmpty { break }
    pending += String(decoding: chunk, as: UTF8.self)
    // 保留尾端可能不完整的 UTF-8 字元
    if pending.utf8.count > 4 {
        let cut = pending.utf8.index(pending.utf8.startIndex, offsetBy: pending.utf8.count - 4)
        var boundary = cut
        while boundary < pending.endIndex {
            let c = pending[boundary]
            if c.unicodeScalars.count == 1 { break }
            boundary = pending.index(after: boundary)
        }
        let head = String(pending[pending.startIndex..<boundary])
        pending = String(pending[boundary...])
        if !head.isEmpty { wikiMode ? processWiki(text: head) : process(text: head) }
    }
}
if !pending.isEmpty { wikiMode ? processWiki(text: pending) : process(text: pending) }

// MARK: - 輸出

if !keepOnes { pruneRare() }   // 清除 count == 1 的配對(雜訊)

if wordsOnly {
    var out = ""
    for (id, c) in unigrams.sorted(by: { $0.value > $1.value }) where c > 0 {
        out += "\(segmenter.vocab.words[Int(id)])\t\(c)\n"
    }
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
} else {
    // --by-key:依「前詞、後詞」的 UTF-8 位元組序排序(與 Python 的 str 序一致,供外部合併)
    let sorted = byKey
        ? counts.sorted { lhs, rhs in
            let a = segmenter.vocab.words[Int(lhs.key >> 32)]
            let b = segmenter.vocab.words[Int(rhs.key >> 32)]
            let cmp = a.utf8.lexicographicallyPrecedes(b.utf8)
            if cmp != (b.utf8.lexicographicallyPrecedes(a.utf8)) { return cmp }
            let c = segmenter.vocab.words[Int(lhs.key & 0xFFFFFFFF)]
            let d = segmenter.vocab.words[Int(rhs.key & 0xFFFFFFFF)]
            return c.utf8.lexicographicallyPrecedes(d.utf8)
        }
        : counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
    var out = ""
    out.reserveCapacity(sorted.count * 24)
    for (key, count) in sorted {
        let a = Int(truncatingIfNeeded: key >> 32)
        let b = Int(truncatingIfNeeded: key & 0xFFFFFFFF)
        out += "\(segmenter.vocab.words[a])\t\(segmenter.vocab.words[b])\t\(count)\n"
    }
    FileHandle.standardOutput.write(out.data(using: .utf8)!)
}

let stats = """
chars\t\(totalChars)
sentences\t\(totalSentences)
tokens\t\(totalTokens)
unigrams\t\(unigrams.count)
bigrams\t\(counts.count)
"""
FileHandle.standardError.write(stats.data(using: .utf8)!)
