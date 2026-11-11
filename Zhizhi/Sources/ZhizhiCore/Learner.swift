import CryptoKit
import Foundation

/// The personal dictionary as plain tab-separated text, so it can be read, edited, imported and exported.
public struct PersonalDictionary: Equatable {
    public enum Source: String { case manual, auto }
    public struct Entry: Equatable {
        public var text: String
        public var reading: String     // Chinese: syllables joined with "-"; empty for English
        public var source: Source
        public var added: Date
        public init(text: String, reading: String, source: Source, added: Date) {
            self.text = text; self.reading = reading; self.source = source; self.added = added
        }
    }

    public private(set) var entries: [Entry] = []
    public private(set) var deleted: Set<String> = []    // never learned again

    public init() {}

    /// Rows are `text<TAB>reading<TAB>source<TAB>unix time`; only the text is required.
    public init(tsv: String, deleted: String = "") {
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let text = f.first, !text.isEmpty else { continue }
            add(Entry(text: text, reading: f.count > 1 ? f[1] : "",
                      source: f.count > 2 ? Source(rawValue: f[2]) ?? .manual : .manual,
                      added: Date(timeIntervalSince1970: f.count > 3 ? Double(f[3]) ?? 0 : 0)))
        }
        self.deleted = Set(deleted.split(separator: "\n").map(String.init))
    }

    public var tsv: String {
        entries.map { "\($0.text)\t\($0.reading)\t\($0.source.rawValue)\t\(Int($0.added.timeIntervalSince1970))\n" }.joined()
    }

    public var deletedText: String { deleted.sorted().map { $0 + "\n" }.joined() }

    /// Returns false when the entry exists already.
    @discardableResult
    public mutating func add(_ entry: Entry) -> Bool {
        guard !entries.contains(where: { $0.text == entry.text }) else { return false }
        entries.append(entry)
        return true
    }

    /// The user added it back by hand, so it may stay and learning may see it again.
    public mutating func allow(_ text: String) { deleted.remove(text) }

    /// Removes an entry for good: learning will not bring it back.
    public mutating func delete(_ text: String) {
        entries.removeAll { $0.text == text }
        deleted.insert(text)
    }

    public func load(into lexicon: Lexicon) {
        for entry in entries {
            if entry.text.first?.isASCII == true, entry.reading.isEmpty {
                lexicon.addUserEnglish(entry.text)
            } else if entry.reading.isEmpty {
                lexicon.addUserEntry(entry.text, reading: nil)
            } else {
                lexicon.addUserChinese(entry.text, reading: entry.reading)
            }
        }
    }
}

/// What typing teaches: chosen words rise, and new words join the dictionary as "auto".
/// Counts are kept as salted hashes, so a word below its threshold cannot be read from disk.
public final class Learner {
    public static let englishThreshold = 3          // an unknown English word typed this many times is added
    public static let phraseThreshold = 2           // characters picked side by side this many times are added
    static let characterStep: Float = 1, characterLimit: Float = 3
    static let wordStep: Float = 2, wordLimit: Float = 4

    public struct State: Codable, Equatable {
        public var salt = UUID().uuidString
        public var counts: [String: Int] = [:]        // hash of a word -> times seen
        public var boosts: [String: Boost] = [:]      // word + reading -> how often it was chosen
        public init() {}
    }
    public struct Boost: Codable, Equatable {
        public var word: String
        public var reading: String
        public var picks: Int
    }

    public private(set) var dictionary: PersonalDictionary
    public private(set) var state: State
    private var unsaved: [PersonalDictionary.Entry] = []
    private let lexicon: Lexicon
    private let clock: () -> Date
    /// Called after anything changed, so the owner can save.
    public var onChange: (() -> Void)?

    public init(lexicon: Lexicon, dictionary: PersonalDictionary = PersonalDictionary(), state: State = State(), clock: @escaping () -> Date = Date.init) {
        self.lexicon = lexicon
        self.dictionary = dictionary
        self.state = state
        self.clock = clock
        dictionary.load(into: lexicon)
        for boost in state.boosts.values { apply(boost) }
    }

    /// A candidate the user chose. Common words rise; they never become dictionary entries.
    public func picked(word: String, reading: String) {
        guard word.count >= 1, !reading.isEmpty else { return }
        let key = word + "\t" + reading
        var boost = state.boosts[key] ?? Boost(word: word, reading: reading, picks: 0)
        boost.picks += 1
        state.boosts[key] = boost
        apply(boost)
        onChange?()
    }

    private func apply(_ boost: Boost) {
        let single = boost.word.count == 1
        let amount = min(Float(boost.picks) * (single ? Self.characterStep : Self.wordStep), single ? Self.characterLimit : Self.wordLimit)
        lexicon.setBoost(word: boost.word, reading: boost.reading, amount: amount)
    }

    /// Characters picked one by one and next to each other: probably a word the lexicon lacks.
    public func pickedPhrase(text: String, reading: String) {
        guard text.count >= 2, !lexicon.hasEntry(word: text, reading: reading), count(text) >= Self.phraseThreshold else { return }
        add(PersonalDictionary.Entry(text: text, reading: reading, source: .auto, added: clock()))
    }

    /// An English word that was committed. Known words and likely misspellings are ignored.
    public func committed(english word: String) {
        let lower = word.lowercased()
        guard word.count >= 3, word.allSatisfy({ $0.isASCII && $0.isLetter }),
              lexicon.englishRank[lower] == nil, lexicon.userEnglish[lower] == nil,
              lexicon.spellingFix(for: lower) == nil,
              count(lower) >= Self.englishThreshold else { return }
        add(PersonalDictionary.Entry(text: word, reading: "", source: .auto, added: clock()))
    }

    private func count(_ text: String) -> Int {
        let digest = SHA256.hash(data: Data((state.salt + text).utf8))
        let key = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let next = (state.counts[key] ?? 0) + 1
        state.counts[key] = next
        onChange?()
        return next
    }

    private func add(_ entry: PersonalDictionary.Entry) {
        guard !dictionary.deleted.contains(entry.text), dictionary.add(entry) else { return }
        unsaved.append(entry)
        if entry.reading.isEmpty { lexicon.addUserEnglish(entry.text) }
        else { lexicon.addUserChinese(entry.text, reading: entry.reading) }
        onChange?()
    }

    /// Entries learned since the last call. The files stay the source of truth, so these get
    /// merged into them instead of overwriting what the App may have changed.
    public func takeUnsaved() -> [PersonalDictionary.Entry] {
        defer { unsaved.removeAll() }
        return unsaved
    }

    /// Takes over a dictionary edited elsewhere (the App), adjusting typing to match.
    public func reload(_ new: PersonalDictionary) {
        for old in dictionary.entries where !new.entries.contains(where: { $0.text == old.text && $0.reading == old.reading }) {
            if old.reading.isEmpty { lexicon.removeUserEntry(old.text) }
            else { lexicon.removeUserChinese(old.text, reading: old.reading) }
        }
        var added = PersonalDictionary()
        for entry in new.entries where !dictionary.entries.contains(where: { $0.text == entry.text && $0.reading == entry.reading }) {
            added.add(entry)
        }
        added.load(into: lexicon)
        dictionary = new
    }

    /// Removes an entry from the dictionary and from typing, for good.
    public func delete(_ text: String) {
        dictionary.delete(text)
        lexicon.removeUserEntry(text)
        onChange?()
    }
}
