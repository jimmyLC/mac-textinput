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
    private var maintenance: DispatchSourceTimer?
    private let maintenanceLock = NSLock()

    init(file: URL, defaults: UserDefaults) {
        self.file = file
        self.defaults = defaults
        stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
    }

    deinit { maintenance?.cancel() }

    private func startMaintenance() {
        // No I/O in init: tests may replace the shared logger before its first use.
        maintenanceLock.lock()
        defer { maintenanceLock.unlock() }
        guard maintenance == nil else { return }
        queue.sync { pruneOnQueue(now: Date()) }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3600, repeating: 3600)
        timer.setEventHandler { [weak self] in self?.pruneOnQueue(now: Date()) }
        timer.resume()
        maintenance = timer
    }

    /// True while logging is on (and not past its 24 hour limit).
    var enabled: Bool {
        get {
            startMaintenance()
            guard let since = defaults.object(forKey: Self.enabledKey) as? Date else { return false }
            if Date().timeIntervalSince(since) > Self.autoOff {
                defaults.removeObject(forKey: Self.enabledKey)
                queue.async { [weak self] in self?.pruneOnQueue(now: Date()) }
                return false
            }
            return true
        }
        set {
            startMaintenance()
            if newValue { defaults.set(Date(), forKey: Self.enabledKey); prune() }
            else { defaults.removeObject(forKey: Self.enabledKey) }
        }
    }

    func record(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        let value = line()
        let now = Date()
        queue.async { [self] in
            let entry = Data((stamp.string(from: now) + " " + value + "\n").utf8)
            // A single oversized entry cannot satisfy the cap; leave existing history intact.
            guard entry.count <= Self.maxBytes else { return }
            let fm = FileManager.default
            try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + entry.count > Self.maxBytes {
                pruneOnQueue(now: now, limit: Self.maxBytes - entry.count)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard let handle = try? FileHandle(forWritingTo: file) else { return }
            handle.seekToEndOfFile()
            handle.write(entry)
            try? handle.close()
        }
    }

    /// Drops entries older than a week and trims the file to the size limit (newest kept).
    func prune(now: Date = Date()) {
        queue.sync { pruneOnQueue(now: now) }
    }

    private func pruneOnQueue(now: Date, limit: Int = DebugLog.maxBytes) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        let cutoff = stamp.string(from: now.addingTimeInterval(-Double(Self.keepDays) * 86400))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var kept: [Substring] = []
        var size = 0
        for line in lines.reversed() where String(line.prefix(23)) >= cutoff {
            let bytes = line.utf8.count + 1
            guard size + bytes <= limit else { break }
            kept.append(line); size += bytes
        }
        let out = kept.reversed().joined(separator: "\n") + (kept.isEmpty ? "" : "\n")
        try? out.write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    func clear() { queue.sync { try? FileManager.default.removeItem(at: file) } }

    /// Waits for pending writes (tests).
    func flush() { startMaintenance(); queue.sync {} }
}
