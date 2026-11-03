import Foundation

/// Jimmy's personal dictionary. English words (letters only) boost English detection and
/// Tab completion; Chinese phrases (with a Zhuyin reading) are written to McBopomofo's
/// user phrase file by the caller. The file never leaves this Mac.
struct UserDictionaryEntry: Codable, Equatable {
    var word: String
    var reading: String?   // Chinese only, syllables joined with "-"
    var auto: Bool?        // true when learned from typing rather than added by hand
    var isEnglish: Bool { reading == nil }
}

enum UserDictionaryError: Error { case empty, invalidEnglish, missingReading, duplicate }

final class UserDictionary {
    static var shared = UserDictionary(
        file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhuyinLM/user-dictionary.json"))

    private(set) var entries: [UserDictionaryEntry] = []
    private let file: URL
    /// First known reading of each character, used to suggest a reading for new Chinese words.
    var characterReadings: [Character: String] = [:]

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([UserDictionaryEntry].self, from: data) { entries = saved }
    }

    var englishWords: [String] { entries.filter { $0.isEnglish }.map { $0.word } }

    static func isEnglishWord(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }
    }

    /// Suggested Zhuyin for a Chinese word, nil if some character is unknown.
    func suggestedReading(for word: String) -> String? {
        let parts = word.map { characterReadings[$0] }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.map { $0! }.joined(separator: "-")
    }

    @discardableResult
    func add(word raw: String, reading rawReading: String?, auto: Bool = false) throws -> UserDictionaryEntry {
        let word = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { throw UserDictionaryError.empty }
        var entry: UserDictionaryEntry
        if word.unicodeScalars.allSatisfy({ $0.isASCII }) {
            guard Self.isEnglishWord(word) else { throw UserDictionaryError.invalidEnglish }
            entry = UserDictionaryEntry(word: word, reading: nil, auto: auto ? true : nil)
        } else {
            let reading = (rawReading?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 }
                ?? suggestedReading(for: word)
            guard let reading else { throw UserDictionaryError.missingReading }
            entry = UserDictionaryEntry(word: word, reading: reading.replacingOccurrences(of: " ", with: "-"))
        }
        guard !entries.contains(where: { $0.word == entry.word }) else { throw UserDictionaryError.duplicate }
        entries.append(entry)
        save()
        return entry
    }

    func remove(word: String) {
        entries.removeAll { $0.word == word }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}
