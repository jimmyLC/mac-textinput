import Foundation
import ZhizhiCore

/// The dictionaries shared by every input session in this process.
final class Engine {
    static let shared = Engine()
    private(set) var decoder: Decoder = Decoder(lexicon: Lexicon())

    func load() {
        let lexicon = Lexicon()
        guard let resources = Bundle.main.resourceURL else { return }
        if let chinese = try? String(contentsOf: resources.appendingPathComponent("chinese-lexicon.tsv"), encoding: .utf8) {
            lexicon.loadChinese(tsv: chinese)
        }
        if let english = try? String(contentsOf: resources.appendingPathComponent("english-words.txt"), encoding: .utf8) {
            lexicon.loadEnglish(text: english)
        }
        decoder = Decoder(lexicon: lexicon)
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
