import Foundation
import ZhizhiCore

/// The dictionaries, learning and local AI shared by every input session in this process.
final class Engine {
    static let shared = Engine()
    /// A swap must raise the sentence's log-probability by this much (eval/README.md).
    static let correctionThreshold: Float = 2.5
    let paths = ZhizhiPaths()
    private(set) var settings = Settings(defaults: Settings.sharedDefaults)

    private(set) var decoder: Decoder = Decoder(lexicon: Lexicon())
    private(set) var learner: Learner?
    private lazy var qwen = HelperClient(
        executable: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/zhizhi-ai"),
        model: paths.models.appendingPathComponent(ModelManifest.qwen.name))
    private let apple = AppleModelBackend()
    /// The model the owner chose. If it cannot run, there are no corrections: it never quietly uses the other.
    var ai: CorrectionBackend { settings.aiModel == .apple ? apple : qwen }
    var aiFailure: String? { settings.aiModel == .apple ? apple.lastFailure : nil }
    private let saving = DispatchQueue(label: "zhizhi.save")
    private var saveScheduled = false

    func load() {
        let lexicon = Lexicon()
        guard let resources = Bundle.main.resourceURL else { return }
        if let chinese = try? String(contentsOf: resources.appendingPathComponent("chinese-lexicon.tsv"), encoding: .utf8) {
            lexicon.loadChinese(tsv: chinese)
        }
        if let english = try? String(contentsOf: resources.appendingPathComponent("english-words.txt"), encoding: .utf8) {
            lexicon.loadEnglish(text: english)
        }
        let state = (try? Data(contentsOf: paths.learning)).flatMap { try? JSONDecoder().decode(Learner.State.self, from: $0) }
        let learner = Learner(lexicon: lexicon, dictionary: paths.loadDictionary(), state: state ?? Learner.State())
        learner.onChange = { [weak self] in self?.scheduleSave() }
        self.learner = learner
        decoder = Decoder(lexicon: lexicon)
        settings.apply(to: decoder)
        if settings.sentenceHistory { try? history()?.prune() }

        // The App edits settings and the dictionary; this process follows along.
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: Settings.settingsChanged, object: nil, queue: .main) { [weak self] _ in self?.reloadSettings() }
        center.addObserver(forName: Settings.dictionaryChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.learner?.reload(self.paths.loadDictionary())
        }
    }

    private func reloadSettings() {
        settings = Settings(defaults: Settings.sharedDefaults)
        settings.apply(to: decoder)
        releaseUnusedModel()
    }

    /// A change made from the input menu.
    func update(_ change: (inout Settings) -> Void) {
        change(&settings)
        settings.save(to: Settings.sharedDefaults)
        settings.apply(to: decoder)
        releaseUnusedModel()
    }

    /// Qwen holds over a gigabyte while loaded: let go as soon as it is not the model in use.
    private func releaseUnusedModel() {
        if !settings.aiCorrections || settings.aiModel != .qwen { qwen.stop() }
    }

    /// Saves a moment after the last change, off the main thread, so typing never waits for the disk.
    private func scheduleSave() {
        guard !saveScheduled, let learner else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let learned = learner.takeUnsaved(), paths = self.paths
            let state = try? JSONEncoder().encode(learner.state)
            self.saving.async {
                if !learned.isEmpty, let merged = try? paths.merge(learned: learned) {
                    DispatchQueue.main.async { learner.reload(merged) }
                }
                try? FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
                try? state?.write(to: paths.learning, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.learning.path)
            }
        }
    }

    /// Nil when the key cannot be obtained: then nothing is kept.
    func history() -> SentenceHistory? {
        guard let key = Keychain.historyKey() else { return nil }
        return SentenceHistory(file: paths.history, key: key)
    }

    func clearHistory() {
        saving.async { [self] in try? history()?.clear() }
    }

    func keep(sentence: String) {
        saving.async { [self] in try? history()?.append(sentence) }
    }
}

/// Opt-in local log of keys and routing, for finding misjudgements. Off by default, turns itself
/// off after 90 days, keeps 7 days and 2 MB, readable only by the owner, never uploaded.
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
            if Date().timeIntervalSince(since) > 90 * 86400 {
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
