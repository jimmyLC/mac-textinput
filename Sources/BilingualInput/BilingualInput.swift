import Cocoa

enum BilingualAction {
    case passThrough                          // let the IME handle the key as usual
    case literal                              // insert the key as plain text, bypassing the IME
    case commitComposingThenLiteral           // commit current composition, then insert the key
    case beginEnglish(String)                 // commit composition (dropping the Zhuyin reading), then insert this text
    case insert(String)                       // insert this text (completion suffix)
    case acceptOffer(String)                  // commit composition, then insert the offered English word
}

/// Decides, key by key, whether typing has turned into English. Once a run is English its
/// letters are typed literally until a space. McBopomofo keeps converted Chinese in the
/// underlined composing buffer until Enter, so English always commits that text first.
/// Typed text is never logged or stored.
final class BilingualInput {
    static let shared = BilingualInput()

    private let lock = NSLock()
    private var analyzer: BilingualAnalyzer?
    private var baseWords: [String] = []
    private var zhuyinIndex: ZhuyinSyllableIndex?
    private var buffer = ""            // keys typed since the composition started
    private var englishRun = false     // inside an English word: letters are literal
    private var runWord = ""           // lowercase letters of the current English word
    private var previousRunEnglish = false
    private var englishMode = false    // persistent mode (Caps Lock or Shift tap)
    private var shiftDown = false
    private var shiftClean = false
    var tooltipShown = false
    /// Label to show next to the cursor after the last event (mode changes).
    var modeLabel: String?

    private static let runCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-:/@?=&%#+~'")
    private static let urlSchemes: Set<String> = ["http", "https", "ftp", "file", "ssh", "git", "mailto"]

