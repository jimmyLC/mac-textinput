import Cocoa

enum BilingualAction {
    case passThrough                          // let the IME handle the key as usual
    case literal                              // insert the key as plain text, bypassing the IME
    case commitComposingThenLiteral           // commit current composition, then insert the key
    case beginEnglish(String)                 // commit composition (dropping the Zhuyin reading), then insert this text
    case insert(String)                       // insert this text (completion suffix)
    case acceptOffer(String)                  // commit composition, then insert the offered English word
    case replaceTyped(old: String, new: String) // swap the just-typed word (with its space) for the corrected one
    case repair(backspaces: Int, keys: String) // delete the last syllables, then retype them with corrected tones
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
    private var repairEngine: PhraseRepair?
    private var pending = ""           // Zhuyin keys of the syllable being typed
    private var done: [String] = []    // finished syllables of this composition, keys incl. tone key
    private var buffer = ""            // keys typed since the composition started
    private var englishRun = false     // inside an English word: letters are literal
    private var runPure = false        // the run so far is letters only (a whole word)
    private var repairOffering = false // a tone fix is currently offered
    private var runWord = ""           // lowercase letters of the current English word
    private var runTyped = ""          // the same letters as typed (capitalisation kept)
    private var spellFix: (old: String, new: String)?   // correction offered for the word just finished
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
        repairEngine = PhraseRepair(lines: zh.split(separator: "\n"))
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
    func install(repair engine: PhraseRepair) { repairEngine = engine }

    func reset() {
        buffer = ""; englishRun = false; runWord = ""; shiftDown = false; modeLabel = nil
        pending = ""; done = []
    }

    /// Follows the Zhuyin syllables typed so far so a wrong tone can be offered a fix.
    private func track(_ ch: Character) {
        if "3467 ".contains(ch) {
            if pending.isEmpty { done = [] } else {
                done.append(pending + String(ch)); pending = ""
                if done.count > 8 { done.removeFirst() }
            }
        } else if ZhuyinKeyboard.keyMap[ch] != nil {
            pending.append(ch)
        } else { pending = ""; done = [] }
    }

    /// Tone fix for the last syllables, when they form no phrase but one tone change does.
    func currentRepair(composing: Bool) -> (word: String, backspaces: Int, keys: String)? {
        guard composing, !englishRun, pending.isEmpty, done.count >= 2, let engine = repairEngine else { return nil }
        for n in stride(from: min(5, done.count), through: 2, by: -1) {
            let typed = done.suffix(n).compactMap { PhraseRepair.syllable(fromKeys: $0) }
            guard typed.count == n, let fix = engine.suggest(typed) else { continue }
            return (fix.word, n, fix.readings.map { PhraseRepair.keys(for: $0) }.joined())
        }
        return nil
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
        pending = ""; done = []
        englishRun = true
        runPure = ch.isLetter
        runWord = ch.isLetter ? String(ch).lowercased() : ""
        runTyped = ch.isLetter ? String(ch) : ""
        buffer = ""
    }

