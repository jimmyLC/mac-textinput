import SwiftUI
import ZhizhiCore

@main
struct ZhizhiApplication: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("知之輸入法") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

extension Notification.Name { static let showOnboarding = Notification.Name("zhizhi.showOnboarding") }

enum Page: String, CaseIterable, Identifiable {
    case home = "首頁", dictionary = "詞典", history = "歷史", preferences = "偏好設定", ai = "AI"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "character.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .preferences: return "slider.horizontal.3"
        case .ai: return "sparkles"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page: Page? = .home
    @AppStorage("onboardingDone") private var onboardingDone = false
    @State private var showOnboarding = false

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            Group {
                switch page ?? .home {
                case .home: HomePage()
                case .dictionary: DictionaryPage()
                case .history: HistoryPage()
                case .preferences: PreferencesPage()
                case .ai: AIPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle((page ?? .home).rawValue)
            .onChange(of: page) { _, _ in model.message = nil }
            .safeAreaInset(edge: .bottom) {
                if let message = model.message {
                    HStack {
                        Text(message)
                        Spacer()
                        Button("關閉") { model.message = nil }.buttonStyle(.link)
                    }
                    .padding(10)
                    .background(.bar)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onAppear { if !onboardingDone { showOnboarding = true } }
        .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in showOnboarding = true }
        .sheet(isPresented: $showOnboarding, onDismiss: { onboardingDone = true }) {
            OnboardingView().environmentObject(model)
        }
        .alert("下載本機 AI 模型？", isPresented: $model.offerModelDownload) {
            Button("下載") { model.downloadModel(); page = .ai }
            Button("先不要", role: .cancel) {}
        } message: {
            Text("模型約 \(model.modelSizeText)，從 Hugging Face 下載一次後就只在這台 Mac 上執行，打字內容不會離開電腦。沒有模型也能打字，之後可以到「AI」頁下載。")
        }
    }
}

// MARK: - Home

struct HomePage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("輸入法") {
                LabeledContent("狀態") {
                    switch model.installState {
                    case .notInstalled: Text("尚未安裝").foregroundStyle(.orange)
                    case .current(let version): Text("已安裝 \(version)")
                    case .outdated(let installed, let bundled): Text("已安裝 \(installed)，可更新到 \(bundled)").foregroundStyle(.orange)
                    }
                }
                LabeledContent("輸入法清單") {
                    Text(model.isEnabled ? "已加入" : "尚未加入").foregroundStyle(model.isEnabled ? Color.secondary : Color.orange)
                }
                HStack {
                    switch model.installState {
                    case .notInstalled: Button("安裝") { model.install() }.keyboardShortcut(.defaultAction)
                    case .outdated: Button("更新") { model.install() }.keyboardShortcut(.defaultAction)
                    case .current: Button("重新安裝") { model.install() }
                    }
                    if !model.isEnabled, model.installState != .notInstalled {
                        Button("加入輸入法清單") { model.enable() }
                    }
                    Button("開啟鍵盤設定") { model.openKeyboardSettings() }
                    Button("新手教學") { NotificationCenter.default.post(name: .showOnboarding, object: nil) }
                    Spacer()
                    if model.canRestore {
                        Button("還原到 \(model.backupVersion ?? "上一版")") { model.restore() }
                    }
                }
            }
            Section("目前") {
                LabeledContent("AI 修正") {
                    let name = model.settings.aiModel == .apple ? "Apple 模型" : "Qwen"
                    Text(!model.chosenModelReady ? "\(name) 無法使用" : model.settings.aiCorrections ? "開啟（\(name)）" : "關閉")
                }
                LabeledContent("個人詞典") {
                    let auto = model.dictionary.entries.filter { $0.source == .auto }.count
                    Text("\(model.dictionary.entries.count) 筆，其中自動加入 \(auto) 筆")
                }
                LabeledContent("學習") { Text(model.settings.learningPaused ? "已暫停" : "進行中") }
                LabeledContent("句子歷史") { Text(model.settings.sentenceHistory ? "開啟" : "關閉") }
            }
            Section("按鍵") {
                Text("Caps Lock 打大寫，Shift 加字母打大寫英文。")
                switch model.settings.switchKey {
                case .none: Text("中英切換鍵已關閉，靠自動判斷。")
                case .leftShift: Text("單按左 Shift：組字中翻轉中英文，沒在組字時切換英文模式。")
                case .rightShift: Text("單按右 Shift：組字中翻轉中英文，沒在組字時切換英文模式。")
                }
                Text("↓ 選字，Tab 補全英文與個人詞典，Cmd-Z 還原 AI 的修正。")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Dictionary

struct DictionaryPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var onlyAuto = false
    @State private var adding = false
    @State private var selection = Set<String>()

    private var rows: [PersonalDictionary.Entry] {
        model.dictionary.entries
            .filter { !onlyAuto || $0.source == .auto }
            .filter { query.isEmpty || $0.text.localizedCaseInsensitiveContains(query) }
            .sorted { $0.added > $1.added }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.dictionary.entries.isEmpty {
                ContentUnavailableView("詞典是空的", systemImage: "character.book.closed",
                                       description: Text("選字和常打的英文會自動加進來，也可以手動新增或匯入。"))
            } else {
                Table(rows, selection: $selection) {
                    TableColumn("詞") { Text($0.text) }
                    TableColumn("注音") { Text($0.reading.replacingOccurrences(of: "-", with: " ")).foregroundStyle(.secondary) }
                    TableColumn("來源") { Text($0.source == .auto ? "自動" : "手動") }.width(50)
                    TableColumn("加入") { Text($0.added, format: .dateTime.year().month().day()).foregroundStyle(.secondary) }.width(100)
                }
                .contextMenu(forSelectionType: String.self) { items in
                    Button("刪除，且不再自動學回來") { items.forEach(model.deleteEntry) }
                }
            }
        }
        .searchable(text: $query, prompt: "搜尋詞典")
        .toolbar {
            Toggle("只看自動", isOn: $onlyAuto)
            Button("刪除", systemImage: "trash") {
                selection.forEach(model.deleteEntry)
                selection.removeAll()
            }
            .disabled(selection.isEmpty)
            Button("匯入") { model.importDictionary() }
            Button("匯出") { model.exportDictionary() }
            Button("新增", systemImage: "plus") { adding = true }
        }
        .sheet(isPresented: $adding) { AddEntrySheet() }
    }
}

extension PersonalDictionary.Entry: Identifiable {
    public var id: String { text }
}

struct AddEntrySheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var reading = ""