    private init() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.load() }
    }

    private func load() {
        guard let res = Bundle.main.resourceURL,
              let en = try? String(contentsOf: res.appendingPathComponent("english-words.txt"), encoding: .utf8),
              let zh = try? String(contentsOf: res.appendingPathComponent("chinese-lexicon.tsv"), encoding: .utf8)
        else { return }
        baseWords = en.split(separator: "\n").prefix(120_000).compactMap { $0.split(separator: "\t").first.map(String.init) }
        var readings: [String] = []
        var firstReading: [Character: String] = [:]
        for line in zh.split(separator: "\n") {
            let f = line.split(separator: "\t")
            guard f.count >= 3 else { continue }
            readings.append(String(f[2]))
            if f[0].count == 1, let ch = f[0].first, let r = f[2].split(separator: "|").first { firstReading[ch] = String(r) }
        }
        UserDictionary.shared.characterReadings = firstReading
        zhuyinIndex = ZhuyinSyllableIndex(readings: readings)
        reloadUserWords()
    }

    /// Rebuilds the English lexicon so words added to the personal dictionary take effect.
    func reloadUserWords() {
        DispatchQueue.global(qos: .utility).async { [self] in
            guard let zhuyin = zhuyinIndex else { return }
            install(analyzer: BilingualAnalyzer(
                lexicon: EnglishLexicon(words: baseWords, user: UserDictionary.shared.englishWords), zhuyin: zhuyin))
        }
    }

    /// Supplies the analyzer directly (used by tests instead of the bundled data files).
    func install(analyzer built: BilingualAnalyzer) { lock.lock(); analyzer = built; lock.unlock() }

    func reset() {
        buffer = ""; englishRun = false; runWord = ""; shiftDown = false; modeLabel = nil
    }

    /// The English word to offer right now: a completion of the word being typed, or an
    /// alternative reading of Zhuyin letters still pending in the composition.
    func currentCompletion(composing: Bool = false) -> String? {
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        if englishRun {
            guard runWord.count >= 2, let word = analyzer?.lexicon.completion(for: runWord, top: 20_000),
                  word.count > runWord.count else { return nil }
            return analyzer?.lexicon.display(word) ?? word
        }
        guard composing, let tail = letterTail(buffer), let offered = analyzer?.offer(for: tail) else { return nil }
        return analyzer?.lexicon.display(offered) ?? offered
    }

    private func startEnglish(_ ch: Character) {
        englishRun = true
        runWord = ch.isLetter ? String(ch).lowercased() : ""
        buffer = ""
    }

    private func decideModifiers(_ event: NSEvent, composing: Bool) -> BilingualAction {
        modeLabel = nil
        switch event.keyCode {
        case 57:  // Caps Lock: on = English mode
            englishMode = event.modifierFlags.contains(.capsLock)
            modeLabel = englishMode ? "English" : "中文"
            return .passThrough
        case 56, 60:  // Shift
            if event.modifierFlags.contains(.shift) {
                shiftDown = true; shiftClean = true
                return .passThrough
            }
            defer { shiftDown = false }
            guard shiftDown, shiftClean else { return .passThrough }
            if composing, !englishRun, let tail = letterTail(buffer), !tail.isEmpty {
                // Shift while Zhuyin letters are pending: they were English after all.
                startEnglish(tail.last!); runWord = tail
                buffer = ""
                return .beginEnglish(tail)
            }
            guard !composing, !englishRun else { return .passThrough }
            englishMode.toggle()
            modeLabel = englishMode ? "English" : "中文"
            return .passThrough
        default:
            return .passThrough
        }
    }

    private func letterTail(_ s: String) -> String? {
        let tail = String(s.reversed().prefix { $0.isASCII && $0.isLowercase }.reversed())
        return tail.isEmpty ? nil : tail
    }

    func decide(_ event: NSEvent, composing: Bool) -> BilingualAction {
        if event.type == .flagsChanged { return decideModifiers(event, composing: composing) }
        guard event.type == .keyDown else { return .passThrough }
        modeLabel = nil
        shiftClean = false
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            reset(); return .passThrough
        }
        if event.keyCode == 51 {  // delete
            if englishRun { if !runWord.isEmpty { runWord.removeLast() }; return .passThrough }
            if !buffer.isEmpty { buffer.removeLast() }
            return .passThrough
        }
        if event.keyCode == 48, let word = currentCompletion(composing: composing) {  // Tab accepts the offer
            if englishRun {
                let suffix = String(word.dropFirst(runWord.count))
                runWord = word.lowercased()
                return .insert(suffix)
            }
            englishRun = true; runWord = word.lowercased(); buffer = ""
            return .acceptOffer(word)
        }
        guard let chars = event.characters, chars.count == 1, let scalar = chars.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value < 0x7F else {
            reset(); return .passThrough  // return, escape, arrows, tab, non-ASCII input
        }
        let ch = chars.first!

        if englishRun {
            if Self.runCharacters.contains(ch) {
                if ch.isLetter { runWord.append(Character(ch.lowercased())) } else { runWord = "" }
                return .literal
            }
            englishRun = false; runWord = ""
            previousRunEnglish = true
            return ch == " " ? .literal : .passThrough
        }
        if englishMode { return composing ? .commitComposingThenLiteral : .literal }
        if !composing { buffer = "" }

        // A capital letter starts an English word.
        if ch.isASCII, ch.isUppercase {
            startEnglish(ch)
            return composing ? .commitComposingThenLiteral : .literal
        }
        // "https:" and friends: English for the rest of the token.
        if ch == ":", composing, Self.urlSchemes.contains(letterTail(buffer) ?? "") {
            let scheme = letterTail(buffer)!
            startEnglish(":")
            return .beginEnglish(scheme + ":")
        }
        if ch == " " {
            buffer = ""
            previousRunEnglish = false  // a Chinese run ended
            return .passThrough
        }
        buffer.append(ch)
        guard ch.isASCII, ch.isLowercase, let tail = letterTail(buffer) else { return .passThrough }
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        if analyzer?.startsEnglish(tail, previousRunEnglish: previousRunEnglish) == true {
            englishRun = true; runWord = tail; buffer = ""
            return .beginEnglish(tail)
        }
        return .passThrough
    }
}
