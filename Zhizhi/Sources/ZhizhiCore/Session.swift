import Foundation

/// One input session as a pure state machine: keys go in, the screen state comes out.
/// The IME layer only translates events and applies `Output`, so typing can be replayed in tests.
public final class Session {
    public enum Key: Equatable {
        case character(Character)
        case fixedDigit(Character)     // Option + digit or numpad: always a digit
        case enter, backspace, left, right, up, down, tab, escape, pageUp, pageDown
        case shiftTap                  // left Shift pressed and released alone
        case undoCorrection            // Cmd-Z while the AI has changed something uncommitted
        case shortcut                  // Command or Control combination
        case other
    }

    public struct Candidates: Equatable {
        public var items: [String]     // the current page
        public var selected: Int       // index within the page
        public var page: Int
        public var pageCount: Int
    }

    public struct Output: Equatable {
        public var handled = true      // false: the key also goes to the app
        public var commit: String?     // text to insert
        public var composing = ""
        public var caret = 0           // UTF-16 offset in `composing`
        public var candidates: Candidates?
        public var offer: String?      // Tab offer text
        public var corrected: [Int] = []   // character offsets in `composing` the AI just changed
    }

    public static let defaultPageSize = 9
    public var pageSize = Session.defaultPageSize
    public var tabOffers = true
    public var escapeClears = false
    public static let symbols = ["，", "。", "、", "；", "：", "？", "！", "「", "」", "『", "』", "（", "）", "《", "》", "〈", "〉",
                                 "…", "——", "～", "·", "＋", "－", "×", "÷", "＝", "％", "＠", "＃", "＆", "＊", "／", "＼",
                                 "→", "←", "↑", "↓", "○", "●", "☆", "★", "✓", "✗", "°", "℃", "＄", "€", "£", "¥"]

    public let decoder: Decoder
    public private(set) var composition = Composition()
    private var listItems: [String] = []
    private var listCandidates: [Decoder.Candidate] = []
    private var listSymbols = false
    private var listOpen = false
    private var listIndex = 0
    private var previousCharacter: Character?
    /// Rises with every key, so an answer from the local AI can tell it is too late.
    public private(set) var generation = 0
    private var scoredTexts: [String] = []

    /// Set only while learning is allowed for the current app.
    public var learner: Learner?
    /// Every committed text, for the sentence history; nil while that is off.
    public var onCommit: ((String) -> Void)?

    public init(decoder: Decoder) { self.decoder = decoder }

    public var isComposing: Bool { !composition.isEmpty }
    public var hasCorrections: Bool { composition.hasCorrections }

    /// What the local AI should score now; nil when it has seen exactly this already.
    public func correctionRequest() -> (plan: CorrectionPlan, generation: Int)? {
        guard isComposing, !listOpen,
              let plan = decoder.correctionPlan(keys: composition.keys, segments: composition.segments(decoder)),
              plan.texts != scoredTexts else { return nil }
        scoredTexts = plan.texts
        return (plan, generation)
    }

    /// Applies an answer, unless the user has typed since. Nil means nothing changed.
    public func applyCorrections(plan: CorrectionPlan, generation: Int, logprobs: [Float], threshold: Float) -> Output? {
        guard generation == self.generation else {
            scoredTexts = []    // this answer is lost: the next pause may ask again, even for the same text
            return nil
        }
        let found = decoder.corrections(plan: plan, logprobs: logprobs, threshold: threshold)
        guard !found.isEmpty else { return nil }
        let before = Array(composition.rendered(decoder).text)
        composition.applyCorrections(found)
        var output = Output()
        output = finish(&output)
        let after = Array(output.composing)
        output.corrected = after.indices.filter { $0 < before.count && before[$0] != after[$0] }
        return output
    }

    /// The screen as it stands now, without touching anything.
    public func currentOutput() -> Output {
        var output = Output()
        return finish(&output)
    }

