import XCTest
@testable import ZhizhiCore

final class SettingsTests: XCTestCase {
    var defaults: UserDefaults!
    let suite = "zhizhi.tests.\(UUID().uuidString)"

    override func setUp() { defaults = UserDefaults(suiteName: suite) }
    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testDefaultsWhenNothingIsSaved() {
        let s = Settings(defaults: defaults)
        XCTAssertEqual(s, Settings())
        XCTAssertTrue(s.aiCorrections)
        XCTAssertFalse(s.sentenceHistory, "history stays off until the owner turns it on")
    }
    func testRoundTrip() {
        var s = Settings()
        s.language = .englishFirst
        s.switchKey = .rightShift
        s.punctuation = .half
        s.autoSpace = false
        s.tabOffers = false
        s.escapeClears = true
        s.candidatesPerPage = 5
        s.aiCorrections = false
        s.aiModel = .apple
        s.learningPaused = true
        s.sentenceHistory = true
        s.save(to: defaults)
        XCTAssertEqual(Settings(defaults: defaults), s)
    }
    func testQwenStaysTheDefaultModel() {
        XCTAssertEqual(Settings(defaults: defaults).aiModel, .qwen)
        defaults.set("nonsense", forKey: "AIModel")
        XCTAssertEqual(Settings(defaults: defaults).aiModel, .qwen)
    }
    func testBadPageSizeFallsBack() {
        defaults.set(99, forKey: "CandidatesPerPage")
        XCTAssertEqual(Settings(defaults: defaults).candidatesPerPage, 9)
    }
    func testOlderKeysStillCount() {
        defaults.set(true, forKey: "AICorrectionsOff")
        defaults.set(true, forKey: "SentenceHistoryOn")
        let s = Settings(defaults: defaults)
        XCTAssertFalse(s.aiCorrections)
        XCTAssertTrue(s.sentenceHistory)
    }
}

final class SettingsBehaviourTests: XCTestCase {
    func decoder() -> Decoder { Decoder(lexicon: DecoderTests.lexicon) }

    func testPunctuationWidth() {
        let d = decoder()
        var s = Settings()
        s.punctuation = .half
        s.apply(to: d)
        XCTAssertTrue(d.render(d.decode("su3cl3:")).hasSuffix(":"))
        s.punctuation = .full
        s.apply(to: d)
        XCTAssertTrue(d.render(d.decode("hello:")).hasSuffix("："))
    }
    func testAutoSpaceOff() {
        let d = decoder()
        var s = Settings()
        s.autoSpace = false
        s.apply(to: d)
        XCTAssertEqual(d.render(d.decode("su3cl3hello")), "你好hello")
    }
    func testCandidatesPerPage() {
        let session = Session(decoder: decoder())
        var s = Settings()
        s.candidatesPerPage = 5
        s.apply(to: session)
        "su3".forEach { _ = session.handle(.character($0)) }
        let list = session.handle(.down).candidates
        XCTAssertEqual(list?.items.count, 5)
    }
    func testTabOffersOff() {
        let session = Session(decoder: decoder())
        var s = Settings()
        s.tabOffers = false
        s.apply(to: session)
        var last = Session.Output()
        "hel".forEach { last = session.handle(.character($0)) }
        XCTAssertNil(last.offer)
        XCTAssertEqual(session.handle(.tab).composing, last.composing)
    }
    func testEscapeClearsOnlyWhenAsked() {
        let session = Session(decoder: decoder())
        "su3".forEach { _ = session.handle(.character($0)) }
        _ = session.handle(.escape)
        XCTAssertTrue(session.isComposing)
        var s = Settings()
        s.escapeClears = true
        s.apply(to: session)
        _ = session.handle(.escape)
        XCTAssertFalse(session.isComposing)
    }
    func testSwitchKey() {
        var mode = TypingMode()
        let now = Date()
        mode.setSwitchKey(60)
        _ = mode.flagsChanged(keyCode: 56, shift: true, composing: false, now: now)
        XCTAssertNil(mode.flagsChanged(keyCode: 56, shift: false, composing: false, now: now))
        _ = mode.flagsChanged(keyCode: 60, shift: true, composing: false, now: now)
        XCTAssertEqual(mode.flagsChanged(keyCode: 60, shift: false, composing: false, now: now), .englishChanged(true))
        mode.setSwitchKey(nil)
        XCTAssertFalse(mode.englishMode, "no key would be left to turn it off")
    }
}

