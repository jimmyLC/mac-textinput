import Foundation

/// Opt-in, local-only log of how each key was routed, for debugging misjudged English/Chinese.
/// Off by default; turns itself off after 24 hours; entries older than 7 days and anything
/// beyond 2 MB are dropped. Keys are recorded, so the file can reveal what was typed: it is
/// readable only by the user, never uploaded, and can be cleared at any time.
final class DebugLog {
    static var shared = DebugLog(
        file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhuyinLM/debug-log.txt"),
        defaults: .standard)

    static let autoOff: TimeInterval = 24 * 3600
    static let keepDays = 7
    static let maxBytes = 2 * 1024 * 1024
    private static let enabledKey = "DebugLogEnabledAt"

    let file: URL
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "zhuyinlm.debuglog")
    private let stamp: DateFormatter

    init(file: URL, defaults: UserDefaults) {
        self.file = file
        self.defaults = defaults
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    }

    /// True while logging is on (and not past its 24 hour limit).
    var enabled: Bool {
        get {
            guard let since = defaults.object(forKey: Self.enabledKey) as? Date else { return false }
            if Date().timeIntervalSince(since) > Self.autoOff {
                defaults.removeObject(forKey: Self.enabledKey)
                return false
            }
            return true
        }
        set {
            if newValue { defaults.set(Date(), forKey: Self.enabledKey); prune() }
            else { defaults.removeObject(forKey: Self.enabledKey) }
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

    /// Drops entries older than a week and trims the file to the size limit (newest kept).
    func prune(now: Date = Date()) {
        queue.sync {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
            let cutoff = stamp.string(from: now.addingTimeInterval(-Double(Self.keepDays) * 86400))
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true).filter { String($0.prefix(23)) >= cutoff }
            var size = lines.reduce(0) { $0 + $1.utf8.count + 1 }
            while size > Self.maxBytes, !lines.isEmpty { size -= lines.removeFirst().utf8.count + 1 }
            let out = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
            try? out.write(to: file, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    func clear() { queue.sync { try? FileManager.default.removeItem(at: file) } }

    /// Waits for pending writes (tests).
    func flush() { queue.sync {} }
}
