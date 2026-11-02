import Foundation

@main
struct BilingualAnalyzerTests {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        func lines(_ path: String) throws -> [Substring] {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n")
        }
        let readings = try lines("data/chinese-lexicon.tsv").compactMap { line -> String? in
            let f = line.split(separator: "\t"); return f.count >= 3 ? String(f[2]) : nil
        }
        let words = try lines("data/english-words.txt").prefix(120_000).compactMap { $0.split(separator: "\t").first.map(String.init) }
        let analyzer = BilingualAnalyzer(
            lexicon: EnglishLexicon(words: words),
            zhuyin: ZhuyinSyllableIndex(readings: readings))
        let zhuyin = analyzer.zhuyin

        // Parser
        precondition(zhuyin.parse("su3") == .complete)
        precondition(zhuyin.parse("su3cl3") == .complete)
        precondition(zhuyin.parse("wu0wu0") == .complete)   // toneless syllables
        precondition(zhuyin.parse("su") == .complete)
        precondition(zhuyin.parse("c") == .prefix)          // ㄏ alone: still being typed
        precondition(zhuyin.parse("hello") == .invalid)
        precondition(zhuyin.parse("Mac") == .invalid)
        precondition(zhuyin.parse("") == .invalid)

        func kinds(_ raw: String) -> [SegmentKind] { analyzer.analyze(raw).map(\.kind) }
        // Fixture cases (tests/fixtures/bilingual-cases.json)
        precondition(kinds("su3cl3 ") == [.chinese])
        precondition(kinds("hello ") == [.english])
        precondition(kinds("Mac ") == [.english])
        precondition(kinds("su3cl3Mac ") == [.chinese, .english])
        precondition(kinds("https://example.com ") == [.english])
        // Not yet at a boundary: never decided early.
        precondition(kinds("hello") == [.undecided])
        precondition(kinds("su3cl3") == [.undecided])
        // Raw keys are never lost, whatever the classification.
        for raw in ["su3cl3Mac ", "hello world ", "zxcv!@# ", "  ", "a", "Mac3Mac "] {
            precondition(analyzer.analyze(raw).map(\.keys).joined() == raw, "lost keys in \(raw)")
        }
        // Words that also parse as toneless Zhuyin resolve to English, as other bilingual IMEs do.
        for w in ["run ", "fun ", "sun ", "no ", "so ", "go "] { precondition(kinds(w) == [.english], w) }
        precondition(kinds("i ") == [.undecided])  // single letters stay ambiguous
        // Trailing English after explicitly toned Zhuyin.
        let split = analyzer.splitTrailingEnglish("su3cl3hello")
        precondition(split?.head == "su3cl3" && split?.tail == "hello")
        precondition(analyzer.splitTrailingEnglish("hello") == nil)
        precondition(analyzer.splitTrailingEnglish("su3cl3") == nil)
        // Coverage on real data. English side: top words that parse as Zhuyin (false "Chinese").
        let topEnglish = words.prefix(20_000).filter { $0.count >= 3 }
        let englishAsZhuyin = topEnglish.filter { zhuyin.parse($0) == .complete }
        // Chinese side: lexicon readings typed with tones (first reading of top words) must parse.
        let inverse = Dictionary(uniqueKeysWithValues: ZhuyinKeyboard.keyMap.filter { $0.key != " " }.map { ($0.value, $0.key) })
        var typed = 0, parsed = 0
        for field in readings.prefix(5_000) {
            guard let reading = field.split(separator: "|").first else { continue }
            let keys = String(reading.filter { $0 != "-" }.compactMap { inverse[$0] })
            typed += 1
            if zhuyin.parse(keys) == .complete { parsed += 1 }
        }
        print("English words (len>=3, top 20k) that also parse as Zhuyin (now resolved to English): \(englishAsZhuyin.count)/\(topEnglish.count), e.g. \(englishAsZhuyin.prefix(8))")
        print("Top-5000 Chinese readings typed with tones that parse as Zhuyin: \(parsed)/\(typed)")
        precondition(Double(parsed) / Double(typed) > 0.99, "Zhuyin recall too low")
        print("Bilingual analyzer: parser, fixtures and key preservation passed")
    }
}
