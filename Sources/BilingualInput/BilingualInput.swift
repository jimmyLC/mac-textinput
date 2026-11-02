import Cocoa

enum BilingualAction {
    case passThrough                          // let the IME handle the key as usual
    case literal                              // insert the key as plain text, bypassing the IME
    case commitComposingThenLiteral           // commit current composition, then insert the key
    case commit(String)                       // drop the composition; commit this text
    case replay(head: String, text: String)   // rebuild `head` as Zhuyin, commit it, then commit `text`
}

/// Tracks the raw keys of the current composition and decides, at a space, whether
/// the run was really English. Typed text is never logged or stored.
final class BilingualInput {
    static let shared = BilingualInput()

    private let lock = NSLock()
    private var analyzer: BilingualAnalyzer?
    private var buffer = ""
    private var englishRun = false
    private static let urlSchemes: Set<String> = ["http", "https", "ftp", "file", "ssh", "git", "mailto"]
    private static let runCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/@?=&%#+~'")

    private init() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.load() }
    }

    private func load() {
        guard let res = Bundle.main.resourceURL,
              let en = try? String(contentsOf: res.appendingPathComponent("english-words.txt"), encoding: .utf8),
              let zh = try? String(contentsOf: res.appendingPathComponent("chinese-lexicon.tsv"), encoding: .utf8)
        else { return }
        let words = en.split(separator: "\n").prefix(120_000).compactMap { $0.split(separator: "\t").first.map(String.init) }
        let readings = zh.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: "\t"); return f.count >= 3 ? String(f[2]) : nil
        }
        let built = BilingualAnalyzer(lexicon: EnglishLexicon(words: words),
                                      zhuyin: ZhuyinSyllableIndex(readings: readings))
        lock.lock(); analyzer = built; lock.unlock()
    }

    func reset() { buffer = ""; englishRun = false }

    func decide(_ event: NSEvent, composing: Bool) -> BilingualAction {
        guard event.type == .keyDown else { return .passThrough }
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            reset(); return .passThrough
        }
        if event.keyCode == 51 {  // delete
            if englishRun { return .passThrough }
            if !buffer.isEmpty { buffer.removeLast() }
            return .passThrough
        }
        guard let chars = event.characters, chars.count == 1, let scalar = chars.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value < 0x7F else {
            reset(); return .passThrough  // return, escape, arrows, tab, non-ASCII input
        }
        let ch = chars.first!

        if englishRun {
            if Self.runCharacters.contains(ch) { return .literal }
            englishRun = false
            if ch == " " { return .literal }
            return .passThrough
        }
        if !composing { buffer = "" }

        // A capital letter starts an English word: keep any composition, then type literally.
        if ch.isASCII, ch.isUppercase {
            buffer = ""; englishRun = true
            return composing ? .commitComposingThenLiteral : .literal
        }
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        // "https:" and friends: leave Zhuyin mode for the rest of the token.
        if ch == ":", composing, Self.urlSchemes.contains(buffer) {
            let text = buffer + ":"
            buffer = ""; englishRun = true
            return .commit(text)
        }
        guard ch == " " else {
            buffer.append(ch)
            return .passThrough
        }
        let body = buffer
        buffer = ""
        guard composing, !body.isEmpty, let analyzer = analyzer else { return .passThrough }
        if analyzer.classify(body + " ") == .english { return .commit(body + " ") }
        if let (head, tail) = analyzer.splitTrailingEnglish(body) { return .replay(head: head, text: tail + " ") }
        return .passThrough
    }
}

extension McBopomofoInputMethodController {
    /// Returns nil when the IME should handle the event as usual.
    func bilingualHandle(_ event: NSEvent, client: Any!) -> Bool? {
        switch BilingualInput.shared.decide(event, composing: state is InputState.Inputting) {
        case .passThrough:
            return nil
        case .literal:
            return false
        case .commitComposingThenLiteral:
            keyHandler.handleForceCommit(stateCallback: { self.handle(state: $0, client: client) })
            handle(state: InputState.Empty(), client: client)
            return false
        case .commit(let text):
            keyHandler.clear()
            handle(state: InputState.Committing(poppedText: text), client: client)
            handle(state: InputState.Empty(), client: client)
            return true
        case .replay(let head, let text):
            keyHandler.clear()
            handle(state: InputState.Empty(), client: client)
            for ch in head {
                guard let ascii = ch.asciiValue else { continue }
                let input = KeyHandlerInput(inputText: String(ch), keyCode: 0, charCode: UInt16(ascii),
                                            flags: [], isVerticalMode: false)
                _ = keyHandler.handle(input: input, state: state, stateCallback: { self.handle(state: $0, client: client) },
                                      errorCallback: {})
            }
            keyHandler.handleForceCommit(stateCallback: { self.handle(state: $0, client: client) })
            handle(state: InputState.Committing(poppedText: text), client: client)
            handle(state: InputState.Empty(), client: client)
            return true
        }
    }
}
