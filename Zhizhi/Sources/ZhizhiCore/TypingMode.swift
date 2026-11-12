import Foundation

/// Caps Lock means capitals, as on any keyboard. A lone left Shift flips the segment
/// being composed, or toggles English mode when nothing is being composed.
public struct TypingMode: Equatable {
    public enum Effect: Equatable {
        case capsChanged(Bool)
        case englishChanged(Bool)
        case flipSegment
        case leaveCaps          // a lone tap under Caps Lock: the app switches Caps Lock off, back to Chinese
    }

    public static let leftShiftKeyCode: UInt16 = 56
    /// The key that flips and toggles; nil turns both off.
    public var switchKeyCode: UInt16? = TypingMode.leftShiftKeyCode
    static let flipWindow: TimeInterval = 1.0     // a slower tap while composing is not a flip
    static let toggleWindow: TimeInterval = 0.5   // stricter: a toggle changes all later typing

    public private(set) var capsOn = false
    public private(set) var englishMode = false
    private var shiftDownAt: Date?
    /// English mode goes back to Chinese after this many idle seconds; 0 keeps it until toggled.
    public var englishIdleLimit: TimeInterval = 60
    private var englishActiveAt: Date?

    public init() {}

    /// Keys go straight to the app, skipping composition.
    public var passesThrough: Bool { capsOn || englishMode }

    /// Caps Lock on the Mac stays uppercase under Shift, so the input method supplies the lowercase.
    public func lowercaseOverride(letter: Character, shift: Bool) -> String? {
        guard capsOn, shift, letter.isASCII, letter.isLetter else { return nil }
        return letter.lowercased()
    }

    /// Call for every key. If English mode sat idle past the limit, it ends (true) before this key is handled.
    public mutating func expireEnglishIfIdle(now: Date = Date()) -> Bool {
        defer { if englishMode { englishActiveAt = now } }
        guard englishMode, englishIdleLimit > 0, let last = englishActiveAt,
              now.timeIntervalSince(last) >= englishIdleLimit else { return false }
        englishMode = false
        return true
    }

    /// Any key or click between Shift down and up means it was not a lone tap.
    public mutating func otherInput() { shiftDownAt = nil }

    public mutating func setSwitchKeyIfChanged(_ code: UInt16?) {
        if code != switchKeyCode { setSwitchKey(code) }
    }

    /// A new choice of key must not leave English mode on with no key to leave it.
    public mutating func setSwitchKey(_ code: UInt16?) {
        switchKeyCode = code
        shiftDownAt = nil
        if code == nil { englishMode = false }
    }

    public mutating func syncCaps(_ caps: Bool) -> Effect? {
        guard caps != capsOn else { return nil }
        capsOn = caps
        return .capsChanged(caps)
    }

    public mutating func flagsChanged(keyCode: UInt16, shift: Bool, composing: Bool, now: Date = Date()) -> Effect? {
        guard keyCode == switchKeyCode else { shiftDownAt = nil; return nil }
        if shift { shiftDownAt = now; return nil }
        defer { shiftDownAt = nil }
        guard let down = shiftDownAt else { return nil }
        let held = now.timeIntervalSince(down)
        if composing { return held < Self.flipWindow ? .flipSegment : nil }
        guard held < Self.toggleWindow else { return nil }
        if capsOn {    // Caps Lock forces English, so toggling would show "中文" while still typing English
            englishMode = false
            return .leaveCaps
        }
        englishMode.toggle()
        englishActiveAt = englishMode ? now : nil
        return .englishChanged(englishMode)
    }
}
