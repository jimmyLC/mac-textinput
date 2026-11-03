import Cocoa

/// Replays typed keys through BilingualInput with synthetic key events and a tiny model
/// of the IME's composing state. Output is what would reach the client as committed text
/// ("[Zh:...]" marks keys left to the Zhuyin engine).
@main
struct BilingualRoutingTests {
    static func event(_ ch: Character, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                         timestamp: 0, windowNumber: 0, context: nil, characters: String(ch),
                         charactersIgnoringModifiers: String(ch).lowercased(), isARepeat: false, keyCode: 0)!
    }
    static func key(_ code: UInt16, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    static func modifier(_ code: Int64, flags: CGEventFlags) -> NSEvent {
        let cg = CGEvent(source: nil)!
        cg.type = .flagsChanged
        cg.setIntegerValueField(.keyboardEventKeycode, value: code)
        cg.flags = flags
        return NSEvent(cgEvent: cg)!
    }

    /// Keys: normal characters, "\n" Return, "\u{8}" Backspace, "{shift}" a lone Shift tap,
    /// "{caps}" Caps Lock toggle. Returns what reached the client; "[Zh:..]" marks keys left
    /// to the Zhuyin engine (committed Chinese).
    static func run(_ keys: String, startPrevious english: Bool = false) -> String {
        let input = BilingualInput.shared
        input.reset()
        var out = ""
        var zh = ""
        var composing: Bool { !zh.isEmpty }
        var caps = false
        func flush() { if !zh.isEmpty { out += "[Zh:\(zh)]" }; zh = "" }
        var tokens: [String] = []
        var i = keys.startIndex
        while i < keys.endIndex {
            if keys[i] == "{", let close = keys[i...].firstIndex(of: "}") {
                tokens.append(String(keys[i...close])); i = keys.index(after: close)
            } else { tokens.append(String(keys[i])); i = keys.index(after: i) }
        }
        for token in tokens {
            if token == "{shift}" {
                _ = input.decide(modifier(56, flags: .maskShift), composing: composing)
                let action = input.decide(modifier(56, flags: []), composing: composing)
                if case .beginEnglish(let t) = action { zh = String(zh.dropLast(t.count)); flush(); out += t }
                continue
            }
            if token == "{caps}" {
                caps.toggle()
                _ = input.decide(modifier(57, flags: caps ? .maskAlphaShift : []), composing: composing)
                continue
            }
            let ch = token.first!
            let ev: NSEvent = ch == "\n" ? key(36, "\r") : ch == "\t" ? key(48, "\t") : ch == "\u{8}" ? key(51, "\u{7F}") : event(ch, shift: ch.isUppercase)
            switch input.decide(ev, composing: composing) {
            case .passThrough:
                if ch == "\u{8}" { if !zh.isEmpty { zh.removeLast() } }
                else if ch == " " || ch == "\n" { flush() }
                else { zh.append(ch) }
            case .literal:
                out.append(ch)
            case .commitComposingThenLiteral:
                flush(); out.append(ch)
            case .beginEnglish(let t):
                // The triggering key was consumed, so the engine holds only t.count - 1 of the letters.
                zh = String(zh.dropLast(max(t.count - 1, 0))); flush(); out += t
            case .insert(let t):
                out += t
            case .repair:
                break
            case .replaceTyped(let old, let new):
                if out.hasSuffix(old) { out = String(out.dropLast(old.count)) + new }
            case .acceptOffer(let word):
                let tail = String(zh.reversed().prefix { $0.isLowercase && $0.isASCII }.reversed())
                zh = String(zh.dropLast(tail.count)); flush(); out += word
            }
        }
        flush()
        return out
    }

    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        func lines(_ path: String) throws -> [Substring] {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8).split(separator: "\n")
        }
        let readings = try lines("data/chinese-lexicon.tsv").compactMap { l -> String? in
            let f = l.split(separator: "\t"); return f.count >= 3 ? String(f[2]) : nil }
        let words = try lines("data/english-words.txt").prefix(120_000).compactMap { $0.split(separator: "\t").first.map(String.init) }
        BilingualInput.shared.install(analyzer: BilingualAnalyzer(
            lexicon: EnglishLexicon(words: words), zhuyin: ZhuyinSyllableIndex(readings: readings)))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("zlm-route-\(UUID().uuidString)")
        DebugLog.shared = DebugLog(file: tmp.appendingPathComponent("dbg.txt"), defaults: UserDefaults(suiteName: "zlm-route-\(UUID().uuidString)")!)
        DebugLog.shared.enabled = true
        UserDictionary.shared = UserDictionary(file: tmp.appendingPathComponent("ud.json"))
        LearningStore.shared = LearningStore(file: tmp.appendingPathComponent("l.json"))
        var failures = 0
        func check(_ keys: String, _ expected: String) {
            let actual = run(keys)
            if actual != expected { failures += 1; print("FAIL \(keys.debugDescription): expected \(expected.debugDescription), got \(actual.debugDescription)") }
        }
        check("hello ", "hello ")                       // English: "he" is a word that is not Zhuyin
        check("run ", "run ")                           // 3+ letters beat toneless Zhuyin
        check("su3cl3 ", "[Zh:su3cl3]")                 // Chinese stays with the Zhuyin engine
        check("up ", "[Zh:up]")                         // 因 (ㄧㄣ): a 2-letter word must not win
        check("hello{shift}su3 ", "hello[Zh:su3]")      // Shift tap ends the English word and returns to Chinese
        check("hello su3 up ", "hello [Zh:su3][Zh:up]") // a finished Chinese syllable resets the English context
        // A key that begins an English run is flagged once, so the controller can add the space.
        input0: do {
            let i = BilingualInput.shared
            i.reset()
            _ = i.decide(event("H", shift: true), composing: true)
            if !i.takeRunStart() || i.takeRunStart() { failures += 1; print("FAIL run-start flag") }
            _ = i.decide(event("i"), composing: false)
            if i.takeRunStart() { failures += 1; print("FAIL run-start flag set mid-word") }
        }
        check("su3cl3co ", "[Zh:su3cl3co]")            // 黑 (ㄏㄟ) after Chinese must not become "co"
        check("co ", "[Zh:co]")
        check("co3", "[Zh:co3]")
        check("hello up ", "hello up ")                 // ...but after English it is English
        check("su3cl3hello ", "[Zh:su3cl3]hello ")      // Chinese then English; Chinese is kept
        check("su3cl3 hello ", "[Zh:su3cl3]hello ")     // Chinese already in the underlined buffer
        check("su3cl3 buy ", "[Zh:su3cl3]buy ")         // the reported "BUY" case, lowercase
        check("su3cl3 BUY ", "[Zh:su3cl3]BUY ")         // ...and uppercase
        check("su3cl3Mac ", "[Zh:su3cl3]Mac ")
        check("Mac ", "Mac ")
        check("https://example.com ", "https://example.com ")
        check("wu0wu0 ", "[Zh:wu0wu0]")                 // toneless Chinese phrase
        check("su3x\u{8}cl3 ", "[Zh:su3cl3]")           // backspace removes the last key
        check("{caps}hello su3{caps}su3 ", "hello su3[Zh:su3]")   // Caps Lock = English mode
        check("{shift}hello su3{shift}su3 ", "hello su3[Zh:su3]") // Shift tap toggles when idle
        check("sucl{shift}", "sucl")                    // Shift while letters pending: they were English
        // Offer beside pending Zhuyin; Tab keeps the Chinese and takes the English word.
        BilingualInput.shared.reset()
        for ch in "su3cl3" { _ = BilingualInput.shared.decide(event(ch), composing: true) }
        for ch in "dat" { _ = BilingualInput.shared.decide(event(ch), composing: true) }
        let offered = BilingualInput.shared.currentCompletion(composing: true)
        precondition(offered?.hasPrefix("dat") == true, "no offer for dat: \(offered ?? "nil")")
        check("su3cl3dat\t", "[Zh:su3cl3]" + (offered ?? "?"))
        // Completion offer for the English word being typed.
        let input = BilingualInput.shared
        input.reset()
        for ch in "fun" { _ = input.decide(event(ch), composing: ch != "f") }
        precondition(input.currentCompletion().map { $0.count > 3 } == true, "no completion for fun")
        if case .insert(let suffix) = input.decide(key(48, "\t"), composing: false) {
            precondition(!suffix.isEmpty)
        } else { failures += 1; print("FAIL Tab completion") }
        // Tone repair: a frequent 2-char phrase typed with one wrong tone key is offered a fix on Tab.
        let engine = PhraseRepair(lines: try lines("data/chinese-lexicon.tsv"))
        input.install(repair: engine)
        var fixed = 0
        for line in try lines("data/chinese-lexicon.tsv").prefix(3000) {
            let f = line.split(separator: "\t")
            guard f.count >= 3, f[0].count == 2, let r = f[2].split(separator: "|").first else { continue }
            let syl = r.split(separator: "-").map(String.init)
            guard syl.count == 2, let tone = PhraseRepair.tone(syl[1]), tone != "˙" else { continue }
            let wrongTone: Character = tone == "ˊ" ? "ˇ" : "ˊ"
            var typed = syl; typed[1] = PhraseRepair.stripTone(syl[1]) + String(wrongTone)
            guard let want = engine.suggest(typed), want.readings == syl else { continue }
            input.reset()
            for syllable in typed {
                for ch in PhraseRepair.keys(for: syllable) { _ = input.decide(event(ch), composing: true) }
            }
            guard case .repair(let n, let keys) = input.decide(key(48, "\t"), composing: true) else {
                failures += 1; print("FAIL no repair for \(f[0])"); break
            }
            if n != 2 || keys != syl.map(PhraseRepair.keys(for:)).joined() { failures += 1; print("FAIL repair keys for \(f[0]): \(n) \(keys)") }
            fixed += 1
            if fixed == 20 { break }
        }
        if fixed == 0 { failures += 1; print("FAIL no tone repair case found") }
        // A correctly typed phrase gets no offer.
        input.reset()
        for ch in "su3cl3" { _ = input.decide(event(ch), composing: true) }
        if input.currentRepair(composing: true) != nil { failures += 1; print("FAIL repair offered for 你好") }
        // Spelling: an unknown English word gets a one-edit correction offered; Tab swaps it.
        check("{caps}the wrold \t{caps}", "the world ")
        check("{caps}the wrold x{caps}", "the wrold x")        // any other key drops the offer
        check("{caps}the world \t{caps}", "the world [Zh:\t]")  // a real word gets no offer
        check("Wrold \t", "World ")                     // capitalisation kept
        // Learning: an uncommon English word typed three times joins the dictionary.
        for _ in 0..<3 { _ = run("Wibblesnork ") }
        if !UserDictionary.shared.englishWords.contains("wibblesnork") { failures += 1; print("FAIL English word not learned: \(UserDictionary.shared.englishWords)") }
        _ = run("hello hello hello ")
        if UserDictionary.shared.englishWords.contains("hello") { failures += 1; print("FAIL common word learned") }
        DebugLog.shared.flush()
        let logged = (try? String(contentsOf: tmp.appendingPathComponent("dbg.txt"), encoding: .utf8)) ?? ""
        if !logged.contains("key=c ") || !logged.contains("-> ") { failures += 1; print("FAIL debug log empty") }
        try? FileManager.default.removeItem(at: tmp)
        if failures > 0 { print("\(failures) routing failure(s)"); exit(1) }
        print("Bilingual routing: key replay cases passed")
    }
}
