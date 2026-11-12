import XCTest
@testable import ZhizhiCore

final class TypingModeTests: XCTestCase {
    let start = Date(timeIntervalSince1970: 1000)

    func tap(_ mode: inout TypingMode, composing: Bool, held: TimeInterval = 0.1) -> TypingMode.Effect? {
        _ = mode.flagsChanged(keyCode: TypingMode.leftShiftKeyCode, shift: true, composing: composing, now: start)
        return mode.flagsChanged(keyCode: TypingMode.leftShiftKeyCode, shift: false, composing: composing, now: start.addingTimeInterval(held))
    }

    func testEnglishModeReturnsToChineseAfterIdle() {
        var mode = TypingMode()
        mode.englishIdleLimit = 60
        _ = tap(&mode, composing: false)
        XCTAssertTrue(mode.englishMode)
        XCTAssertFalse(mode.expireEnglishIfIdle(now: start.addingTimeInterval(30)))   // typing keeps it alive
        XCTAssertFalse(mode.expireEnglishIfIdle(now: start.addingTimeInterval(80)))   // 50 s since the last key
        XCTAssertTrue(mode.expireEnglishIfIdle(now: start.addingTimeInterval(150)))   // 70 s idle
        XCTAssertFalse(mode.englishMode)
        XCTAssertFalse(mode.expireEnglishIfIdle(now: start.addingTimeInterval(400)))
    }
    func testIdleLimitZeroKeepsEnglish() {
        var mode = TypingMode()
        mode.englishIdleLimit = 0
        _ = tap(&mode, composing: false)
        XCTAssertFalse(mode.expireEnglishIfIdle(now: start.addingTimeInterval(9999)))
        XCTAssertTrue(mode.englishMode)
    }

    func testCapsIsCapitalsNotALanguageSwitch() {
        var mode = TypingMode()
        XCTAssertEqual(mode.syncCaps(true), .capsChanged(true))
        XCTAssertTrue(mode.capsOn)
        XCTAssertFalse(mode.englishMode)
        XCTAssertTrue(mode.passesThrough)
        XCTAssertNil(mode.syncCaps(true))
        XCTAssertEqual(mode.syncCaps(false), .capsChanged(false))
        XCTAssertFalse(mode.passesThrough)
    }
    func testShiftUnderCapsTypesLowercase() {
        var mode = TypingMode()
        _ = mode.syncCaps(true)
        XCTAssertEqual(mode.lowercaseOverride(letter: "A", shift: true), "a")
        XCTAssertNil(mode.lowercaseOverride(letter: "A", shift: false))
        XCTAssertNil(mode.lowercaseOverride(letter: "1", shift: true))
    }
    func testLoneShiftUnderCapsLeavesCapsAndChinese() {
        var mode = TypingMode()
        _ = mode.syncCaps(true)
        XCTAssertEqual(tap(&mode, composing: false), .leaveCaps)
        XCTAssertFalse(mode.englishMode)
        _ = mode.syncCaps(false)
        XCTAssertFalse(mode.passesThrough)
    }
    func testNoOverrideWithoutCaps() {
        XCTAssertNil(TypingMode().lowercaseOverride(letter: "A", shift: true))
    }
    func testLoneShiftTogglesEnglishWhenNothingIsComposed() {
        var mode = TypingMode()
        XCTAssertEqual(tap(&mode, composing: false), .englishChanged(true))
        XCTAssertTrue(mode.passesThrough)
        XCTAssertEqual(tap(&mode, composing: false), .englishChanged(false))
        XCTAssertFalse(mode.passesThrough)
    }
    func testLoneShiftFlipsWhileComposing() {
        var mode = TypingMode()
        XCTAssertEqual(tap(&mode, composing: true), .flipSegment)
        XCTAssertFalse(mode.englishMode)
    }
    func testShiftUsedWithAnotherInputDoesNothing() {
        var mode = TypingMode()
        _ = mode.flagsChanged(keyCode: TypingMode.leftShiftKeyCode, shift: true, composing: false, now: start)
        mode.otherInput()
        XCTAssertNil(mode.flagsChanged(keyCode: TypingMode.leftShiftKeyCode, shift: false, composing: false, now: start))
        XCTAssertFalse(mode.englishMode)
    }
    func testHeldShiftDoesNotToggle() {
        var mode = TypingMode()
        XCTAssertNil(tap(&mode, composing: false, held: 0.6))
        XCTAssertNil(tap(&mode, composing: true, held: 1.5))
    }
    func testRightShiftAndOtherFlagsAreIgnored() {
        var mode = TypingMode()
        XCTAssertNil(mode.flagsChanged(keyCode: 60, shift: true, composing: false, now: start))
        XCTAssertNil(mode.flagsChanged(keyCode: 60, shift: false, composing: false, now: start))
        _ = mode.flagsChanged(keyCode: TypingMode.leftShiftKeyCode, shift: true, composing: false, now: start)
        _ = mode.flagsChanged(keyCode: 55, shift: true, composing: false, now: start)
        XCTAssertNil(mode.flagsChanged(keyCode: TypingMode.leftShiftKeyCode, shift: false, composing: false, now: start))
    }
}