    private func decideModifiers(_ event: NSEvent, composing: Bool) -> BilingualAction {
        modeLabel = nil
        switch event.keyCode {
        case 57:  // Caps Lock: on = English mode
            englishMode = event.modifierFlags.contains(.capsLock)
            englishRun = false; runWord = ""; runTyped = ""   // the mode decides again from here
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
                startEnglish(tail.last!); runWord = tail; runTyped = tail
                buffer = ""
                return .beginEnglish(tail)
            }
            guard !composing, !englishRun || englishMode else { return .passThrough }
            englishMode.toggle()
            englishRun = false; runWord = ""; runTyped = ""
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

    private func logDecision(_ event: NSEvent, composing: Bool, action: BilingualAction) {
        guard DebugLog.shared.enabled else { return }
        let key: String
        if event.type == .flagsChanged { key = "mod\(event.keyCode)" }
        else if let c = event.characters, c.count == 1, let s = c.unicodeScalars.first, s.value >= 0x21, s.value < 0x7F { key = c }
        else { key = "code\(event.keyCode)" }
        let act: String
        switch action {
        case .passThrough: act = "pass"
        case .literal: act = "literal"
        case .commitComposingThenLiteral: act = "commit+literal"
        case .beginEnglish(let t): act = "beginEnglish(\(t))"
        case .insert(let t): act = "insert(\(t))"
        case .acceptOffer(let w): act = "acceptOffer(\(w))"
        case .replaceTyped(let o, let n): act = "replace(\(o.trimmingCharacters(in: .whitespaces))>\(n.trimmingCharacters(in: .whitespaces)))"
        case .repair(let b, let k): act = "repair(\(b),\(k))"
        }
        DebugLog.shared.record("key=\(key) composing=\(composing) run=\(englishRun) mode=\(englishMode ? "en" : "zh") prevEn=\(previousRunEnglish) -> \(act)" + (modeLabel.map { " label=\($0)" } ?? ""))
    }

    /// Counts a finished uncommon English word; a word seen often enough joins the dictionary.
    /// After a finished, unknown English word, remember a one-edit correction to offer.
    private func offerSpellFix() {
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        guard runPure, let lexicon = analyzer?.lexicon, let fix = lexicon.correction(for: runWord),
              !UserDictionary.shared.englishWords.contains(where: { $0.lowercased() == runWord }) else { return }
        let new: String
        if runTyped.count > 1, runTyped == runTyped.uppercased() { new = fix.uppercased() }
        else if runTyped.first?.isUppercase == true { new = fix.prefix(1).uppercased() + fix.dropFirst() }
        else { new = fix }
        spellFix = (runTyped + " ", new + " ")
    }

    /// Correction offered for the word just typed (cleared by the next key).
    var currentSpellFix: (old: String, new: String)? { spellFix }

    private func learnEnglish(_ word: String) {
        guard runPure, word.count >= 3 else { return }
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        guard let lexicon = analyzer?.lexicon, !lexicon.isCommon(word, top: 20_000),
              lexicon.correction(for: word) == nil,   // probably a typo, not a new word
              !UserDictionary.shared.englishWords.contains(where: { $0.lowercased() == word }) else { return }
        if LearningStore.shared.recordEnglish(word),
           (try? UserDictionary.shared.add(word: word, reading: nil, auto: true)) != nil {
            reloadUserWords()
        }
    }

    func decide(_ event: NSEvent, composing: Bool) -> BilingualAction {
        let wasOffering = repairOffering
        let action = decideKey(event, composing: composing)
        logDecision(event, composing: composing, action: action)
        guard event.type == .keyDown else { return action }
        if case .repair = action {
            LearningStore.shared.recordRepairAccepted()
            repairOffering = false
            return action
        }
        repairEngine?.margin = LearningStore.shared.repairMargin
        let offering = currentRepair(composing: true) != nil
        if offering && !wasOffering { LearningStore.shared.recordRepairShown() }
        repairOffering = offering
        return action
    }

    private func decideKey(_ event: NSEvent, composing: Bool) -> BilingualAction {
        if event.type == .flagsChanged { return decideModifiers(event, composing: composing) }
        guard event.type == .keyDown else { return .passThrough }
        modeLabel = nil
        shiftClean = false
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            reset(); return .passThrough
        }
        let offeredFix = spellFix
        if event.type == .keyDown { spellFix = nil }
        if event.keyCode == 48, let fix = offeredFix, !englishRun {  // Tab applies the spelling fix
            return .replaceTyped(old: fix.old, new: fix.new)
        }
        if event.keyCode == 51 {  // delete
            if englishRun { if !runWord.isEmpty { runWord.removeLast(); runTyped.removeLast() }; return .passThrough }
            if !buffer.isEmpty { buffer.removeLast() }
            if !pending.isEmpty { pending.removeLast() } else if !done.isEmpty { done.removeLast() }
            return .passThrough
        }
        if event.keyCode == 48, let word = currentCompletion(composing: composing) {  // Tab accepts the offer
            if englishRun {
                let suffix = String(word.dropFirst(runWord.count))
                runWord = word.lowercased(); runTyped += suffix
                return .insert(suffix)
            }
            englishRun = true; runWord = word.lowercased(); runTyped = word; buffer = ""
            pending = ""; done = []
            return .acceptOffer(word)
        }
        if event.keyCode == 48, let fix = currentRepair(composing: composing) {  // Tab applies the tone fix
            return .repair(backspaces: fix.backspaces, keys: fix.keys)
        }
        guard let chars = event.characters, chars.count == 1, let scalar = chars.unicodeScalars.first,
              scalar.value >= 0x20, scalar.value < 0x7F else {
            reset(); return .passThrough  // return, escape, arrows, tab, non-ASCII input
        }
        let ch = chars.first!

        if englishRun {
            if Self.runCharacters.contains(ch) {
                if ch.isLetter { runWord.append(Character(ch.lowercased())); runTyped.append(ch) } else { runWord = ""; runTyped = ""; runPure = false }
                return .literal
            }
            learnEnglish(runWord)
            if ch == " " { offerSpellFix() }
            englishRun = false; runWord = ""
            previousRunEnglish = true
            return ch == " " ? .literal : .passThrough
        }
        if englishMode {
            if ch.isLetter { startEnglish(ch) }   // tracked as an English run: offers, spelling, learning
            return composing ? .commitComposingThenLiteral : .literal
        }
        if !composing { buffer = ""; pending = ""; done = [] }

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
            track(ch)
            buffer = ""
            previousRunEnglish = false  // a Chinese run ended
            return .passThrough
        }
        buffer.append(ch)
        track(ch)
        guard ch.isASCII, ch.isLowercase, let tail = letterTail(buffer) else { return .passThrough }
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        if analyzer?.startsEnglish(tail, previousRunEnglish: previousRunEnglish) == true {
            englishRun = true; runWord = tail; runTyped = tail; buffer = ""
            pending = ""; done = []
            return .beginEnglish(tail)
        }
        return .passThrough
    }
}
