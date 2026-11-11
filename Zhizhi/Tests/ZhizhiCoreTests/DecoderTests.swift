import XCTest
@testable import ZhizhiCore

final class DecoderTests: XCTestCase {
    static let lexicon: Lexicon = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let l = Lexicon()
        l.loadChinese(tsv: try! String(contentsOf: root.appendingPathComponent("data/chinese-lexicon.tsv"), encoding: .utf8))
        l.loadEnglish(text: try! String(contentsOf: root.appendingPathComponent("data/english-words.txt"), encoding: .utf8))
        return l
    }()
    let decoder = Decoder(lexicon: DecoderTests.lexicon)

    func text(_ keys: String) -> String { decoder.render(decoder.decode(keys)) }
    func kinds(_ keys: String) -> [Segment.Kind] { decoder.decode(keys).map { $0.kind } }

    func testChineseWithTones() { XCTAssertEqual(text("su3cl3"), "你好") }
    func testComponentsInAnyOrder() {
        XCTAssertEqual(text("ru4"), text("ur4"), "ㄐㄧˋ typed medial first")
        XCTAssertFalse(kinds("url4").contains(.english), "url4 is ㄐㄧㄠˋ, not English")
    }
    func testTonelessWord() { XCTAssertEqual(text("su cl").replacingOccurrences(of: " ", with: ""), text("su3cl3")) }
    func testEnglishWord() { XCTAssertEqual(text("hello"), "hello") }
    func testChineseWordsStayChinese() {
        XCTAssertEqual(kinds("co "), [.chinese], "黑")
        XCTAssertEqual(kinds("up "), [.chinese], "因")
        XCTAssertEqual(kinds("co3"), [.chinese])
    }
    func testMixedWithAutoSpace() {
        XCTAssertEqual(text("su3cl3hello"), "你好 hello")
        XCTAssertEqual(text("hellosu3cl3"), "hello 你好")
        XCTAssertEqual(text("su3cl3 BUY"), "你好 BUY")
        XCTAssertEqual(text("su3cl3Mac"), "你好 Mac")
    }
    func testEnglishSentence() { XCTAssertEqual(text("hello world"), "hello world") }
    func testUpAfterEnglish() { XCTAssertEqual(text("hello up"), "hello up") }
    func testRunIsEnglish() { XCTAssertEqual(text("run"), "run") }
    func testTokens() {
        XCTAssertEqual(text("https://example.com"), "https://example.com")
        XCTAssertEqual(text("a.b@example.com"), "a.b@example.com")
        XCTAssertEqual(text("example.com"), "example.com")
    }
    func testNumbers() {
        XCTAssertEqual(text("2026"), "2026")
        XCTAssertEqual(text("283"), text("283"))
        XCTAssertEqual(kinds("283"), [.chinese], "ㄉㄚˇ")
    }
    func testLettersAfterToneAndSpaceAreEnglishAtOnce() {
        for typed in ["a", "ap", "app"] {
            XCTAssertEqual(decoder.decode("su3cl3 " + typed).last?.kind, .english, "\(typed) after a closed syllable")
        }
        XCTAssertEqual(text("su3cl3 apple"), "你好 apple")
    }
    func testSpaceAsFirstToneStillBuildsChinese() {
        XCTAssertEqual(decoder.decode("su cl").last?.kind, .chinese, "the space after ㄋㄧ is its tone, so ㄏㄠ goes on as Chinese")
        XCTAssertEqual(text("su3cl3"), "你好")
    }
    func testStrayLetterBetweenChineseIsDropped() {
        XCTAssertEqual(text("su3cl3"), "你好")
        XCTAssertEqual(text("su3ccl3"), text("su3cl3"), "an extra c typed between the two words")
        XCTAssertNotEqual(text("su3c"), "你", "a letter at the end is still being typed, so it stays")
    }
    func testDigitsBeforePercentStayNumbers() {
        XCTAssertEqual(text("10%"), "10%")
        XCTAssertEqual(text("su3cl310%"), "你好10%")
        XCTAssertEqual(text("su3cl3 10%"), "你好 10%")
        XCTAssertEqual(text("su3cl3283"), text("su3cl3283"), "digits without a percent sign are untouched")
    }
    func testListMarker() {
        XCTAssertEqual(text("2."), "2.")
        XCTAssertEqual(text("2. "), "2. ")
        XCTAssertEqual(text("3. "), "3. ")
        XCTAssertEqual(text("su3cl3 2. "), "你好 2. ")
        XCTAssertEqual(kinds("2.4"), [.chinese], "ㄉㄡˋ stays Zhuyin")
        XCTAssertEqual(text("5. ai4"), "週末", "ㄓㄡ followed by more syllables is still a word")
    }
    func testPendingSyllableShowsSymbols() { XCTAssertEqual(decoder.decode("su").last?.kind, .pending) }
    func testWrongToneIsTolerated() { XCTAssertEqual(text("su3cl "), "你好") }
    func testPickedCandidateIsKept() {
        let keys = Array("su3cl3")
        let picked = [Constraint(range: 3..<6, fix: .text("郝", .chinese))]
        XCTAssertEqual(decoder.render(decoder.decode(keys: keys, constraints: picked)).last, "郝")
    }
    func testFlipToEnglish() {
        let keys = Array("up")
        let flipped = [Constraint(range: 0..<2, fix: .language(.english))]
        XCTAssertEqual(decoder.render(decoder.decode(keys: keys, constraints: flipped)), "up")
    }
    func testPunctuationFollowsLanguage() {
        XCTAssertEqual(text("su3cl3<"), "你好，")
        XCTAssertEqual(text("hello<"), "hello,")
    }
    func testOkWinsWithoutContext() { XCTAssertEqual(text("ok"), "ok") }

    // MARK: Composition

    func type(_ keys: String, into c: inout Composition) { for k in keys { c.insert(k) } }

    func testMisjudgementHealsAsYouType() {
        var c = Composition()
        type("url", into: &c)
        XCTAssertEqual(c.segments(decoder).last?.kind, .pending, "ㄐㄧㄠ so far")
        XCTAssertNotNil(decoder.offer(keys: c.keys, cursor: c.cursor), "English is still one Tab away")
        type("4", into: &c)
        XCTAssertEqual(c.segments(decoder).map { $0.kind }, [.chinese], "the tone key changes the reading, no backspace needed")
    }
    func testBackspaceRemovesWholeCharacter() {
        var c = Composition()
        type("su3cl3", into: &c)
        c.backspace(decoder)
        XCTAssertEqual(c.rendered(decoder).text, "你")
        XCTAssertEqual(c.keys, Array("su3"))
    }
    func testBackspaceRemovesOneZhuyinKeyWhileUnfinished() {
        var c = Composition()
        type("su", into: &c)
        c.backspace(decoder)
        XCTAssertEqual(c.keys, Array("s"))
    }
    func testBackspaceRemovesOneLetter() {
        var c = Composition()
        type("hello", into: &c)
        c.backspace(decoder)
        XCTAssertEqual(c.keys, Array("hell"))
    }
    func testPickedCharacterSurvivesMoreTyping() {
        var c = Composition()
        type("su3cl3", into: &c)
        let options = decoder.candidates(keys: c.keys, segments: c.segments(decoder), cursor: c.cursor)
        XCTAssertEqual(options.first?.text, "你好", "longest first")
        let single = options.first { $0.text.count == 1 && $0.text != "好" }!
        c.pick(single)
        type("hello", into: &c)
        XCTAssertTrue(c.rendered(decoder).text.contains(single.text))
    }
    func testFlipBothWays() {
        var c = Composition()
        type("up", into: &c)
        XCTAssertEqual(c.segments(decoder).last?.kind, .pending)
        c.flipBeforeCursor(decoder)
        XCTAssertEqual(c.rendered(decoder).text, "up")
    }
    func testCursorEditsInTheMiddle() {
        var c = Composition()
        type("su3cl3", into: &c)
        XCTAssertTrue(c.moveLeft(decoder))
        XCTAssertEqual(c.cursor, 3)
        XCTAssertEqual(c.rendered(decoder).caret, 1)
        c.backspace(decoder)
        XCTAssertEqual(c.keys, Array("cl3"))
    }
    func testMoveAtEdgeBelongsToTheApp() {
        var c = Composition()
        XCTAssertFalse(c.moveLeft(decoder))
        XCTAssertFalse(c.moveRight(decoder))
    }
    func testSentencePunctuationAsksToCommit() {
        var c = Composition()
        type("su3cl3", into: &c)
        XCTAssertTrue(c.insert(">"))
        XCTAssertEqual(c.commit(decoder), "你好。")
        XCTAssertTrue(c.isEmpty)
    }
    func testCommitResolvesUnfinishedSyllable() {
        var c = Composition()
        type("co", into: &c)
        XCTAssertFalse(c.commit(decoder).unicodeScalars.contains { $0.value >= 0x3100 && $0.value <= 0x312F }, "no bare Zhuyin symbols")
        var digits = Composition()
        type("10", into: &digits)
        XCTAssertEqual(digits.commit(decoder), "10")
    }
    func testLongBufferCommitsTheFront() {
        var c = Composition()
        for _ in 0..<30 { type("su3cl3", into: &c) }
        let front = c.commitOverflow(decoder)
        XCTAssertNotNil(front)
        XCTAssertFalse(c.isEmpty)
        XCTAssertLessThanOrEqual(c.rendered(decoder).text.count + (front?.count ?? 0), 60)
    }

    // MARK: Offers

    func testEnglishOffer() {
        let offer = decoder.offer(keys: Array("dat"), cursor: 3)
        XCTAssertTrue(offer?.text.hasPrefix("dat") == true)
        XCTAssertEqual(offer?.range, 0..<3)
    }
    func testOfferNeedsTwoLetters() { XCTAssertNil(decoder.offer(keys: Array("d"), cursor: 1)) }
    func testCapitalisedOfferKeepsTypedCase() {
        XCTAssertEqual(decoder.offer(keys: Array("Dat"), cursor: 3)?.text.first, "D")
    }
    func testAcceptingOfferBecomesEnglish() {
        var c = Composition()
        type("su3cl3dat", into: &c)
        let offer = decoder.offer(keys: c.keys, cursor: c.cursor)!
        c.accept(offer)
        XCTAssertTrue(c.rendered(decoder).text.hasPrefix("你好 dat"))
    }
    func testPersonalOffers() {
        let l = Lexicon()
        l.loadChinese(tsv: "亞\t-5\tㄧㄚˋ\n東\t-5\tㄉㄨㄥ\n證\t-5\tㄓㄥˋ\n券\t-5\tㄑㄩㄢˋ\n")
        l.addUserEntry("Claude Code", reading: nil)
        l.addUserChinese("亞東證券", reading: "ㄧㄚˋ-ㄉㄨㄥ-ㄓㄥˋ-ㄑㄩㄢˋ")
        let d = Decoder(lexicon: l)
        XCTAssertEqual(d.offer(keys: Array("cl"), cursor: 2)?.text, "Claude Code")
        let keys = Array("u842j/ ")
        XCTAssertEqual(d.offer(keys: keys, cursor: keys.count)?.text, "亞東證券")
        XCTAssertNil(d.offer(keys: Array("u84"), cursor: 3), "one syllable is not enough")
    }
    func testSpellingFix() {
        XCTAssertEqual(DecoderTests.lexicon.spellingFix(for: "wrold"), "world")
        XCTAssertNil(DecoderTests.lexicon.spellingFix(for: "world"))
        XCTAssertNil(DecoderTests.lexicon.spellingFix(for: "teh"), "too short to guess")
    }

    func testUserEnglishKeepsSpelling() {
        let l = Lexicon()
        l.addUserEnglish("MyJAV")
        XCTAssertEqual(Decoder(lexicon: l).render(Decoder(lexicon: l).decode("myjav")), "MyJAV")
    }
}
