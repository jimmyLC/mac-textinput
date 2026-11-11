import Cocoa

@main struct BilingualRecoveryTests {
    static func key(_ text: String, code: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: 0, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let rows = try String(contentsOf: root.appendingPathComponent("data/chinese-lexicon.tsv"), encoding: .utf8)
            .split(separator: "\n")
        let readings = rows.compactMap { row -> String? in
            let fields = row.split(separator: "\t"); return fields.count >= 3 ? String(fields[2]) : nil
        }
        let words = try String(contentsOf: root.appendingPathComponent("data/english-words.txt"), encoding: .utf8)
            .split(separator: "\n").compactMap { $0.split(separator: "\t").first.map(String.init) }
        let index = ZhuyinSyllableIndex(readings: readings)
        let router = BilingualInput.shared
        router.install(analyzer: BilingualAnalyzer(lexicon: EnglishLexicon(words: words), zhuyin: index))
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zlm-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let suiteName = "zlm-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        DebugLog.shared = DebugLog(file: tmp.appendingPathComponent("debug.txt"), defaults: defaults)
        UserDictionary.shared = UserDictionary(file: tmp.appendingPathComponent("dictionary.json"))
        LearningStore.shared = LearningStore(file: tmp.appendingPathComponent("learning.json"))
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }
        // Handwritten regression keys only. Never import a user's typing log into tests.
        for sequence in ["sup6", "sul3", "ful6", "ful3dk4xu4", "url4", "us4", "uru4", "sai4", "jpg4"] {
            router.reset()
            for (i, ch) in sequence.enumerated() {
                if case .passThrough = router.decide(key(String(ch)), composing: i > 0) {} else {
                    check(false, "Chinese keys \(sequence) switched to English before their tone"); break
                }
            }
        }
        // Check the online router, not just the offline parser, on real toned Chinese.
        var chineseCases = 0
        for row in rows.prefix(5000) {
            let fields = row.split(separator: "\t")
            guard fields.count >= 3, let reading = fields[2].split(separator: "|").first else { continue }
            let sequence = reading.split(separator: "-").map { PhraseRepair.keys(for: String($0)) }.joined()
            router.reset()
            var stayedChinese = true
            for (i, ch) in sequence.enumerated() {
                if case .passThrough = router.decide(key(String(ch)), composing: i > 0) {} else {
                    stayedChinese = false; break
                }
            }
            check(stayedChinese, "online Chinese reading changed language: \(fields[0])")
            chineseCases += 1
        }
        check(chineseCases == 5000, "expected 5000 online Chinese regression cases")
        // A two-letter word is ambiguous in a fresh Chinese context.
        router.reset()
        _ = router.decide(key("a"), composing: false)
        if case .passThrough = router.decide(key("n"), composing: true) {} else {
            check(false, "two-letter word prematurely committed")
        }
        // An explicit capital starts a run; deleting it all must restore Chinese routing.
        router.reset()
        _ = router.decide(key("A"), composing: false)
        _ = router.decide(key("n"), composing: false)
        _ = router.decide(key("\u{7F}", code: 51), composing: false)
        _ = router.decide(key("\u{7F}", code: 51), composing: false)
        if case .passThrough = router.decide(key("s"), composing: false) {} else {
            check(false, "empty English run still routes Chinese literally")
        }
        router.reset()
        for (i, ch) in "hello".enumerated() { _ = router.decide(key(String(ch)), composing: i > 0) }
        for _ in 0..<5 { _ = router.decide(key("\u{7F}", code: 51), composing: false) }
        if case .passThrough = router.decide(key("s"), composing: false) {} else {
            check(false, "deleting auto-detected English did not restore Chinese")
        }
        router.reset(capsLock: true)
        _ = router.decide(key("a"), composing: false)
        _ = router.decide(key("\u{7F}", code: 51), composing: false)
        if case .literal = router.decide(key("s"), composing: false) {} else {
            check(false, "deleting a word unexpectedly left explicit English mode")
        }
        // Punctuation and URL characters are part of the run too, not just its last word.
        router.reset()
        for ch in "A.b" { _ = router.decide(key(String(ch)), composing: false) }
        for _ in 0..<3 { _ = router.decide(key("\u{7F}", code: 51), composing: false) }
        if case .passThrough = router.decide(key("s"), composing: false) {} else {
            check(false, "deleted punctuation run still routes literally")
        }
        router.reset()
        for ch in "Wrold " { _ = router.decide(key(String(ch)), composing: false) }
        check(router.currentSpellFix != nil, "spelling fixture did not produce an offer")
        router.reset()
        check(router.currentSpellFix == nil, "spelling offer leaked across clients")
        if case .passThrough = router.decide(key("\t", code: 48), composing: false) {} else {
            check(false, "new client's Tab was consumed")
        }
        router.reset()
        for ch in "Hello " { _ = router.decide(key(String(ch)), composing: false) }
        router.reset()
        _ = router.decide(key("u"), composing: false)
        if case .passThrough = router.decide(key("p"), composing: true) {} else {
            check(false, "English context leaked across clients")
        }
        print(failures == 0 ? "Bilingual recovery: OK (\(chineseCases) online Chinese cases)" : "Bilingual recovery: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
