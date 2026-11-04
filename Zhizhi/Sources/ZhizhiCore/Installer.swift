import Foundation

/// Copies the input method embedded in the App to where macOS looks for it. Keeps the
/// previous copy, so one click brings it back. Running and registering it is the App's job.
public struct Installer {
    public enum State: Equatable {
        case notInstalled
        case current(version: String)
        case outdated(installed: String, bundled: String)
    }
    public enum Failure: Error { case bundledCopyMissing, nothingToRestore }

    public var bundled: URL
    public var installed: URL
    public var backups: URL

    public init(bundled: URL, installed: URL, backups: URL) {
        self.bundled = bundled
        self.installed = installed
        self.backups = backups
    }

    public static func version(of app: URL) -> (short: String, build: String)? {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let short = info["CFBundleShortVersionString"] as? String else { return nil }
        return (short, info["CFBundleVersion"] as? String ?? "0")
    }

    public var state: State {
        guard let current = Self.version(of: installed) else { return .notInstalled }
        guard let inside = Self.version(of: bundled) else { return .current(version: current.short) }
        if current.build == inside.build { return .current(version: current.short) }
        return .outdated(installed: "\(current.short) (\(current.build))", bundled: "\(inside.short) (\(inside.build))")
    }

    private var backup: URL { backups.appendingPathComponent(installed.lastPathComponent) }

    public var canRestore: Bool { Self.version(of: backup) != nil }
    public var backupVersion: String? { Self.version(of: backup).map { "\($0.short) (\($0.build))" } }

    /// Installs or updates. The running copy is replaced only once the new one is fully in place.
    public func install() throws {
        guard FileManager.default.fileExists(atPath: bundled.path) else { throw Failure.bundledCopyMissing }
        let fm = FileManager.default
        try fm.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let incoming = staging("incoming")
        try fm.copyItem(at: bundled, to: incoming)
        if fm.fileExists(atPath: installed.path) {
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            try fm.moveItem(at: installed, to: backup)
        }
        try fm.moveItem(at: incoming, to: installed)
    }

    /// Swaps the installed copy with the backup, so restoring can itself be undone.
    public func restore() throws {
        guard canRestore else { throw Failure.nothingToRestore }
        let fm = FileManager.default
        let holding = staging("holding")
        if fm.fileExists(atPath: installed.path) { try fm.moveItem(at: installed, to: holding) }
        try fm.moveItem(at: backup, to: installed)
        if fm.fileExists(atPath: holding.path) { try fm.moveItem(at: holding, to: backup) }
    }

    private func staging(_ name: String) -> URL {
        let url = installed.deletingLastPathComponent().appendingPathComponent(".\(installed.lastPathComponent).\(name)")
        try? FileManager.default.removeItem(at: url)
        return url
    }
}
