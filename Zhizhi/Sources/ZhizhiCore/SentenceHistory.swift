import CryptoKit
import Foundation
import Security

/// Committed sentences, each sealed on its own line with AES-GCM. Holds no app name or URL,
/// keeps 90 days, and is excluded from backups. The key comes from the caller (the Keychain).
public final class SentenceHistory {
    public struct Item: Codable, Equatable {
        public var date: Date
        public var text: String
        public init(date: Date, text: String) { self.date = date; self.text = text }
    }
    public static let retention: TimeInterval = 90 * 24 * 3600

    private let file: URL
    private let key: SymmetricKey
    private let clock: () -> Date

    public init(file: URL, key: SymmetricKey, clock: @escaping () -> Date = Date.init) {
        self.file = file
        self.key = key
        self.clock = clock
    }

    public func append(_ text: String) throws {
        let item = Item(date: clock(), text: text)
        let sealed = try AES.GCM.seal(JSONEncoder().encode(item), using: key)
        guard let combined = sealed.combined else { return }
        try prepare()
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((combined.base64EncodedString() + "\n").utf8))
    }

    /// Items newest first. Lines that cannot be opened (a different key, damage) are skipped.
    public func items(matching query: String = "") -> [Item] {
        let limit = clock().addingTimeInterval(-Self.retention)
        return readItems()
            .filter { $0.date >= limit && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.date > $1.date }
    }

    /// Drops everything past the retention period.
    public func prune() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let keep = items().reversed()
        let lines = try keep.compactMap { item -> String? in
            try AES.GCM.seal(JSONEncoder().encode(item), using: key).combined?.base64EncodedString()
        }
        try lines.map { $0 + "\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
        try secure()
    }

    public func delete(_ item: Item) throws {
        let keep = items().reversed().filter { $0 != item }
        try clear()
        try prepare()
        let lines = try keep.compactMap { kept -> String? in
            try AES.GCM.seal(JSONEncoder().encode(kept), using: key).combined?.base64EncodedString()
        }
        try lines.map { $0 + "\n" }.joined().write(to: file, atomically: true, encoding: .utf8)
        try secure()
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func readItems() -> [Item] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let data = Data(base64Encoded: String(line)),
                  let box = try? AES.GCM.SealedBox(combined: data),
                  let plain = try? AES.GCM.open(box, using: key) else { return nil }
            return try? JSONDecoder().decode(Item.self, from: plain)
        }
    }

    private func prepare() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: file.path) { fm.createFile(atPath: file.path, contents: nil) }
        try secure()
    }

    private func secure() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

/// Apps whose text is never learned or kept: password tools and terminals.
public enum LearningExclusions {
    public static let prefixes = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.1password", "com.agilebits", "com.bitwarden",
        "com.lastpass", "com.dashlane", "org.keepassxc", "com.apple.Terminal", "com.googlecode.iterm2",
        "dev.warp", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "co.zeit.hyper", "io.alacritty", "com.mitchellh.ghostty",
    ]
    public static func excludes(bundleID: String?) -> Bool {
        guard let id = bundleID else { return true }   // unknown client: stay on the safe side
        return prefixes.contains { id.hasPrefix($0) }
    }
}

/// The sentence history's key, in the login Keychain on this device only.
public enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.jimmylc.inputmethod.Zhizhi.history",
        kSecAttrAccount as String: "sentence-history-key",
    ]

    public static func historyKey() -> SymmetricKey? {
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
