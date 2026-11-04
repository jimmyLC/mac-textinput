import Foundation

/// The composition buffer: raw keys, the cursor among them, and what the user has fixed.
/// Holds no platform types, so a whole typing session can be replayed in tests.
public struct Composition {
    public private(set) var keys: [Character] = []
    public private(set) var cursor = 0
    public private(set) var constraints: [Constraint] = []
    /// Language of the text just before this buffer in the app.
    public var leading: Segment.Kind = .other

    /// Sentence-ending punctuation commits the buffer.
    private static let committingKeys: Set<Character> = ["<", ">", "?", "!"]
    public static let maxLength = 40

    public init() {}

    public var isEmpty: Bool { keys.isEmpty }

    public func segments(_ decoder: Decoder) -> [Segment] { decoder.decode(keys: keys, constraints: constraints, leading: leading) }

    /// Display text and the caret's offset (UTF-16) inside it.
    public func rendered(_ decoder: Decoder) -> (text: String, caret: Int) {
        let all = segments(decoder)
        let text = decoder.render(all)
        guard cursor < keys.count else { return (text, (text as NSString).length) }
        // Render what is before the cursor, cutting a word at the syllable the cursor stands on.
        var before: [Segment] = []
        for s in all {
            if s.range.upperBound <= cursor { before.append(s); continue }
            guard s.range.lowerBound < cursor else { break }
            var part = s
            switch s.kind {
            case .chinese:
                let done = s.syllableEnds.filter { $0 <= cursor }.count
                part.text = String(s.text.prefix(done))
            default:
                part.text = String(s.text.prefix(cursor - s.range.lowerBound))
            }
            before.append(part)
        }
        return (text, (decoder.render(before) as NSString).length)
    }

    /// Adds a key. Returns true when this key should commit the buffer.
    @discardableResult
    public mutating func insert(_ key: Character) -> Bool {
        keys.insert(key, at: cursor)
        shift(from: cursor, by: 1)
        cursor += 1
        return Self.committingKeys.contains(key) && cursor == keys.count
    }

    /// Adds a key whose meaning is already fixed: an Option-digit, numpad digit or picked symbol.
    public mutating func insertFixed(_ key: Character, text: String) {
        keys.insert(key, at: cursor)
        shift(from: cursor, by: 1)
        constraints.append(Constraint(range: cursor..<(cursor + 1), fix: .text(text, .other)))
        cursor += 1
    }

    /// Deletes one unit before the cursor: a whole Chinese character, one letter, or one Zhuyin key.
    public mutating func backspace(_ decoder: Decoder) {
        guard cursor > 0 else { return }
        let all = segments(decoder)
        var start = cursor - 1
        if let s = all.first(where: { $0.range.lowerBound < cursor && cursor <= $0.range.upperBound }), s.kind == .chinese {
            start = ([s.range.lowerBound] + s.syllableEnds).filter { $0 < cursor }.max() ?? start
        }
        remove(start..<cursor)
    }

    private mutating func remove(_ range: Range<Int>) {
        keys.removeSubrange(range)
        constraints.removeAll { $0.range.overlaps(range) }
        shift(from: range.upperBound, by: -range.count)
        cursor = range.lowerBound
    }

    private mutating func shift(from position: Int, by delta: Int) {
        constraints = constraints.map { c in
            guard c.range.lowerBound >= position else {
                // An insertion inside a fixed range releases it.
                return c
            }
            var moved = c
            moved.range = (c.range.lowerBound + delta)..<(c.range.upperBound + delta)
            return moved
        }
        if delta > 0 {
            constraints.removeAll { $0.range.lowerBound < position && position < $0.range.upperBound + 0 && $0.range.contains(position) }
        }
    }

    /// Moves by one displayed unit; returns false at the edge (the key then belongs to the app).
    public mutating func moveLeft(_ decoder: Decoder) -> Bool {
        guard cursor > 0 else { return false }
        cursor = boundaries(decoder).filter { $0 < cursor }.max() ?? 0
        return true
    }

    public mutating func moveRight(_ decoder: Decoder) -> Bool {
        guard cursor < keys.count else { return false }
        cursor = boundaries(decoder).filter { $0 > cursor }.min() ?? keys.count
        return true
    }

