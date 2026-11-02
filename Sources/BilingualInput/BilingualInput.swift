import Cocoa
import InputMethodKit

enum BilingualAction {
    case passThrough                          // let the IME handle the key as usual
    case literal                              // insert the key as plain text, bypassing the IME
    case commitComposingThenLiteral           // commit current composition, then insert the key
    case commit(String)                       // drop the composition; commit this text
    case replay(head: String, text: String)   // rebuild `head` as Zhuyin, commit it, then commit `text`
    case toggled(String)                      // Shift tap flipped this run's reading; show the label
}

/// Tracks the raw keys of the current composition and decides, at a space, whether
/// the run was really English. Typed text is never logged or stored.
final class BilingualInput {
    static let shared = BilingualInput()

    private let lock = NSLock()
    private var analyzer: BilingualAnalyzer?
    private var buffer = ""
    private var englishRun = false
    var tooltipShown = false
    /// Manual override of the automatic reading for the current run (Shift tap while composing).
    private enum Override { case english, chinese }
    private var override: Override?
    private var shiftDown = false
    private var shiftClean = false
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

    func reset() { buffer = ""; englishRun = false; override = nil; shiftDown = false }

    /// The raw keys to display as English instead of Zhuyin right now, if any.
    func liveEnglish() -> String? {
        if override == .chinese || buffer.isEmpty { return nil }
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        if override == .english { return buffer }
        return analyzer?.showsAsEnglish(buffer) == true ? buffer : nil
    }

    /// Completion to show for the current composition, if any.
    func currentCompletion() -> String? {
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        return analyzer?.completion(for: buffer)
    }

    /// A lone Shift tap (press and release with no other key) flips the reading of the current run.
    private func decideShift(_ event: NSEvent, composing: Bool) -> BilingualAction {
        let isShift = event.keyCode == 56 || event.keyCode == 60
        guard isShift else { return .passThrough }
        if event.modifierFlags.contains(.shift) {
            shiftDown = true; shiftClean = true
            return .passThrough
        }
        defer { shiftDown = false }
        guard shiftDown, shiftClean, composing, !buffer.isEmpty, !englishRun else { return .passThrough }
        lock.lock(); let analyzer = self.analyzer; lock.unlock()
        let auto = analyzer?.classify(buffer + " ") == .english
        let current: Override = override ?? (auto ? .english : .chinese)
        override = current == .english ? .chinese : .english
        return .toggled(override == .english ? "English" : "中文")
    }

    func decide(_ event: NSEvent, composing: Bool) -> BilingualAction {
        if event.type == .flagsChanged { return decideShift(event, composing: composing) }
        guard event.type == .keyDown else { return .passThrough }
        shiftClean = false
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
            reset(); return .passThrough
        }
        if event.keyCode == 51 {  // delete
            if englishRun { return .passThrough }
            if !buffer.isEmpty { buffer.removeLast() }
            return .passThrough
        }
        if (event.keyCode == 36 || event.keyCode == 76), composing, let word = liveEnglish() {  // Return/Enter
            buffer = ""; override = nil
            return .commit(word)
        }
        if event.keyCode == 48, composing, let word = currentCompletion() {  // Tab accepts the offer
            buffer = ""
            return .commit(word)
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
        let forced = override
        buffer = ""; override = nil
        guard composing, !body.isEmpty, let analyzer = analyzer else { return .passThrough }
        if forced == .chinese { return .passThrough }
        if forced == .english { return .commit(body + " ") }
        // Same rule as the live display, so what was shown is what gets committed.
        if analyzer.classify(body + " ") == .english || analyzer.showsAsEnglish(body) { return .commit(body + " ") }
        if let (head, tail) = analyzer.splitTrailingEnglish(body) { return .replay(head: head, text: tail + " ") }
        return .passThrough
    }
}

extension McBopomofoInputMethodController {
    /// Called after the IME has processed a key: offer an English completion next to the cursor.
    func bilingualAfterKey(client: Any!) {
        if state is InputState.Inputting, let word = BilingualInput.shared.liveEnglish() {
            let marked = NSAttributedString(string: word, attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue, .markedClauseSegment: 0])
            (client as? IMKTextInput)?.setMarkedText(
                marked, selectionRange: NSRange(location: word.count, length: 0),
                replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
        }
        guard state is InputState.Inputting, let word = BilingualInput.shared.currentCompletion() else {
            if BilingualInput.shared.tooltipShown {
                BilingualInput.shared.tooltipShown = false
                McBopomofoInputMethodController.tooltipController.hide()
            }
            return
        }
        var lineHeightRect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
        _ = (client as? IMKTextInput)?.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineHeightRect)
        BilingualInput.shared.tooltipShown = true
        McBopomofoInputMethodController.tooltipController.show(
            tooltip: word + " ⇥", at: NSPoint(x: lineHeightRect.origin.x, y: lineHeightRect.origin.y - 4))
    }

    /// Returns nil when the IME should handle the event as usual.
    func bilingualHandle(_ event: NSEvent, client: Any!) -> Bool? {
        switch BilingualInput.shared.decide(event, composing: state is InputState.Inputting) {
        case .passThrough:
            return nil
        case .toggled(let label):
            var rect = NSMakeRect(0.0, 0.0, 16.0, 16.0)
            _ = (client as? IMKTextInput)?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            BilingualInput.shared.tooltipShown = true
            McBopomofoInputMethodController.tooltipController.show(
                tooltip: label, at: NSPoint(x: rect.origin.x, y: rect.origin.y - 4))
            return true
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
