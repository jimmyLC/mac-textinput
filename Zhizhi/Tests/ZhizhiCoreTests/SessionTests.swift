import XCTest
@testable import ZhizhiCore

final class SessionTests: XCTestCase {
    var session: Session!
    var committed = ""

    override func setUp() {
        session = Session(decoder: Decoder(lexicon: DecoderTests.lexicon))
        committed = ""
    }

    @discardableResult
    func press(_ key: Session.Key) -> Session.Output {
        let out = session.handle(key)
        committed += out.commit ?? ""
        return out
    }

    @discardableResult
    func type(_ keys: String) -> Session.Output {
        var last = Session.Output()
        for k in keys { last = press(.character(k)) }
        return last
    }

    func testTypingShowsCompositionAndEnterCommits() {
        XCTAssertEqual(type("su3cl3").composing, "你好")
        XCTAssertEqual(committed, "")
        let out = press(.enter)
        XCTAssertEqual(committed, "你好")
        XCTAssertEqual(out.composing, "")
    }
    func testMixedSentenceFlows() {
        type("su3cl3hello")
        press(.enter)
        XCTAssertEqual(committed, "你好 hello")
    }
    func testEnglishThenSpaceThenChinese() {
        XCTAssertEqual(type("hello su3cl3").composing, "hello 你好")
    }
    func testShiftCapitalsReadAsEnglish() {
        XCTAssertEqual(type("Hello").composing, "Hello")
        press(.enter)
        XCTAssertEqual(type("A").composing, "A")
        press(.enter)
        XCTAssertEqual(type("OK").composing, "OK")
        press(.enter)
        XCTAssertEqual(type("iPhone").composing, "iPhone")
        press(.enter)
        XCTAssertEqual(type("BUY").composing, "BUY")
        press(.enter)
        session = Session(decoder: session.decoder)
        XCTAssertEqual(type("su3cl3Hello").composing, "你好 Hello")
    }
    func testUnderscoreStaysAnUnderscoreAfterChinese() {
        XCTAssertEqual(type("su3cl3_").composing, "你好_")
        press(.enter)
        XCTAssertEqual(type("_").composing, "_")
    }
    func testSentencePunctuationCommits() {
        type("su3cl3>")
        XCTAssertEqual(committed, "你好。")
        XCTAssertFalse(session.isComposing)
    }
    func testKeysOnEmptyBufferGoToTheApp() {
        XCTAssertFalse(press(.enter).handled)
        XCTAssertFalse(press(.backspace).handled)
        XCTAssertFalse(press(.left).handled)
        XCTAssertFalse(press(.down).handled)
        XCTAssertFalse(press(.tab).handled)
        XCTAssertFalse(press(.character(" ")).handled)
        XCTAssertFalse(press(.shiftTap).handled)
    }
    func testEscapeKeepsText() {
        type("su3")
        let out = press(.escape)
        XCTAssertTrue(out.handled)
        XCTAssertEqual(out.composing, "你")
    }
    func testCandidatesOpenPickAndLock() {
        type("su3cl3")
        let open = press(.down)
        XCTAssertEqual(open.candidates?.items.first, "你好")
        XCTAssertEqual(open.candidates?.selected, 0)
        let single = open.candidates!.items.firstIndex { $0.count == 1 && $0 != "好" }!
        let choice = open.candidates!.items[single]
        let out = press(.character(Character(String(single + 1))))
        XCTAssertNil(out.candidates)
        XCTAssertTrue(out.composing.contains(choice))
        XCTAssertTrue(type("hello").composing.contains(choice), "a pick survives more typing")
    }
    func testDigitsTypeZhuyinWhenNoListIsOpen() {
        XCTAssertEqual(type("283").composing, "打")
    }
    func testTypingClosesTheList() {
        type("su3")
        XCTAssertNotNil(press(.down).candidates)
        let out = press(.character("c"))
        XCTAssertNil(out.candidates)
        XCTAssertEqual(session.composition.keys, Array("su3c"))
    }
    func testEscapeClosesListOnly() {
        type("su3")
        press(.down)
        let out = press(.escape)
        XCTAssertNil(out.candidates)
        XCTAssertEqual(out.composing, "你")
    }
    func testTabAcceptsEnglishOffer() {
        let shown = type("su3cl3dat")
        let offer = try! XCTUnwrap(shown.offer)
        XCTAssertTrue(offer.hasPrefix("dat"))
        XCTAssertEqual(press(.tab).composing, "你好 " + offer)
    }
    func testTabWithoutOfferIsSwallowed() {
        type("su3")
        let out = press(.tab)
        XCTAssertTrue(out.handled)
        XCTAssertEqual(out.composing, "你")
    }
    func testShiftTapFlips() {
        type("up")
        XCTAssertEqual(press(.shiftTap).composing, "up")
    }
    func testSpellingOfferAfterSpace() {
        let out = type("Wrold ")
        XCTAssertEqual(out.offer, "World")
        XCTAssertEqual(press(.tab).composing, "World ")
    }
    func testFixedDigit() {
        type("su3")
        XCTAssertEqual(press(.fixedDigit("2")).composing, "你2")
    }
    func testShortcutCommitsAndPasses() {
        type("su3")
        let out = press(.shortcut)
        XCTAssertFalse(out.handled)
        XCTAssertEqual(committed, "你")
    }
    func testSymbolTable() {
        let open = type("`")
        XCTAssertEqual(open.candidates?.items.first, "，")
        let out = press(.character("2"))
        XCTAssertEqual(out.composing, "。")
    }
    func testPreviousChineseMakesEnglishStartWithASpace() {
        session.setPreviousCharacter("好")
        type("hello")
        press(.enter)
        XCTAssertEqual(committed, " hello")
    }
    func testPreviousChineseMakesPunctuationFullWidth() {
        session.setPreviousCharacter("好")
        XCTAssertEqual(type("<").commit, "，")
    }
    func testFlushCommits() {
        type("su3cl3")
        XCTAssertEqual(session.flush(), "你好")
        XCTAssertNil(session.flush())
    }
    func testLongBufferFlushesFront() {
        for _ in 0..<30 { type("su3cl3") }
        XCTAssertFalse(committed.isEmpty)
        XCTAssertTrue(session.isComposing)
    }
}
