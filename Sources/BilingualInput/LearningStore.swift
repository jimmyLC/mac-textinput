import Foundation

/// On-device learning from typing habits. Stores only counts of uncommon English words
/// and three counters about tone-fix offers: never sentences, never Chinese text.
/// Nothing leaves this Mac; learning can be paused and cleared from the dictionary window.
final class LearningStore {
    static var shared = LearningStore(
        file: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZhuyinLM/learning.json"))

    struct State: Codable {
        var enabled = true
        var counts: [String: Int] = [:]   // uncommon English words seen, not yet in the dictionary
        var blocked: [String] = []        // words the user removed; never learned again
        var repairShown = 0
        var repairAccepted = 0
    }

    static let threshold = 3
    static let maxTracked = 2000

    private(set) var state = State()
    private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
    }

    var enabled: Bool {
        get { state.enabled }
        set { state.enabled = newValue; save() }
    }

    /// Counts one use of an uncommon English word. True when it has now been seen often
    /// enough to join the personal dictionary (its counter is dropped).
    func recordEnglish(_ word: String) -> Bool {
        guard state.enabled, (3...20).contains(word.count), UserDictionary.isEnglishWord(word),
              !state.blocked.contains(word) else { return false }
        let n = (state.counts[word] ?? 0) + 1
        if n >= Self.threshold {
            state.counts[word] = nil
            save()
            return true
        }
        state.counts[word] = n
        if state.counts.count > Self.maxTracked {
            for (w, _) in state.counts.sorted(by: { $0.value < $1.value }).prefix(Self.maxTracked / 4) { state.counts[w] = nil }
        }
        save()
        return false
    }

    func block(_ word: String) {
        let w = word.lowercased()
        if !state.blocked.contains(w) { state.blocked.append(w) }
        state.counts[w] = nil
        save()
    }

    func clear() {
        state = State(enabled: state.enabled, counts: [:], blocked: [], repairShown: 0, repairAccepted: 0)
        save()
    }

    func recordRepairShown() { guard state.enabled else { return }; state.repairShown += 1; save() }
    func recordRepairAccepted() { guard state.enabled else { return }; state.repairAccepted += 1; save() }

    /// How demanding tone-fix offers should be: raised when offers are mostly ignored,
    /// lowered when they are mostly taken. Needs 30 offers of history first.
    var repairMargin: Double {
        guard state.repairShown >= 30 else { return 1.5 }
        let rate = Double(state.repairAccepted) / Double(state.repairShown)
        if rate < 0.15 { return 2.5 }
        if rate < 0.30 { return 2.0 }
        if rate > 0.60 { return 1.0 }
        return 1.5
    }

    private func save() {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: file, options: .atomic) }
    }
}
