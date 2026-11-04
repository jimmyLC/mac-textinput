import CryptoKit
import XCTest
@testable import ZhizhiCore

final class CorrectionTests: XCTestCase {
    /// A fresh lexicon: these tests change scores and must not disturb the shared one.
    func makeDecoder() -> Decoder {
        let lexicon = Lexicon()
        lexicon.loadChinese(tsv: """
        你好\t-3\tㄋㄧˇ-ㄏㄠˇ
        你\t-3\tㄋㄧˇ
        擬\t-6\tㄋㄧˇ
        擬定\t-6\tㄋㄧˇ-ㄉㄧㄥˋ
        好\t-3\tㄏㄠˇ
        郝\t-7\tㄏㄠˇ
        郝市\t-9\tㄏㄠˇ-ㄕˋ
        """)
        lexicon.loadEnglish(text: "hello\nworld\nthe\n")
        return Decoder(lexicon: lexicon)
    }

    func testPlanTriesSameSoundCharactersOnly() throws {
        let decoder = makeDecoder()
        let keys = Array("su3cl3")
        let plan = try XCTUnwrap(decoder.correctionPlan(keys: keys, segments: decoder.decode(keys: keys)))
        XCTAssertEqual(plan.texts.first, "你好")
        XCTAssertEqual(Set(plan.texts.dropFirst()), ["擬好", "你郝"])
    }
    func testOnlyAClearGainChangesTheText() throws {
        let decoder = makeDecoder()
        let keys = Array("su3cl3")
        let plan = try XCTUnwrap(decoder.correctionPlan(keys: keys, segments: decoder.decode(keys: keys)))
        let scores = plan.texts.map { $0 == "你郝" ? Float(-8) : Float(-10) }
        XCTAssertTrue(decoder.corrections(plan: plan, logprobs: scores, threshold: 2.5).isEmpty)
        let found = decoder.corrections(plan: plan, logprobs: scores, threshold: 2)
        XCTAssertEqual(decoder.render(decoder.decode(keys: keys, constraints: found)), "你郝")
    }
    func testUnfinishedSyllableIsLeftOut() throws {
        let decoder = makeDecoder()
        let keys = Array("su3cl3c")
        let plan = try XCTUnwrap(decoder.correctionPlan(keys: keys, segments: decoder.decode(keys: keys)))
        XCTAssertEqual(plan.texts.first, "你好")
    }
    func testPickedTextIsNeverReconsidered() {
        let decoder = makeDecoder()
        var composition = Composition()
        "su3cl3".forEach { composition.insert($0) }
        composition.pick(Decoder.Candidate(text: "你好", range: 0..<6))
        XCTAssertNil(decoder.correctionPlan(keys: composition.keys, segments: composition.segments(decoder)))
    }
    func testAnswerArrivingAfterAKeyIsDropped() throws {
        let session = Session(decoder: makeDecoder())
        "su3cl3".forEach { _ = session.handle(.character($0)) }
        let request = try XCTUnwrap(session.correctionRequest())
        _ = session.handle(.character("c"))
        let scores = request.plan.texts.map { $0 == "你郝" ? Float(0) : Float(-10) }
        XCTAssertNil(session.applyCorrections(plan: request.plan, generation: request.generation, logprobs: scores, threshold: 2))
    }
    func testSameTextIsNotScoredTwice() throws {
        let session = Session(decoder: makeDecoder())
        "su3cl3".forEach { _ = session.handle(.character($0)) }
        XCTAssertNotNil(session.correctionRequest())
        XCTAssertNil(session.correctionRequest())
    }
    func testCorrectionMarksCharactersAndUndoRestoresAndLocks() throws {
        let session = Session(decoder: makeDecoder())
        "su3cl3".forEach { _ = session.handle(.character($0)) }
        let request = try XCTUnwrap(session.correctionRequest())
        let scores = request.plan.texts.map { $0 == "你郝" ? Float(0) : Float(-10) }
        let out = try XCTUnwrap(session.applyCorrections(plan: request.plan, generation: request.generation, logprobs: scores, threshold: 2))
        XCTAssertEqual(out.composing, "你郝")
        XCTAssertEqual(out.corrected, [1])
        XCTAssertTrue(session.hasCorrections)
        XCTAssertEqual(session.handle(.undoCorrection).composing, "你好")
        XCTAssertFalse(session.hasCorrections)
        XCTAssertNil(session.correctionRequest(), "restored text is locked")
    }
    func testBackspaceAfterCorrectionStillWorksPerCharacter() throws {
        let session = Session(decoder: makeDecoder())
        "su3cl3".forEach { _ = session.handle(.character($0)) }
        let request = try XCTUnwrap(session.correctionRequest())
        let scores = request.plan.texts.map { $0 == "你郝" ? Float(0) : Float(-10) }
        _ = session.applyCorrections(plan: request.plan, generation: request.generation, logprobs: scores, threshold: 2)
        XCTAssertEqual(session.handle(.backspace).composing, "你")
    }
}