    /// The character before the caret in the app, when it can tell; used at the start of a buffer.
    public func setPreviousCharacter(_ character: Character?) {
        previousCharacter = character
        guard composition.isEmpty else { return }
        composition.leading = Self.language(of: character)
    }

    private static func language(of character: Character?) -> Segment.Kind {
        guard let c = character else { return .other }
        if c.isASCII { return c.isLetter ? .english : .other }
        guard let v = c.unicodeScalars.first?.value else { return .other }
        let han = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
        return han ? .chinese : .other
    }

    /// Commits everything (focus change, mode switch). Nil when nothing is pending.
    public func flush() -> String? {
        listOpen = false
        guard !composition.isEmpty else { return nil }
        return commitText()
    }

    private func commitText() -> String {
        let leading = composition.leading
        learn()
        var text = composition.commit(decoder)
        onCommit?(text)
        if decoder.autoSpace, leading != .other, let first = text.first, first != " " {
            let language = Self.language(of: first)
            if language != .other, language != leading { text = " " + text }
        }
        previousCharacter = text.last
        composition.leading = Self.language(of: previousCharacter)
        return text
    }

    /// Tells the learner what this commit showed: chosen words, new phrases, unknown English.
    private func learn() {
        guard let learner else { return }
        let keys = composition.keys
        var run: [Constraint] = []
        func closeRun() {
            defer { run.removeAll() }
            guard run.count >= 2, let first = run.first, let last = run.last else { return }
            let text = run.compactMap { c -> String? in if case .text(let t, _) = c.fix { return t } else { return nil } }.joined()
            let range = first.range.lowerBound..<last.range.upperBound
            if let reading = decoder.reading(of: text, keys: keys, range: range) { learner.pickedPhrase(text: text, reading: reading) }
        }
        let segments = composition.segments(decoder)
        for c in composition.constraints.filter({ $0.picked }).sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard case .text(let text, _) = c.fix else { continue }
            // Chosen next to other Chinese words: the choice is about this spot. Chosen alone: about the word.
            let at = segments.firstIndex { $0.range == c.range }
            let previous = at.flatMap { $0 > 0 && segments[$0 - 1].kind == .chinese ? segments[$0 - 1].text : nil }
            let next = at.flatMap { $0 + 1 < segments.count && segments[$0 + 1].kind == .chinese ? segments[$0 + 1].text : nil }
            if previous != nil || next != nil {
                let without = decoder.decode(keys: keys, constraints: composition.constraints.filter { $0 != c }, leading: composition.leading)
                let replaced = without.first { $0.range == c.range && $0.kind == .chinese }?.text
                learner.pickedBetween(word: text, previous: previous, next: next, replaced: replaced)
            } else if let reading = decoder.reading(of: text, keys: keys, range: c.range) {
                learner.picked(word: text, reading: reading)
            }
            if let last = run.last, last.range.upperBound != c.range.lowerBound { closeRun() }
            run.append(c)
        }
        closeRun()
        for segment in composition.segments(decoder) where segment.kind == .english {
            learner.committed(english: segment.text)
        }
    }

    public func handle(_ key: Key) -> Output {
        generation += 1
        var output = Output()
        if listOpen, handleList(key, &output) { return finish(&output) }

        switch key {
        case .character(let ch):
            guard ch.isASCII else { output.handled = isComposing; if isComposing { output.commit = commitText() }; output.handled = false; break }
            if composition.isEmpty, ch == " " { output.handled = false; break }
            if ch == "`" { openSymbols(); break }
            if composition.insert(ch) {
                output.commit = commitText()
            } else if let front = composition.commitOverflow(decoder) {
                output.commit = front
                onCommit?(front)
            }
        case .fixedDigit(let ch):
            composition.insertFixed(ch, text: String(ch))
        case .enter:
            if composition.isEmpty { output.handled = false } else { output.commit = commitText() }
        case .backspace:
            if composition.isEmpty { output.handled = false } else { composition.backspace(decoder) }
        case .left:
            output.handled = composition.moveLeft(decoder) || isComposing
        case .right:
            output.handled = composition.moveRight(decoder) || isComposing
        case .down:
            if composition.isEmpty { output.handled = false } else { openCandidates() }
        case .up, .pageUp, .pageDown:
            output.handled = isComposing
        case .tab:
            if composition.isEmpty { output.handled = false }
            else if let offer = currentOffer() { composition.accept(offer) }
        case .escape:
            output.handled = isComposing
            if escapeClears { composition = Composition() }   // otherwise Esc never drops the text
        case .shiftTap:
            if composition.isEmpty { output.handled = false } else { composition.flipBeforeCursor(decoder) }
        case .undoCorrection:
            composition.undoCorrections()
        case .shortcut, .other:
            if isComposing { output.commit = commitText() }
            output.handled = false
        }
        return finish(&output)
    }

    private func finish(_ output: inout Output) -> Output {
        let (text, caret) = composition.rendered(decoder)
        output.composing = text
        output.caret = caret
        if listOpen {
            let pages = max(1, (listItems.count + pageSize - 1) / pageSize)
            let page = listIndex / pageSize
            let start = page * pageSize
            output.candidates = Candidates(items: Array(listItems[start..<min(start + pageSize, listItems.count)]),
                                           selected: listIndex - start, page: page, pageCount: pages)
        } else {
            output.offer = currentOffer()?.text.trimmingCharacters(in: .whitespaces)
        }
        return output
    }

    /// Returns true when the key was consumed by the open list.
    private func handleList(_ key: Key, _ output: inout Output) -> Bool {
        switch key {
        case .character(let ch):
            if let n = ch.wholeNumberValue, (1...pageSize).contains(n) {
                let index = (listIndex / pageSize) * pageSize + n - 1
                if index < listItems.count { choose(index) }
                return true
            }
            if ch == " " { moveList(pageSize); return true }
            listOpen = false
            return false
        case .down: moveList(1); return true
        case .up: moveList(-1); return true
        case .right, .pageDown: moveList(pageSize); return true
        case .left, .pageUp: moveList(-pageSize); return true
        case .enter: choose(listIndex); return true
        case .escape, .backspace: listOpen = false; return true
        case .tab: return true
        default:
            listOpen = false
            return false
        }
    }

    private func moveList(_ delta: Int) {
        guard !listItems.isEmpty else { return }
        listIndex = min(max(0, listIndex + delta), listItems.count - 1)
    }

    private func choose(_ index: Int) {
        listOpen = false
        if listSymbols {
            composition.insertFixed("`", text: listItems[index])
        } else {
            composition.pick(listCandidates[index])
        }
    }

    private func openCandidates() {
        let segments = composition.segments(decoder)
        listCandidates = decoder.candidates(keys: composition.keys, segments: segments, cursor: composition.cursor)
        guard !listCandidates.isEmpty else { return }
        listItems = listCandidates.map { $0.text }
        listSymbols = false
        listOpen = true
        listIndex = 0
    }

    private func openSymbols() {
        listItems = Self.symbols
        listSymbols = true
        listOpen = true
        listIndex = 0
    }

    private func currentOffer() -> Decoder.Offer? {
        guard tabOffers, !composition.isEmpty else { return nil }
        let keys = composition.keys, cursor = composition.cursor
        // A word just finished with a space: offer its spelling fix, English segments only.
        if cursor >= 2, keys[cursor - 1] == " " {
            var start = cursor - 1
            while start > 0, keys[start - 1].isASCII, keys[start - 1].isLetter { start -= 1 }
            let typed = String(keys[start..<(cursor - 1)])
            let segment = composition.segments(decoder).first { $0.range.upperBound == cursor - 1 }
            guard segment?.kind == .english, let fix = decoder.spellingFix(for: typed) else { return nil }
            return Decoder.Offer(text: fix + " ", range: start..<cursor)
        }
        // Text the user has already fixed gets no offer.
        if composition.constraints.contains(where: { $0.range.upperBound == cursor }) { return nil }
        return decoder.offer(keys: keys, cursor: cursor)
    }
}