    var body: some View {
        Form {
            TextField("詞", text: $text, prompt: Text("例如：品瑞、Claude Code、產品ID"))
                .onChange(of: text) { _, new in reading = model.suggestedReading(for: new) }
            TextField("注音", text: $reading, prompt: Text("開頭的中文才需要，音節用 - 分開"))
            Text("注音會自動帶入，破音字請自己改，例如 ㄔㄨㄥˊ-ㄒㄧㄣ。英文留空。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("新增") {
                    model.addEntry(text: text, reading: reading)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 240)
    }
}

// MARK: - History

struct HistoryPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("保留句子歷史", isOn: $model.settings.sentenceHistory)
                Text("加密保存 90 天，不進備份，不記錄 App 名稱或網址；密碼工具和終端機不記錄。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.sentenceHistory {
                    Text("開啟前請先確認：到網頁的密碼欄打字時，知之不會收到按鍵。")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    if model.historyUnlocked {
                        Button("鎖定") { model.lockHistory() }
                    } else {
                        Button("打開歷史紀錄") { model.unlockHistory() }
                    }
                    Spacer()
                    Button("全部清除", role: .destructive) { confirmClear = true }
                }
            }
            if model.historyUnlocked {
                Section("\(model.historyItems.count) 句") {
                    TextField("搜尋", text: $query).onChange(of: query) { _, new in model.searchHistory(new) }
                    ForEach(Array(model.historyItems.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.text).textSelection(.enabled)
                            Spacer()
                            Text(item.date, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                            Button("刪除", systemImage: "trash") { model.deleteHistoryItem(item, query: query) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清除全部句子歷史？這無法復原。", isPresented: $confirmClear) {
            Button("全部清除", role: .destructive) {
                model.clearHistory()
                model.lockHistory()
            }
        }
    }
}

// MARK: - Preferences

struct PreferencesPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("打字") {
                Picker("判斷中英文", selection: $model.settings.language) {
                    Text("中文優先").tag(Settings.Language.chineseFirst)
                    Text("英文優先").tag(Settings.Language.englishFirst)
                }
                Picker("中英切換鍵", selection: $model.settings.switchKey) {
                    Text("左 Shift").tag(Settings.SwitchKey.leftShift)
                    Text("右 Shift").tag(Settings.SwitchKey.rightShift)
                    Text("不使用").tag(Settings.SwitchKey.none)
                }
                Toggle("中英文之間自動空格", isOn: $model.settings.autoSpace)
                Picker("標點寬度", selection: $model.settings.punctuation) {
                    Text("跟著前面的文字").tag(Settings.PunctuationWidth.follow)
                    Text("一律全形").tag(Settings.PunctuationWidth.full)
                    Text("一律半形").tag(Settings.PunctuationWidth.half)
                }
                Toggle("Tab 補全英文與個人詞典", isOn: $model.settings.tabOffers)
                Toggle("Esc 清除組字中的文字", isOn: $model.settings.escapeClears)
            }
            Section("選字") {
                Stepper("每頁 \(model.settings.candidatesPerPage) 個候選字", value: $model.settings.candidatesPerPage, in: Settings.pageSizes)
            }
            Section("學習") {
                Toggle("暫停學習", isOn: $model.settings.learningPaused)
                Text("暫停時不會調整選字順序，也不會自動加詞。密碼欄、密碼工具和終端機本來就不學習。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI

struct AIPage: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                Toggle("自動修正同音字", isOn: $model.settings.aiCorrections).disabled(!model.chosenModelReady)
                Picker("使用的模型", selection: $model.settings.aiModel) {
                    Text("Qwen（修得較多，需下載）").tag(Settings.AIModel.qwen)
                    Text("Apple 模型（免下載，較保守）").tag(Settings.AIModel.apple)
                }
                if !model.chosenModelReady {
                    Text(model.settings.aiModel == .apple ? "Apple 模型目前無法使用，不會自動改用 Qwen。" : "Qwen 尚未下載，不會自動改用 Apple 模型。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("停下來約 0.35 秒後，修正還沒送出的字，改過的字會短暫加粗底線。Cmd-Z 可還原並鎖定，你選過的字不會被改。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Apple 模型") {
                LabeledContent("狀態") {
                    switch model.appleStatus {
                    case .available: Text("可以使用")
                    case .osTooOld: Text("需要 macOS 26 以上").foregroundStyle(.orange)
                    case .deviceNotEligible: Text("這台 Mac 不支援").foregroundStyle(.orange)
                    case .appleIntelligenceOff: Text("請先在系統設定開啟 Apple 智慧").foregroundStyle(.orange)
                    case .modelNotReady: Text("系統還在準備模型").foregroundStyle(.orange)
                    case .unknown: Text("目前無法使用").foregroundStyle(.orange)
                    }
                }
                LabeledContent("大小與記憶體") { Text("由系統管理，知之不另外占用") }
            }
            Section("Qwen 模型") {
                LabeledContent("Qwen2.5-1.5B-4bit") {
                    Text(model.modelInstalled ? "已安裝" : "尚未安裝").foregroundStyle(model.modelInstalled ? Color.secondary : Color.orange)
                }
                LabeledContent("大小") { Text(model.modelSizeText) }
                LabeledContent("執行時記憶體") { Text("約 1.3 GB，閒置 5 分鐘後釋放") }
                if let progress = model.downloadProgress {
                    ProgressView(value: progress) { Text("下載中 \(Int(progress * 100))%") }
                    Button("取消") { model.cancelDownload() }
                } else if model.modelInstalled {
                    Button("移除模型", role: .destructive) { confirmRemove = true }
                } else {
                    Button("下載模型") { model.downloadModel() }.keyboardShortcut(.defaultAction)
                }
            }
            Section("隱私") {
                Text("兩個模型都只在這台 Mac 上執行，知之只用 Apple 的裝置端模型，打字內容不會上傳。Qwen 只從 Hugging Face 下載一次，並核對檔案雜湊。沒有模型也能正常打字。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("移除模型？之後要再下載才有 AI 修正。", isPresented: $confirmRemove) {
            Button("移除", role: .destructive) { model.removeModel() }
        }
    }
}
