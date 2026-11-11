import SwiftUI

/// First-launch tour: four cards, shown once, reopenable from 首頁.
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    private let count = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch index {
                case 0: SetupCard()
                case 1: MixedTypingCard()
                case 2: PickingCard()
                default: LearningCard()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 36).padding(.top, 32)
            .id(index)
            .transition(.opacity)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<count, id: \.self) { i in
                        Circle().fill(i == index ? Color.primary : Color.secondary.opacity(0.3)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button("跳過") { dismiss() }.buttonStyle(.link).foregroundStyle(.secondary)
                if index > 0 { Button("上一步") { withAnimation { index -= 1 } } }
                if index < count - 1 {
                    Button("下一步") { withAnimation { index += 1 } }.keyboardShortcut(.defaultAction)
                } else {
                    Button("開始使用") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        }
        .frame(width: 560, height: 420)
    }
}

private struct CardTitle: View {
    let step: String, title: String, subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step).font(.caption).foregroundStyle(.secondary).tracking(1.5)
            Text(title).font(.system(size: 26, weight: .bold, design: .serif))
            Text(subtitle).foregroundStyle(.secondary)
        }
        .padding(.bottom, 18)
    }
}

private struct Tip: View {
    let keys: String, text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.15)))
                .frame(minWidth: 96, alignment: .leading)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
    }
}

private struct SetupCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(step: "1 / 4 · 開始", title: "先把輸入法裝好", subtitle: "兩個動作，之後就能在任何 App 裡切換到「知之」。")
            row("安裝輸入法", done: model.installState != .notInstalled) {
                if model.installState == .notInstalled { Button("安裝") { model.install() } }
            }
            row("加入輸入法清單", done: model.isEnabled) {
                if !model.isEnabled && model.installState != .notInstalled {
                    Button("加入") { model.enable() }
                    Button("開啟鍵盤設定") { model.openKeyboardSettings() }
                }
            }
            Text("加入後，用選單列的輸入法圖示，或 Control + 空白鍵，切換到「知之」。")
                .font(.callout).foregroundStyle(.secondary).padding(.top, 14)
        }
    }
    private func row<Action: View>(_ title: String, done: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? Color.primary : Color.secondary)
            Text(title)
            Spacer()
            action()
        }
        .padding(.vertical, 8)
    }
}

private struct MixedTypingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(step: "2 / 4 · 打字", title: "中英文混著打", subtitle: "照平常的注音打下去，英文單字會自己被認出來。")
            Tip(keys: "單按左 Shift", text: "打到一半時，翻轉游標前那一段的中英文；沒在打字時，切換英文模式。")
            Tip(keys: "Caps Lock", text: "直接打大寫英文。再按一次回到中文。")
            Tip(keys: "數字", text: "注音的數字鍵會被當成注音。要打 3、5 這種數字，用數字鍵盤，或按 Option + 數字。")
        }
    }
}

private struct PickingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(step: "3 / 4 · 選字", title: "少選字，需要時再選", subtitle: "不用每個字都確認，打完整句再按 Enter。")
            Tip(keys: "Enter", text: "送出整段。")
            Tip(keys: "↓", text: "打開候選字，用數字鍵或方向鍵選。")
            Tip(keys: "Tab", text: "補全英文單字，或你個人詞典裡的詞。中文不會被 Tab 補全。")
            Tip(keys: "⌘ Z", text: "AI 改過的字會標出來，不喜歡就按這個還原。")
        }
    }
}

private struct LearningCard: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(step: "4 / 4 · 越用越準", title: "它會學你的習慣", subtitle: "個人詞典與 AI 都在你的 Mac 上運作，不連雲端。")
            Tip(keys: "個人詞典", text: "你選過的字、常用的片語與英文單字會自動記下，也可以到「詞典」頁自己加。")
            Tip(keys: "本機 AI", text: "整句停下來時，檢查並換掉選錯的同音字。第一次使用要到「AI」頁下載模型一次。")
            Tip(keys: "隨時調整", text: "切換鍵、學習與 AI 都能在「偏好設定」關掉。")
        }
    }
}
