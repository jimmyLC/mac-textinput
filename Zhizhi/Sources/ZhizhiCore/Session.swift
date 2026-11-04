import Foundation

/// One input session as a pure state machine: keys go in, the screen state comes out.
/// The IME layer only translates events and applies `Output`, so typing can be replayed in tests.
public final class Session {
    public enum Key: Equatable {
        case character(Character)
        case fixedDigit(Character)     // Option + digit or numpad: always a digit
        case enter, backspace, left, right, up, down, tab, escape, pageUp, pageDown
        case shiftTap                  // left Shift pressed and released alone
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
    }

    public static let pageSize = 9
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

    public init(decoder: Decoder) { self.decoder = decoder }

    public var isComposing: Bool { !composition.isEmpty }

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
        var text = composition.commit(decoder)
        if decoder.autoSpace, leading != .other, let first = text.first, first != " " {
            let language = Self.language(of: first)
            if language != .other, language != leading { text = " " + text }
        }
        previousCharacter = text.last
        composition.leading = Self.language(of: previousCharacter)
        return text
    }

    public func handle(_ key: Key) -> Output {
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
            output.handled = isComposing       // Esc never drops the text
        case .shiftTap:
            if composition.isEmpty { output.handled = false } else { composition.flipBeforeCursor(decoder) }
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
            let pages = max(1, (listItems.count + Self.pageSize - 1) / Self.pageSize)
            let page = listIndex / Self.pageSize
            let start = page * Self.pageSize
            output.candidates = Candidates(items: Array(listItems[start..<min(start + Self.pageSize, listItems.count)]),
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
            if let n = ch.wholeNumberValue, (1...Self.pageSize).contains(n) {
                let index = (listIndex / Self.pageSize) * Self.pageSize + n - 1
                if index < listItems.count { choose(index) }
                return true
            }
            if ch == " " { moveList(Self.pageSize); return true }
            listOpen = false
            return false
        case .down: moveList(1); return true
        case .up: moveList(-1); return true
        case .right, .pageDown: moveList(Self.pageSize); return true
        case .left, .pageUp: moveList(-Self.pageSize); return true
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
        guard !composition.isEmpty else { return nil }
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
