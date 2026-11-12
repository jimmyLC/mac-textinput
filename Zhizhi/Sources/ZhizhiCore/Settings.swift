import Foundation

/// The owner's choices, shared by the App (which edits them) and the input method (which obeys them).
public struct Settings: Equatable {
    public enum Language: String, CaseIterable { case chineseFirst, englishFirst }
    public enum SwitchKey: String, CaseIterable { case leftShift, rightShift, none }
    public enum PunctuationWidth: String, CaseIterable { case follow, full, half }
    public enum AIModel: String, CaseIterable { case qwen, apple }

    public var language = Language.chineseFirst
    public var switchKey = SwitchKey.leftShift
    public var punctuation = PunctuationWidth.follow
    public var autoSpace = true
    public var tabOffers = true
    public var escapeClears = false
    public var candidatesPerPage = 9
    public var aiCorrections = true
    public var aiModel = AIModel.qwen
    public var learningPaused = false
    /// Seconds of no typing after which English mode returns to Chinese; 0 means never.
    public var englishIdleSeconds = 60
    public static let englishIdleChoices = [0, 30, 60, 120, 300]
    /// Off until the owner has verified on this Mac that secure fields bypass the input method.
    public var sentenceHistory = false

    public init() {}

    public static let suiteName = "com.jimmylc.inputmethod.Zhizhi"
    public static let pageSizes = 5...9
    /// Posted by the App after it changes settings or the dictionary files.
    public static let settingsChanged = Notification.Name("com.jimmylc.Zhizhi.settingsChanged")
    public static let dictionaryChanged = Notification.Name("com.jimmylc.Zhizhi.dictionaryChanged")

    /// The input method's own defaults, from either process. A suite named after the
    /// running app's bundle ID is rejected by the system, so that process uses `standard`.
    public static var sharedDefaults: UserDefaults {
        if Bundle.main.bundleIdentifier == suiteName { return .standard }
        return UserDefaults(suiteName: suiteName) ?? .standard
    }

    public init(defaults: UserDefaults) {
        defaults.synchronize()
        if let v = defaults.string(forKey: "Language").flatMap(Language.init) { language = v }
        if let v = defaults.string(forKey: "SwitchKey").flatMap(SwitchKey.init) { switchKey = v }
        if let v = defaults.string(forKey: "Punctuation").flatMap(PunctuationWidth.init) { punctuation = v }
        if defaults.object(forKey: "AutoSpace") != nil { autoSpace = defaults.bool(forKey: "AutoSpace") }
        if defaults.object(forKey: "TabOffers") != nil { tabOffers = defaults.bool(forKey: "TabOffers") }
        escapeClears = defaults.bool(forKey: "EscapeClears")
        let page = defaults.integer(forKey: "CandidatesPerPage")
        if Self.pageSizes.contains(page) { candidatesPerPage = page }
        aiCorrections = !defaults.bool(forKey: "AICorrectionsOff")
        if let v = defaults.string(forKey: "AIModel").flatMap(AIModel.init) { aiModel = v }
        learningPaused = defaults.bool(forKey: "LearningPaused")
        if defaults.object(forKey: "EnglishIdleSeconds") != nil { englishIdleSeconds = max(0, defaults.integer(forKey: "EnglishIdleSeconds")) }
        sentenceHistory = defaults.bool(forKey: "SentenceHistoryOn")
    }

    public func save(to defaults: UserDefaults) {
        defaults.set(language.rawValue, forKey: "Language")
        defaults.set(switchKey.rawValue, forKey: "SwitchKey")
        defaults.set(punctuation.rawValue, forKey: "Punctuation")
        defaults.set(autoSpace, forKey: "AutoSpace")
        defaults.set(tabOffers, forKey: "TabOffers")
        defaults.set(escapeClears, forKey: "EscapeClears")
        defaults.set(candidatesPerPage, forKey: "CandidatesPerPage")
        defaults.set(!aiCorrections, forKey: "AICorrectionsOff")
        defaults.set(aiModel.rawValue, forKey: "AIModel")
        defaults.set(learningPaused, forKey: "LearningPaused")
        defaults.set(englishIdleSeconds, forKey: "EnglishIdleSeconds")
        defaults.set(sentenceHistory, forKey: "SentenceHistoryOn")
        defaults.synchronize()
    }

    /// The key that flips a segment and toggles English mode; nil when turned off.
    public var switchKeyCode: UInt16? {
        switch switchKey {
        case .leftShift: return 56
        case .rightShift: return 60
        case .none: return nil
        }
    }

    public func apply(to decoder: Decoder) {
        decoder.preference = language == .englishFirst ? .englishFirst : .chineseFirst
        decoder.autoSpace = autoSpace
        decoder.punctuationWidth = punctuation
    }

    public func apply(to session: Session) {
        session.pageSize = candidatesPerPage
        session.tabOffers = tabOffers
        session.escapeClears = escapeClears
    }
}

/// Where everything lives. Tests point this at a temporary folder.
public struct ZhizhiPaths {
    public var support: URL
    public init(support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Zhizhi")) {
        self.support = support
    }
    public var dictionary: URL { support.appendingPathComponent("dictionary.tsv") }
    public var deleted: URL { support.appendingPathComponent("dictionary-deleted.txt") }
    public var learning: URL { support.appendingPathComponent("learning.json") }
    public var history: URL { support.appendingPathComponent("history.enc") }
    public var models: URL { support.appendingPathComponent("models") }
    public var backups: URL { support.appendingPathComponent("backups") }

    public func loadDictionary() -> PersonalDictionary {
        PersonalDictionary(tsv: (try? String(contentsOf: dictionary, encoding: .utf8)) ?? "",
                           deleted: (try? String(contentsOf: deleted, encoding: .utf8)) ?? "")
    }

    /// Adds learned entries to what is on disk now. A word the App deleted in the meantime stays deleted.
    @discardableResult
    public func merge(learned: [PersonalDictionary.Entry]) throws -> PersonalDictionary {
        var current = loadDictionary()
        for entry in learned where !current.deleted.contains(entry.text) { current.add(entry) }
        try save(current)
        return loadDictionary()    // exactly what is on disk, whole seconds included
    }

    public func save(_ value: PersonalDictionary) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try value.tsv.write(to: dictionary, atomically: true, encoding: .utf8)
        try value.deletedText.write(to: deleted, atomically: true, encoding: .utf8)
        for file in [dictionary, deleted] { try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
    }
}