final class LearnerTests: XCTestCase {
    func make(_ dictionary: PersonalDictionary = PersonalDictionary(), state: Learner.State = Learner.State()) -> (Learner, Lexicon, Decoder) {
        let lexicon = Lexicon()
        lexicon.loadChinese(tsv: """
        在\t-3\tㄗㄞˋ
        再\t-4\tㄗㄞˋ
        品\t-5\tㄆㄧㄣˇ
        瑞\t-6\tㄖㄨㄟˋ
        銳\t-5\tㄖㄨㄟˋ
        """)
        lexicon.loadEnglish(text: "hello\nworld\nthe\nreceive\n")
        return (Learner(lexicon: lexicon, dictionary: dictionary, state: state), lexicon, Decoder(lexicon: lexicon))
    }
    func commitWithPick(_ session: Session, keys: String, pick: Int) {
        keys.forEach { _ = session.handle(.character($0)) }
        _ = session.handle(.down)
        _ = session.handle(.character(Character(String(pick))))
        _ = session.handle(.enter)
    }

    func testPickRaisesTheCharacterWithinLimits() {
        let (learner, _, decoder) = make()
        XCTAssertEqual(decoder.render(decoder.decode("y94")), "在")
        learner.picked(word: "再", reading: "ㄗㄞˋ")
        learner.picked(word: "再", reading: "ㄗㄞˋ")
        XCTAssertEqual(decoder.render(decoder.decode("y94")), "再")
        for _ in 0..<10 { learner.picked(word: "再", reading: "ㄗㄞˋ") }
        XCTAssertEqual(learner.state.boosts.count, 1)
    }
    func testBoostsSurviveARestart() {
        let (learner, _, _) = make()
        learner.picked(word: "再", reading: "ㄗㄞˋ")
        learner.picked(word: "再", reading: "ㄗㄞˋ")
        let (_, _, decoder) = make(state: learner.state)
        XCTAssertEqual(decoder.render(decoder.decode("y94")), "再")
    }
    func testPickThroughTheSessionTeaches() {
        let (learner, _, decoder) = make()
        let session = Session(decoder: decoder)
        session.learner = learner
        commitWithPick(session, keys: "y94", pick: 2)
        XCTAssertEqual(learner.state.boosts["再\tㄗㄞˋ"]?.picks, 1)
    }
    func testUnknownEnglishNeedsThreeCommitsAndCountsAreNotReadable() {
        let (learner, _, _) = make()
        learner.committed(english: "Zhizhi")
        learner.committed(english: "Zhizhi")
        XCTAssertTrue(learner.dictionary.entries.isEmpty)
        let saved = String(data: try! JSONEncoder().encode(learner.state), encoding: .utf8)!
        XCTAssertFalse(saved.lowercased().contains("zhizhi"), "a word below the threshold must not be readable")
        learner.committed(english: "Zhizhi")
        XCTAssertEqual(learner.dictionary.entries.map(\.text), ["Zhizhi"])
        XCTAssertEqual(learner.dictionary.entries.first?.source, .auto)
    }
    func testKnownWordsAndMisspellingsAreNotLearned() {
        let (learner, _, _) = make()
        for _ in 0..<5 { learner.committed(english: "hello"); learner.committed(english: "recieve") }
        XCTAssertTrue(learner.dictionary.entries.isEmpty)
    }
    func testAdjacentPicksBecomeAPhraseOnTheSecondTime() {
        let (learner, lexicon, decoder) = make()
        learner.pickedPhrase(text: "品瑞", reading: "ㄆㄧㄣˇ-ㄖㄨㄟˋ")
        XCTAssertTrue(learner.dictionary.entries.isEmpty)
        learner.pickedPhrase(text: "品瑞", reading: "ㄆㄧㄣˇ-ㄖㄨㄟˋ")
        XCTAssertEqual(learner.dictionary.entries.map(\.text), ["品瑞"])
        XCTAssertTrue(lexicon.hasEntry(word: "品瑞", reading: "ㄆㄧㄣˇ-ㄖㄨㄟˋ"))
        XCTAssertEqual(decoder.render(decoder.decode("qup3bjo4")), "品瑞")
    }
    func testDeletedWordIsNeverRelearned() {
        let (learner, _, _) = make()
        for _ in 0..<3 { learner.committed(english: "Zhizhi") }
        learner.delete("Zhizhi")
        XCTAssertTrue(learner.dictionary.entries.isEmpty)
        for _ in 0..<5 { learner.committed(english: "Zhizhi") }
        XCTAssertTrue(learner.dictionary.entries.isEmpty)
    }
    func testDictionaryRoundTripsAsText() {
        var dictionary = PersonalDictionary()
        dictionary.add(.init(text: "Claude Code", reading: "", source: .manual, added: Date(timeIntervalSince1970: 100)))
        dictionary.add(.init(text: "品瑞", reading: "ㄆㄧㄣˇ-ㄖㄨㄟˋ", source: .auto, added: Date(timeIntervalSince1970: 200)))
        dictionary.delete("垃圾")
        XCTAssertEqual(PersonalDictionary(tsv: dictionary.tsv, deleted: dictionary.deletedText), dictionary)
    }
    func testPlainWordListImports() {
        XCTAssertEqual(PersonalDictionary(tsv: "OpenAI\n# a comment\nClaude Code\n").entries.map(\.text), ["OpenAI", "Claude Code"])
    }
    func testLoadedDictionaryIsTypable() {
        let dictionary = PersonalDictionary(tsv: "品瑞\tㄆㄧㄣˇ-ㄖㄨㄟˋ\tmanual\t0\nOpenAI\t\tmanual\t0\n")
        let (_, _, decoder) = make(dictionary)
        XCTAssertEqual(decoder.render(decoder.decode("qup3bjo4")), "品瑞")
        XCTAssertEqual(decoder.render(decoder.decode("openai")), "OpenAI")
    }
}

