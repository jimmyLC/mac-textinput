import Foundation

@main struct StorageSafetyTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zlm-storage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var failures = 0
        func check(_ ok: Bool, _ message: String) {
            if !ok { failures += 1; print("FAIL: \(message)") }
        }
        let blocked = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        let bad = UserDictionary(file: blocked.appendingPathComponent("dictionary.json"))
        do { try bad.add(word: "Example", reading: nil); check(false, "failed write reported success") } catch {}
        check(bad.entries.isEmpty, "failed add left an unpersisted in-memory entry")
        let file = dir.appendingPathComponent("dictionary.json")
        let dictionary = UserDictionary(file: file)
        try dictionary.add(word: "Example", reading: nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try dictionary.remove(word: "Example"); check(false, "failed delete reported success") } catch {}
        check(dictionary.entries.count == 1, "failed delete changed the in-memory dictionary")

        let suiteName = "zlm-storage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let logFile = dir.appendingPathComponent("debug.txt")
        let log = DebugLog(file: logFile, defaults: defaults)
        log.enabled = true
        for i in 0..<6 { log.record("\(i) " + String(repeating: "x", count: 500_000)) }
        log.flush()
        let size = try Data(contentsOf: logFile).count
        check(size <= DebugLog.maxBytes, "active log exceeded 2 MB: \(size)")
        let text = try String(contentsOf: logFile, encoding: .utf8)
        check(text.contains("5 "), "size pruning discarded the newest entry")
        log.enabled = false
        let oldFile = dir.appendingPathComponent("expired.txt")
        try "2000-01-01T00:00:00.000 key=a\n".write(to: oldFile, atomically: true, encoding: .utf8)
        let offLog = DebugLog(file: oldFile, defaults: defaults)
        offLog.flush()
        check((try String(contentsOf: oldFile, encoding: .utf8)).isEmpty, "expired log survives startup while disabled")
        print(failures == 0 ? "Storage safety: OK" : "Storage safety: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
