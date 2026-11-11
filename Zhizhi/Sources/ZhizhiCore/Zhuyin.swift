import Foundation

/// Standard (大千) Zhuyin layout. Components of a syllable may be typed in any order.
public enum Zhuyin {
    public enum Tone {
        public static let none: UInt8 = 0      // no tone key typed
        public static let first: UInt8 = 1
        public static let second: UInt8 = 2
        public static let third: UInt8 = 3
        public static let fourth: UInt8 = 4
        public static let neutral: UInt8 = 5
    }

    static let symbolForKey: [Character: Character] = [
        "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
        "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
        "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
        "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
        "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
        "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
        "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
        "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
        "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
        "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ", "-": "ㄦ",
    ]
    static let toneForKey: [Character: UInt8] = [" ": Tone.first, "6": Tone.second, "3": Tone.third, "4": Tone.fourth, "7": Tone.neutral]
    static let toneMarks: [UInt8: Character] = [Tone.second: "ˊ", Tone.third: "ˇ", Tone.fourth: "ˋ", Tone.neutral: "˙"]
    static let markTones: [Character: UInt8] = [ "ˊ": Tone.second, "ˇ": Tone.third, "ˋ": Tone.fourth, "˙": Tone.neutral]
    static let medials: Set<Character> = ["ㄧ", "ㄨ", "ㄩ"]
    static let finals: Set<Character> = Set("ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ")

    /// 0 initial, 1 medial, 2 final.
    static func slot(_ symbol: Character) -> Int {
        if medials.contains(symbol) { return 1 }
        if finals.contains(symbol) { return 2 }
        return 0
    }

    /// Canonical spelling of up to three typed components, nil if two share a slot.
    static func canonical(_ symbols: [Character]) -> String? {
        var parts: [Character?] = [nil, nil, nil]
        for s in symbols {
            let i = slot(s)
            if parts[i] != nil { return nil }
            parts[i] = s
        }
        return String(parts.compactMap { $0 })
    }

    /// Splits "ㄋㄧˇ" into base "ㄋㄧ" and tone; an unmarked syllable is first tone.
    static func split(_ syllable: Substring) -> (base: String, tone: UInt8) {
        if let last = syllable.last, let tone = markTones[last] { return (String(syllable.dropLast()), tone) }
        // A leading neutral mark ("˙ㄉㄜ") also occurs in some data.
        if let first = syllable.first, let tone = markTones[first] { return (String(syllable.dropFirst()), tone) }
        return (String(syllable), Tone.first)
    }

    /// Typing keys for a reading such as "ㄋㄧˇ" ("su3"); first tone ends with a space.
    public static func keys(forSyllable syllable: String) -> String {
        let keyForSymbol = Dictionary(uniqueKeysWithValues: symbolForKey.map { ($1, $0) })
        let (base, tone) = split(Substring(syllable))
        var out = String(base.compactMap { keyForSymbol[$0] })
        switch tone {
        case Tone.second: out.append("6")
        case Tone.third: out.append("3")
        case Tone.fourth: out.append("4")
        case Tone.neutral: out.append("7")
        default: out.append(" ")
        }
        return out
    }

    public static func display(tone: UInt8) -> String { toneMarks[tone].map(String.init) ?? "" }
}