    private func boundaries(_ decoder: Decoder) -> [Int] {
        var result = [0, keys.count]
        for s in segments(decoder) {
            result.append(s.range.lowerBound)
            if s.kind == .chinese { result += s.syllableEnds }
            else if s.kind == .english { result += Array(s.range) }
        }
        return result
    }

    /// Fixes a picked candidate; re-decoding will keep it.
    public mutating func pick(_ candidate: Decoder.Candidate) {
        constraints.removeAll { $0.range.overlaps(candidate.range) }
        var constraint = Constraint(range: candidate.range, fix: .text(candidate.text, .chinese))
        constraint.picked = true
        constraints.append(constraint)
    }

    /// The local AI's choices. The user's own fixes always win: `corrections` never touches them.
    public mutating func applyCorrections(_ corrections: [Constraint]) {
        for c in corrections {
            constraints.removeAll { $0.range.overlaps(c.range) }
            constraints.append(c)
        }
    }

    public var hasCorrections: Bool { constraints.contains { $0.correctedFrom != nil } }

    /// Cmd-Z: puts back what the AI replaced and locks it, so the AI will not change it again.
    public mutating func undoCorrections() {
        constraints = constraints.map { c in
            guard let original = c.correctedFrom else { return c }
            var restored = c
            restored.fix = .text(original, .chinese)
            restored.correctedFrom = nil
            return restored
        }
    }

    /// Lone left Shift: flips the language of the segment before the cursor.
    public mutating func flipBeforeCursor(_ decoder: Decoder) {
        let all = segments(decoder)
        guard let s = all.last(where: { $0.range.lowerBound < cursor && $0.kind != .other }) else { return }
        let target: Segment.Kind = s.kind == .english ? .chinese : .english
        constraints.removeAll { $0.range.overlaps(s.range) }
        constraints.append(Constraint(range: s.range, fix: .language(target)))
    }

    /// Accepts a Tab offer: its keys now mean exactly this text.
    public mutating func accept(_ offer: Decoder.Offer) {
        constraints.removeAll { $0.range.overlaps(offer.range) }
        let kind: Segment.Kind = offer.text.first?.isASCII == true ? .english : .chinese
        constraints.append(Constraint(range: offer.range, fix: .text(offer.text, kind)))
    }

    /// The final text and an empty buffer. An unfinished syllable becomes its most likely
    /// character, or plain digits when it was only digit keys.
    public mutating func commit(_ decoder: Decoder) -> String {
        var pieces = segments(decoder)
        if let last = pieces.last, last.kind == .pending {
            let typed = keys[last.range]
            if typed.allSatisfy({ $0.isNumber }) {
                pieces[pieces.count - 1].text = String(typed)
                pieces[pieces.count - 1].kind = .other
            } else if let word = decoder.bestCharacter(keys: Array(typed)) {
                pieces[pieces.count - 1].text = word
                pieces[pieces.count - 1].kind = .chinese
            }
        }
        let text = decoder.render(pieces)
        self = Composition()
        return text
    }

    /// Commits the front of a buffer that grew too long, keeping the rest editable.
    public mutating func commitOverflow(_ decoder: Decoder) -> String? {
        let all = segments(decoder)
        guard decoder.render(all).count > Self.maxLength, all.count > 1 else { return nil }
        var length = 0
        var taken = 0
        for s in all.dropLast() {
            if length + s.text.count > Self.maxLength / 2, taken > 0 { break }
            length += s.text.count
            taken += 1
        }
        guard taken > 0 else { return nil }
        let front = Array(all.prefix(taken))
        let end = front.last!.range.upperBound
        let text = decoder.render(front)
        keys.removeFirst(end)
        constraints = constraints.compactMap { c in
            guard c.range.lowerBound >= end else { return nil }
            var moved = c
            moved.range = (c.range.lowerBound - end)..<(c.range.upperBound - end)
            return moved
        }
        cursor = max(0, cursor - end)
        return text
    }
}

extension Decoder {
    /// Most likely character for keys with no tone typed yet.
    public func bestCharacter(keys: [Character]) -> String? { bestCharacterAnyTone(keys) }
}
