import Foundation

/// Caps Lock means capitals, as on any keyboard. A lone left Shift flips the segment
/// being composed, or toggles English mode when nothing is being composed.
public struct TypingMode: Equatable {
    public enum Effect: Equatable {
        case capsChanged(Bool)
        case englishChanged(Bool)
        case flipSegment
    }

    public static let leftShiftKeyCode: UInt16 = 56
    /// The key that flips and toggles; nil turns both off.
    public var switchKeyCode: UInt16? = TypingMode.leftShiftKeyCode
    static let flipWindow: TimeInterval = 1.0     // a slower tap while composing is not a flip
    static let toggleWindow: TimeInterval = 0.5   // stricter: a toggle changes all later typing

    public private(set) var capsOn = false
    public private(set) var englishMode = false
    private var shiftDownAt: Date?

    public init() {}

    /// Keys go straight to the app, skipping composition.
    public var passesThrough: Bool { capsOn || englishMode }

    /// Caps Lock on the Mac stays uppercase under Shift, so the input method supplies the lowercase.
    public func lowercaseOverride(letter: Character, shift: Bool) -> String? {
        guard capsOn, shift, letter.isASCII, letter.isLetter else { return nil }
        return letter.lowercased()
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
        guard held < Self.toggleWindow, !capsOn else { return nil }
        englishMode.toggle()
        return .englishChanged(englishMode)
    }
}
