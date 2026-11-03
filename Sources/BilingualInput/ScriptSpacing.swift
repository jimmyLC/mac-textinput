import Foundation

/// Decides when a space belongs between Chinese text and an English word that follows it.
enum ScriptSpacing {
    static let defaultsKey = "AutoSpaceBetweenScripts"

    /// On by default; the dictionary window can switch it off.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// True for Han characters and Bopomofo, i.e. text a space should separate from English.
    /// Fullwidth punctuation, spaces, digits and Latin letters need no extra space.
    static func isChinese(_ ch: Character) -> Bool {
        guard let v = ch.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x3100...0x312F).contains(v)
            || (0xF900...0xFAFF).contains(v)
    }

    static func needsSpace(before previous: Character?) -> Bool {
        guard let previous else { return false }
        return isChinese(previous)
    }
}