final class DictionarySyncTests: XCTestCase {
    func make() -> (Learner, Decoder, Lexicon) {
        let lexicon = Lexicon()
        lexicon.loadChinese(tsv: "品\t-5\tㄆㄧㄣˇ\n瑞\t-6\tㄖㄨㄟˋ\n銳\t-5\tㄖㄨㄟˋ\n品質\t-4\tㄆㄧㄣˇ-ㄓˊ\n")
        lexicon.loadEnglish(text: "hello\n")
        return (Learner(lexicon: lexicon), Decoder(lexicon: lexicon), lexicon)
    }
    func testReloadAddsAndRemoves() {
        let (learner, decoder, lexicon) = make()
        learner.reload(PersonalDictionary(tsv: "品瑞\tㄆㄧㄣˇ-ㄖㄨㄟˋ\tmanual\t0\nOpenAI\t\tmanual\t0\n"))
        XCTAssertEqual(decoder.render(decoder.decode("qup3bjo4")), "品瑞")
        XCTAssertEqual(decoder.render(decoder.decode("openai")), "OpenAI")
        learner.reload(PersonalDictionary())
        XCTAssertFalse(lexicon.hasEntry(word: "品瑞", reading: "ㄆㄧㄣˇ-ㄖㄨㄟˋ"))
        XCTAssertNil(lexicon.userEnglish["openai"])
        XCTAssertTrue(lexicon.userEntries.isEmpty)
    }
    func testDeletedListFromTheAppBlocksLearning() {
        let (learner, _, _) = make()
        learner.reload(PersonalDictionary(tsv: "", deleted: "Zhizhi\n"))
        for _ in 0..<5 { learner.committed(english: "Zhizhi") }
        XCTAssertTrue(learner.dictionary.entries.isEmpty)
    }
    func testSuggestedReading() {
        let (_, _, lexicon) = make()
        XCTAssertEqual(lexicon.suggestedReading(for: "品質"), "ㄆㄧㄣˇ-ㄓˊ")
        XCTAssertEqual(lexicon.suggestedReading(for: "品瑞"), "ㄆㄧㄣˇ-ㄖㄨㄟˋ")
        XCTAssertEqual(lexicon.suggestedReading(for: "品ID"), "ㄆㄧㄣˇ")
        XCTAssertEqual(lexicon.suggestedReading(for: "OpenAI"), "")
    }
    func testLearnedWordsDoNotUndoWhatTheAppChanged() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = ZhizhiPaths(support: folder)
        let (learner, _, _) = make()
        for _ in 0..<3 { learner.committed(english: "Zhizhi") }
        for _ in 0..<3 { learner.committed(english: "Gone") }
        // Meanwhile the App adds one word and deletes another.
        var edited = PersonalDictionary()
        edited.add(.init(text: "依建議", reading: "", source: .manual, added: Date(timeIntervalSince1970: 1)))
        edited.delete("Gone")
        try paths.save(edited)
        let merged = try paths.merge(learned: learner.takeUnsaved())
        XCTAssertEqual(merged.entries.map(\.text), ["依建議", "Zhizhi"])
        XCTAssertEqual(paths.loadDictionary(), merged)
        XCTAssertTrue(learner.takeUnsaved().isEmpty)
        learner.reload(merged)
        XCTAssertEqual(learner.dictionary, merged)
    }
    func testDictionaryFilesRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let paths = ZhizhiPaths(support: folder)
        var dictionary = PersonalDictionary()
        dictionary.add(.init(text: "Claude Code", reading: "", source: .manual, added: Date(timeIntervalSince1970: 5)))
        dictionary.delete("垃圾")
        try paths.save(dictionary)
        XCTAssertEqual(paths.loadDictionary(), dictionary)
        let permissions = try FileManager.default.attributesOfItem(atPath: paths.dictionary.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}

