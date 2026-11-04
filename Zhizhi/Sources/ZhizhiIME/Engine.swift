import CryptoKit
import Foundation
import Security
import ZhizhiCore

/// The dictionaries, learning and local AI shared by every input session in this process.
final class Engine {
    static let shared = Engine()
    /// A swap must raise the sentence's log-probability by this much (eval/README.md).
    static let correctionThreshold: Float = 2.5
    static let modelName = "Qwen2.5-1.5B-4bit"

    private(set) var decoder: Decoder = Decoder(lexicon: Lexicon())
    private(set) var learner: Learner?
    private(set) lazy var ai = HelperClient(
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zhizhi-ai"),
        model: Self.support.appendingPathComponent("models/\(Self.modelName)"))
    private let saving = DispatchQueue(label: "zhizhi.save")
    private var saveScheduled = false

    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Zhizhi")
    private static let dictionaryFile = support.appendingPathComponent("dictionary.tsv")
    private static let deletedFile = support.appendingPathComponent("dictionary-deleted.txt")
    private static let learningFile = support.appendingPathComponent("learning.json")

    func load() {
        let lexicon = Lexicon()
        guard let resources = Bundle.main.resourceURL else { return }
        if let chinese = try? String(contentsOf: resources.appendingPathComponent("chinese-lexicon.tsv"), encoding: .utf8) {
            lexicon.loadChinese(tsv: chinese)
        }
        if let english = try? String(contentsOf: resources.appendingPathComponent("english-words.txt"), encoding: .utf8) {
            lexicon.loadEnglish(text: english)
        }
        let dictionary = PersonalDictionary(
            tsv: (try? String(contentsOf: Self.dictionaryFile, encoding: .utf8)) ?? "",
            deleted: (try? String(contentsOf: Self.deletedFile, encoding: .utf8)) ?? "")
        let state = (try? Data(contentsOf: Self.learningFile)).flatMap { try? JSONDecoder().decode(Learner.State.self, from: $0) }
        let learner = Learner(lexicon: lexicon, dictionary: dictionary, state: state ?? Learner.State())
        learner.onChange = { [weak self] in self?.scheduleSave() }
        self.learner = learner
        decoder = Decoder(lexicon: lexicon)
        if Preferences.sentenceHistory { try? history()?.prune() }
    }

    /// Saves a moment after the last change, off the main thread, so typing never waits for the disk.
    private func scheduleSave() {
        guard !saveScheduled, let learner else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.saveScheduled = false
            let tsv = learner.dictionary.tsv, deleted = learner.dictionary.deletedText
            let state = try? JSONEncoder().encode(learner.state)
            self?.saving.async {
                let fm = FileManager.default
                try? fm.createDirectory(at: Self.support, withIntermediateDirectories: true)
                try? tsv.write(to: Self.dictionaryFile, atomically: true, encoding: .utf8)
                try? deleted.write(to: Self.deletedFile, atomically: true, encoding: .utf8)
                try? state?.write(to: Self.learningFile, options: .atomic)
                for file in [Self.dictionaryFile, Self.deletedFile, Self.learningFile] {
                    try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            }
        }
    }

    /// Nil when the key cannot be obtained: then nothing is kept.
    func history() -> SentenceHistory? {
        guard let key = Keychain.historyKey() else { return nil }
        return SentenceHistory(file: Self.support.appendingPathComponent("history.enc"), key: key)
    }

    func clearHistory() {
        saving.async { [self] in try? history()?.clear() }
    }

    func keep(sentence: String) {
        saving.async { [self] in try? history()?.append(sentence) }
    }
}

/// Owner's choices; the App's preference pages will edit these later.
enum Preferences {
    private static let defaults = UserDefaults.standard
    static var aiCorrections: Bool {
        get { !defaults.bool(forKey: "AICorrectionsOff") }
        set { defaults.set(!newValue, forKey: "AICorrectionsOff") }
    }
    static var learningPaused: Bool {
        get { defaults.bool(forKey: "LearningPaused") }
        set { defaults.set(newValue, forKey: "LearningPaused") }
    }
    /// Off until the owner has verified on this Mac that secure fields bypass the input method.
    static var sentenceHistory: Bool {
        get { defaults.bool(forKey: "SentenceHistoryOn") }
        set { defaults.set(newValue, forKey: "SentenceHistoryOn") }
    }
}

/// The sentence history's key, in the login Keychain on this device only.
enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jimmylc.inputmethod.Zhizhi.history",
        kSecAttrAccount as String: "sentence-history-key",
    ]

    static func historyKey() -> SymmetricKey? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var found: CFTypeRef?
        if SecItemCopyMatching(lookup as CFDictionary, &found) == errSecSuccess, let data = found as? Data {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        var add = query
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? key : nil
    }
}

/// Opt-in local log of keys and routing, for finding misjudgements. Off by default, turns itself
/// off after 24 hours, keeps 7 days and 2 MB, readable only by the owner, never uploaded.
final class DebugLog {
    static let shared = DebugLog()
    private let enabledKey = "DebugLogEnabledAt"
    private let queue = DispatchQueue(label: "zhizhi.debuglog")
    private let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()
    let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Zhizhi/debug-log.txt")

    var enabled: Bool {
        get {
            guard let since = UserDefaults.standard.object(forKey: enabledKey) as? Date else { return false }
            if Date().timeIntervalSince(since) > 24 * 3600 {
                UserDefaults.standard.removeObject(forKey: enabledKey)
                return false
            }
            return true
        }
        set {
            if newValue { UserDefaults.standard.set(Date(), forKey: enabledKey); prune() }
            else { UserDefaults.standard.removeObject(forKey: enabledKey) }
        }
    }

    func record(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let entry = stamp.string(from: Date()) + " " + line() + "\n"
        queue.async { [file] in
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        }
    }

    private func prune() {
        queue.async { [file, stamp] in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let cutoff = stamp.string(from: Date().addingTimeInterval(-7 * 86400))
            var lines = text.split(separator: "\n").filter { String($0.prefix(23)) >= cutoff }
            var size = lines.reduce(0) { $0 + $1.utf8.count + 1 }
            while size > 2 * 1024 * 1024, !lines.isEmpty { size -= lines.removeFirst().utf8.count + 1 }
            try? (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func clear() { queue.async { [file] in try? FileManager.default.removeItem(at: file) } }
}
