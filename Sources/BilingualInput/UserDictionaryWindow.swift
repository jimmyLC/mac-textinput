import Cocoa

/// 個人詞典 window: add or remove English words and Chinese phrases by hand.
final class UserDictionaryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    static let shared = UserDictionaryWindowController()

    private let store = UserDictionary.shared
    private let table = NSTableView()
    private let wordField = NSTextField()
    private let readingField = NSTextField()
    private let message = NSTextField(labelWithString: "")
    private var readingEdited = false
    private var learningBox: NSButton?
    private var debugBox: NSButton?

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "個人詞典"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build(in: window.contentView!)
    }

    required init?(coder: NSCoder) { fatalError() }

    func present() {
        table.reloadData()
        learningBox?.state = LearningStore.shared.enabled ? .on : .off
        debugBox?.state = DebugLog.shared.enabled ? .on : .off
        message.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build(in view: NSView) {
        let hint = NSTextField(wrappingLabelWithString:
            "加入常用的英文字（只能是英文字母，例如 MyJAV）或中文詞（可留空讀音自動推測，例如 亞東證券）。英文字會優先辨識並可用 Tab 補完；中文詞會排在候選前面。")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor

        wordField.placeholderString = "詞彙"
        readingField.placeholderString = "讀音（中文詞，例如 ㄧㄚˇ-ㄉㄨㄥ），可留空"
        wordField.delegate = self
        readingField.delegate = self
        let add = NSButton(title: "加入", target: self, action: #selector(addEntry))
        add.keyEquivalent = "\r"
        let row = NSStackView(views: [wordField, readingField, add])
        row.spacing = 8
        wordField.widthAnchor.constraint(equalToConstant: 120).isActive = true

        let wordCol = NSTableColumn(identifier: .init("word")); wordCol.title = "詞彙"; wordCol.width = 180
        let kindCol = NSTableColumn(identifier: .init("kind")); kindCol.title = "類型／讀音"; kindCol.width = 240
        table.addTableColumn(wordCol); table.addTableColumn(kindCol)
        table.dataSource = self; table.delegate = self
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let remove = NSButton(title: "刪除選取的詞", target: self, action: #selector(removeSelected))
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [remove, message]); footer.spacing = 12
        let learn = NSButton(checkboxWithTitle: "自動學習常打的英文字（只記次數）",
                             target: self, action: #selector(toggleLearning(_:)))
        learn.state = LearningStore.shared.enabled ? .on : .off
        learningBox = learn
        let clear = NSButton(title: "清除學習資料", target: self, action: #selector(clearLearning))
        let learnRow = NSStackView(views: [learn, clear]); learnRow.spacing = 12
        let logBox = NSButton(checkboxWithTitle: "記錄打字判斷（除錯用，24 小時後自動關閉）",
                              target: self, action: #selector(toggleDebugLog(_:)))
        logBox.state = DebugLog.shared.enabled ? .on : .off
        debugBox = logBox
        let logRow = NSStackView(views: [logBox,
            NSButton(title: "清除記錄", target: self, action: #selector(clearDebugLog)),
            NSButton(title: "在 Finder 顯示", target: self, action: #selector(revealDebugLog))])
        logRow.spacing = 12

        let stack = NSStackView(views: [hint, row, scroll, footer, learnRow, logRow])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    // Suggest a reading while a Chinese word is being typed, unless the user edited it.
    func controlTextDidChange(_ obj: Notification) {
        if obj.object as AnyObject === readingField { readingEdited = true; return }
        guard !readingEdited else { return }
        let word = wordField.stringValue
        readingField.stringValue = word.unicodeScalars.contains(where: { !$0.isASCII }) ? (store.suggestedReading(for: word) ?? "") : ""
    }

    @objc private func addEntry() {
        do {
            let entry = try store.add(word: wordField.stringValue, reading: readingField.stringValue)
            if let reading = entry.reading { ChinesePhraseFile.add(entry.word, reading: reading) }
            BilingualInput.shared.reloadUserWords()
            wordField.stringValue = ""; readingField.stringValue = ""; readingEdited = false
            message.stringValue = "已加入「\(entry.word)」"
            table.reloadData()
        } catch UserDictionaryError.empty {
            message.stringValue = "請輸入詞彙"
        } catch UserDictionaryError.invalidEnglish {
            message.stringValue = "英文詞目前只支援英文字母（不含空格或數字）"
        } catch UserDictionaryError.missingReading {
            message.stringValue = "找不到讀音，請手動填寫，例如 ㄧㄚˇ-ㄉㄨㄥ"
        } catch UserDictionaryError.duplicate {
            message.stringValue = "這個詞已經在詞典裡"
        } catch {
            message.stringValue = "加入失敗"
        }
    }

    @objc private func removeSelected() {
        let removed = table.selectedRowIndexes.map { store.entries[$0] }
        for entry in removed {
            store.remove(word: entry.word)
            if entry.reading != nil { ChinesePhraseFile.remove(entry.word) }
            if entry.auto == true { LearningStore.shared.block(entry.word.lowercased()) }
        }
        BilingualInput.shared.reloadUserWords()
        message.stringValue = removed.isEmpty ? "請先選取要刪除的詞" : "已刪除 \(removed.count) 個詞"
        table.reloadData()
    }

    @objc private func toggleLearning(_ sender: NSButton) {
        LearningStore.shared.enabled = sender.state == .on
        message.stringValue = sender.state == .on ? "已開啟自動學習" : "已暫停自動學習"
    }

    @objc private func toggleDebugLog(_ sender: NSButton) {
        DebugLog.shared.enabled = sender.state == .on
        message.stringValue = sender.state == .on
            ? "已開始記錄按鍵與判斷結果（只存在這台電腦，24 小時後自動關閉）" : "已停止記錄"
    }

    @objc private func clearDebugLog() {
        DebugLog.shared.clear()
        message.stringValue = "已清除記錄"
    }

    @objc private func revealDebugLog() {
        let log = DebugLog.shared.file
        if FileManager.default.fileExists(atPath: log.path) { NSWorkspace.shared.activateFileViewerSelecting([log]) }
        else { message.stringValue = "目前沒有記錄檔" }
    }

    @objc private func clearLearning() {
        LearningStore.shared.clear()
        message.stringValue = "已清除學習資料（個人詞典裡的詞不受影響）"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { store.entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = store.entries[row]
        let text = tableColumn?.identifier.rawValue == "word" ? entry.word : (entry.reading ?? (entry.auto == true ? "英文（自動學習）" : "英文"))
        let cell = NSTextField(labelWithString: text)
        return cell
    }
}

/// Keeps Chinese entries in McBopomofo's own user phrase file so the engine uses them.
enum ChinesePhraseFile {
    private static var path: String { LanguageModelManager.userPhrasesDataPathMcBopomofo }

    static func add(_ word: String, reading: String) {
        _ = LanguageModelManager.writeUserPhrase("\(word) \(reading)")
        reload()
    }

    static func remove(_ word: String) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let kept = text.components(separatedBy: "\n").filter { !$0.hasPrefix("\(word) ") }
        try? kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        reload()
    }

    private static func reload() {
        LanguageModelManager.loadUserPhrases(enableForPlainBopomofo: Preferences.enableUserPhrasesInPlainBopomofo)
    }
}
