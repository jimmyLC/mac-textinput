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

    static func run(_ keys: String) -> String {
        let input = BilingualInput.shared
        input.reset()
        var out = ""
        var composing = false
        var zh = ""          // keys the Zhuyin engine is holding
        for ch in keys {
            let ev = ch == "\n" ? key(36, "\r") : event(ch, shift: ch.isUppercase)
            switch input.decide(ev, composing: composing) {
            case .passThrough:
                if ch == " " || ch == "\n" { if !zh.isEmpty { out += "[Zh:\(zh)]" }; zh = ""; composing = false }
                else { zh.append(ch); composing = true }
            case .literal:
                out.append(ch)
            case .commitComposingThenLiteral:
                if !zh.isEmpty { out += "[Zh:\(zh)]" }; zh = ""; composing = false; out.append(ch)
            case .commit(let t):
                out += t; zh = ""; composing = false
            case .replay(let head, let t):
                out += "[Zh:\(head)]" + t; zh = ""; composing = false
            case .toggled: break
            }
        }
        if !zh.isEmpty { out += "[Zh:\(zh)]" }
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

        var failures = 0
        func check(_ keys: String, _ expected: String) {
            let actual = run(keys)
            if actual != expected { failures += 1; print("FAIL \(keys.debugDescription): expected \(expected.debugDescription), got \(actual.debugDescription)") }
        }
        check("hello ", "hello ")                       // English, committed raw
        check("run ", "run ")                           // also valid toneless Zhuyin
        check("su3cl3 ", "[Zh:su3cl3]")                 // Chinese stays with the Zhuyin engine
        check("su3cl3hello ", "[Zh:su3cl3]hello ")      // Chinese then English
        check("su3cl3Mac ", "[Zh:su3cl3]Mac ")          // capitals: commit composition, then literal
        check("Mac ", "Mac ")
        check("https://example.com ", "https://example.com ")
        check("hello\n", "hello")                       // Return commits displayed English
        check("wu0wu0 ", "[Zh:wu0wu0]")                 // toneless Chinese phrase
        check("hel ", "hel ")                           // typo-prefix commits as typed English
        // Backspace removes the last key from the run.
        let input = BilingualInput.shared
        input.reset()
        var c = true
        for ch in "helx" { _ = input.decide(event(ch), composing: c) }
        _ = input.decide(key(51, "\u{7F}"), composing: c)
        c = true
        if case .commit(let t) = input.decide(event(" "), composing: c) { precondition(t == "hel ", t) } else { failures += 1; print("FAIL backspace") }
        if failures > 0 { print("\(failures) routing failure(s)"); exit(1) }
        print("Bilingual routing: key replay cases passed")
    }
}