final class InstallerTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func app(_ path: String, build: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info: NSDictionary = ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": build]
        info.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
        return url
    }
    func make(bundled: URL) -> Installer {
        Installer(bundled: bundled, installed: root.appendingPathComponent("Input Methods/Zhizhi.app"), backups: root.appendingPathComponent("backups"))
    }

    func testFreshInstall() throws {
        let installer = make(bundled: try app("in/Zhizhi.app", build: "2"))
        XCTAssertEqual(installer.state, .notInstalled)
        XCTAssertFalse(installer.canRestore)
        try installer.install()
        XCTAssertEqual(installer.state, .current(version: "0.1.0"))
        XCTAssertFalse(installer.canRestore, "nothing was replaced")
    }
    func testUpdateKeepsThePreviousCopyAndRestoreSwapsBack() throws {
        var installer = make(bundled: try app("old/Zhizhi.app", build: "1"))
        try installer.install()
        installer.bundled = try app("new/Zhizhi.app", build: "2")
        XCTAssertEqual(installer.state, .outdated(installed: "0.1.0 (1)", bundled: "0.1.0 (2)"))
        try installer.install()
        XCTAssertEqual(Installer.version(of: installer.installed)?.build, "2")
        XCTAssertEqual(installer.backupVersion, "0.1.0 (1)")
        try installer.restore()
        XCTAssertEqual(Installer.version(of: installer.installed)?.build, "1")
        XCTAssertEqual(installer.backupVersion, "0.1.0 (2)", "restoring can be undone")
    }
    func testMissingBundleChangesNothing() throws {
        var installer = make(bundled: try app("old/Zhizhi.app", build: "1"))
        try installer.install()
        installer.bundled = root.appendingPathComponent("nope.app")
        XCTAssertThrowsError(try installer.install())
        XCTAssertEqual(Installer.version(of: installer.installed)?.build, "1")
    }
}

final class ModelDownloaderTests: XCTestCase {
    var root: URL!
    var source: URL!
    var target: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = root.appendingPathComponent("source/")
        target = root.appendingPathComponent("models/m")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func file(_ name: String, _ text: String) throws -> ModelManifest.File {
        let url = source.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return .init(name: name, size: Int64(text.utf8.count), sha256: try ModelDownloader.sha256(of: url))
    }
    func run(_ downloader: ModelDownloader) -> Result<Void, Error> {
        let done = expectation(description: "finished")
        var result: Result<Void, Error>?
        downloader.start(progress: { _ in }) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 20)
        return result!
    }

    func testDownloadsAndInstalls() throws {
        let manifest = ModelManifest(name: "m", baseURL: source, files: [try file("config.json", "{}"), try file("model.safetensors", "weights")])
        let downloader = ModelDownloader(manifest: manifest, folder: target)
        XCTAssertFalse(downloader.isInstalled)
        if case .failure(let error) = run(downloader) { XCTFail("\(error)") }
        XCTAssertTrue(downloader.isInstalled)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("model.safetensors"), encoding: .utf8), "weights")
    }
    func testJoinsPiecesIntoOneFile() throws {
        let manifest = ModelManifest(name: "m", baseURL: source, files: [try file("model.safetensors.part1", "wei"), try file("model.safetensors.part2", "ghts")],
                                     assemble: ["model.safetensors": ["model.safetensors.part1", "model.safetensors.part2"]])
        let downloader = ModelDownloader(manifest: manifest, folder: target)
        if case .failure(let error) = run(downloader) { XCTFail("\(error)") }
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("model.safetensors"), encoding: .utf8), "weights")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("model.safetensors.part1").path))
    }
    func testWrongHashNeverLooksInstalled() throws {
        var bad = try file("model.safetensors", "weights")
        bad.sha256 = String(repeating: "0", count: 64)
        let downloader = ModelDownloader(manifest: ModelManifest(name: "m", baseURL: source, files: [bad]), folder: target)
        guard case .failure(let error) = run(downloader), case ModelDownloader.Failure.hashMismatch = error else { return XCTFail("expected a hash failure") }
        XCTAssertFalse(downloader.isInstalled)
    }
    func testRemoveOnALinkLeavesItsTarget() throws {
        let real = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("w".utf8).write(to: real.appendingPathComponent("model.safetensors"))
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: real)
        let downloader = ModelDownloader(manifest: ModelManifest(name: "m", baseURL: source, files: []), folder: target)
        XCTAssertTrue(downloader.isInstalled)
        try downloader.remove()
        XCTAssertFalse(downloader.isInstalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("model.safetensors").path))
    }
    func testBundledManifestCoversWhatTheHelperLoads() {
        let names = Set(ModelManifest.qwen.files.map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["config.json", "tokenizer.json", "tokenizer_config.json"]))
        XCTAssertEqual(ModelManifest.qwen.assemble.keys.sorted(), ["model.safetensors"])
        XCTAssertTrue(names.isSuperset(of: ModelManifest.qwen.assemble["model.safetensors"] ?? ["x"]))
        XCTAssertGreaterThan(ModelManifest.qwen.totalSize, 800_000_000)
    }
}