final class HistoryTests: XCTestCase {
    var folder: URL!
    var now = Date(timeIntervalSince1970: 1_000_000_000)

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func make(key: SymmetricKey = SymmetricKey(size: .bits256)) -> SentenceHistory {
        SentenceHistory(file: folder.appendingPathComponent("h/history.enc"), key: key, clock: { [unowned self] in now })
    }

    func testStoredEncryptedPrivateAndOutOfBackups() throws {
        let history = make()
        try history.append("祕密的句子")
        let file = folder.appendingPathComponent("h/history.enc")
        let raw = try Data(contentsOf: file)
        XCTAssertNil(raw.range(of: Data("祕密".utf8)))
        XCTAssertEqual(history.items().map(\.text), ["祕密的句子"])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func testAnotherKeyReadsNothing() throws {
        try make().append("一句話")
        XCTAssertTrue(make().items().isEmpty)
    }
    func testNinetyDaysThenGone() throws {
        let history = make()
        try history.append("很久以前")
        now = now.addingTimeInterval(91 * 24 * 3600)
        try history.append("今天")
        XCTAssertEqual(history.items().map(\.text), ["今天"])
        try history.prune()
        let lines = try String(contentsOf: folder.appendingPathComponent("h/history.enc"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 1)
    }
    func testSearchDeleteClear() throws {
        let history = make()
        try history.append("買牛奶")
        now = now.addingTimeInterval(1)
        try history.append("開會")
        XCTAssertEqual(history.items(matching: "牛奶").map(\.text), ["買牛奶"])
        try history.delete(history.items(matching: "牛奶")[0])
        XCTAssertEqual(history.items().map(\.text), ["開會"])
        try history.clear()
        XCTAssertTrue(history.items().isEmpty)
    }
    func testExclusions() {
        XCTAssertTrue(LearningExclusions.excludes(bundleID: "com.1password.1password"))
        XCTAssertTrue(LearningExclusions.excludes(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(LearningExclusions.excludes(bundleID: nil))
        XCTAssertFalse(LearningExclusions.excludes(bundleID: "jp.naver.line.mac"))
    }
}
