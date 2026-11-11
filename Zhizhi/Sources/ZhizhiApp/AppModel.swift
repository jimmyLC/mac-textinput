import AppKit
import Carbon
import Foundation
import UniformTypeIdentifiers
import ZhizhiCore

/// Everything the App's pages show and do. The App need not stay running: all state lives
/// in the same files and defaults the input method uses.
@MainActor
final class AppModel: ObservableObject {
    static let inputMethodID = "com.jimmylc.inputmethod.Zhizhi"

    let paths = ZhizhiPaths()
    let installer: Installer
    let downloader: ModelDownloader

    @Published var settings: Settings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: Settings.sharedDefaults)
            DistributedNotificationCenter.default().postNotificationName(Settings.settingsChanged, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    // Home
    @Published private(set) var installState = Installer.State.notInstalled
    @Published private(set) var canRestore = false
    @Published private(set) var backupVersion: String?
    @Published private(set) var isEnabled = false
    @Published var message: String?

    // Dictionary
    @Published private(set) var dictionary: PersonalDictionary
    private lazy var lexicon: Lexicon = loadLexicon()

    // History
    @Published private(set) var historyItems: [SentenceHistory.Item] = []
    @Published private(set) var historyUnlocked = false
    private var history: SentenceHistory?

    // AI
    @Published private(set) var modelInstalled = false
    @Published private(set) var downloadProgress: Double?
    @Published var offerModelDownload = false

    init() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Zhizhi.app")
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        installer = Installer(bundled: bundled, installed: library.appendingPathComponent("Input Methods/Zhizhi.app"), backups: paths.backups)
        downloader = ModelDownloader(manifest: .qwen, folder: paths.models.appendingPathComponent(ModelManifest.qwen.name))
        settings = Settings(defaults: Settings.sharedDefaults)
        dictionary = paths.loadDictionary()
        refresh()
        // Offered once, as agreed; the AI page offers it for good.
        if !modelInstalled, AppleModelBackend.status != .available, !UserDefaults.standard.bool(forKey: "ModelOfferShown") {
            UserDefaults.standard.set(true, forKey: "ModelOfferShown")
            offerModelDownload = true
        }
    }

    func refresh() {
        installState = installer.state
        canRestore = installer.canRestore
        backupVersion = installer.backupVersion
        isEnabled = inputSource().map { source in
            let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled)
            return value.map { CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque($0).takeUnretainedValue()) } ?? false
        } ?? false
        modelInstalled = downloader.isInstalled
        dictionary = paths.loadDictionary()
    }

    // MARK: - Install

    /// The selectable Zhuyin mode of the input method, once macOS knows about it.
    private func inputSource() -> TISInputSource? {
        let filter = [kTISPropertyBundleID as String: Self.inputMethodID] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        return list.first { source in
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return false }
            let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
            return id.hasSuffix(".Zhuyin")
        } ?? list.first
    }

    func install() {
        perform("安裝完成") { try self.installer.install() }
    }

    func restore() {
        perform("已還原上一版") { try self.installer.restore() }
    }

    private func perform(_ success: String, _ action: @escaping () throws -> Void) {
        do {
            try action()
            run("/usr/bin/pkill", ["-x", "Zhizhi"])         // the system starts the new copy on next use
            run(installer.installed.appendingPathComponent("Contents/MacOS/Zhizhi").path, ["--register"])
            message = success
        } catch {
            message = "失敗：\(error.localizedDescription)"
        }
        refresh()
    }

    /// Adds it to the input menu. This does not switch the current input source.
    func enable() {
        guard let source = inputSource() else {
            message = "系統還找不到知之，請先安裝。"
            return
        }
        let status = TISEnableInputSource(source)
        message = status == noErr ? "已加入輸入法清單" : "加入失敗（\(status)），請到系統設定手動加入。"
        refresh()
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    private func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: - Dictionary

    private func loadLexicon() -> Lexicon {
        let lexicon = Lexicon()
        let resources = installer.bundled.appendingPathComponent("Contents/Resources")
        if let text = try? String(contentsOf: resources.appendingPathComponent("chinese-lexicon.tsv"), encoding: .utf8) {
            lexicon.loadChinese(tsv: text)
        }
        return lexicon
    }

    /// What Zhuyin a new entry's leading Chinese is read as; English gets none.
    func suggestedReading(for text: String) -> String {
        guard let first = text.first, !first.isASCII else { return "" }
        return lexicon.suggestedReading(for: text)
    }

    func addEntry(text: String, reading: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        var updated = paths.loadDictionary()
        updated.allow(text)
        updated.add(.init(text: text, reading: reading, source: .manual, added: Date()))
        store(updated)
    }

    func deleteEntry(_ text: String) {
        var updated = paths.loadDictionary()
        updated.delete(text)
        store(updated)
    }

    func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .tabSeparatedText, .text]
        panel.message = "選一個文字檔：每行一個詞，或知之匯出的 TSV。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let incoming = PersonalDictionary(tsv: try String(contentsOf: url, encoding: .utf8))
            var updated = paths.loadDictionary()
            var count = 0
            for var entry in incoming.entries {
                if entry.reading.isEmpty { entry.reading = suggestedReading(for: entry.text) }
                entry.source = .manual
                entry.added = Date()
                updated.allow(entry.text)
                if updated.add(entry) { count += 1 }
            }
            store(updated)
            message = "匯入 \(count) 筆"
        } catch {
            message = "匯入失敗：\(error.localizedDescription)"
        }
    }

    func exportDictionary() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "知之個人詞典.tsv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try paths.loadDictionary().tsv.write(to: url, atomically: true, encoding: .utf8)
            message = "已匯出"
        } catch {
            message = "匯出失敗：\(error.localizedDescription)"
        }
    }

    private func store(_ updated: PersonalDictionary) {
        do {
            try paths.save(updated)
            dictionary = updated
            DistributedNotificationCenter.default().postNotificationName(Settings.dictionaryChanged, object: nil, userInfo: nil, deliverImmediately: true)
        } catch {
            message = "儲存失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - History

    /// Asks the Keychain only when the user opens the history. macOS may ask them to allow it.
    func unlockHistory() {
        guard let key = Keychain.historyKey() else {
            message = "無法取得加密金鑰，歷史紀錄未開啟。"
            return
        }
        history = SentenceHistory(file: paths.history, key: key)
        historyUnlocked = true
        searchHistory("")
    }

    func lockHistory() {
        history = nil
        historyUnlocked = false
        historyItems = []
    }

    func searchHistory(_ query: String) {
        historyItems = history?.items(matching: query) ?? []
    }

    func deleteHistoryItem(_ item: SentenceHistory.Item, query: String) {
        try? history?.delete(item)
        searchHistory(query)
    }

    func clearHistory() {
        do {
            try SentenceHistory(file: paths.history, key: .init(size: .bits256)).clear()
            historyItems = []
            message = "已清除句子歷史"
        } catch {
            message = "清除失敗：\(error.localizedDescription)"
        }
    }

    // MARK: - Model

    var appleStatus: AppleModelBackend.Status { AppleModelBackend.status }

    /// Whether the model chosen in settings can run right now.
    var chosenModelReady: Bool {
        settings.aiModel == .apple ? appleStatus == .available : modelInstalled
    }

    var modelSizeText: String { ByteCountFormatter.string(fromByteCount: ModelManifest.qwen.totalSize, countStyle: .file) }

    func downloadModel() {
        guard downloadProgress == nil else { return }
        downloadProgress = 0
        downloader.start(progress: { [weak self] value in
            Task { @MainActor in self?.downloadProgress = value }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.downloadProgress = nil
                switch result {
                case .success:
                    self.message = "模型已安裝"
                case .failure(ModelDownloader.Failure.cancelled):
                    self.message = "已取消，已完成的檔案會保留。"
                case .failure(let error):
                    self.message = "下載失敗：\(error.localizedDescription)"
                }
                self.refresh()
            }
        })
    }

    func cancelDownload() { downloader.cancel() }

    func removeModel() {
        do {
            try downloader.remove()
            message = "模型已移除"
        } catch {
            message = "移除失敗：\(error.localizedDescription)"
        }
        refresh()
    }
}
