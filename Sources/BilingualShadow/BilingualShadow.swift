import Cocoa
import os

/// Read-only observer for the bilingual analyzer. It never changes what the IME
/// does: it only counts how the analyzer would classify each space-terminated
/// run of keys. Typed text is never logged or stored; only category counts are.
final class BilingualShadow {
    static let shared = BilingualShadow()

    private let log = Logger(subsystem: "com.jimmylc.inputmethod.ZhuyinLM", category: "bilingual-shadow")
    private let queue = DispatchQueue(label: "bilingual-shadow")
    private var analyzer: BilingualAnalyzer?
    private var buffer = ""
    private var counts: [String: Int] = [:]
    private var unsaved = 0

    private init() {
        queue.async { [weak self] in self?.load() }
    }

    private func load() {
        guard let res = Bundle.main.resourceURL,
              let en = try? String(contentsOf: res.appendingPathComponent("english-words.txt"), encoding: .utf8),
              let zh = try? String(contentsOf: res.appendingPathComponent("chinese-lexicon.tsv"), encoding: .utf8)
        else { log.error("shadow data missing; observer disabled"); return }
        let words = en.split(separator: "\n").prefix(120_000).compactMap { $0.split(separator: "\t").first.map(String.init) }
        let readings = zh.split(separator: "\n").compactMap { line -> String? in
            let f = line.split(separator: "\t"); return f.count >= 3 ? String(f[2]) : nil
        }
        analyzer = BilingualAnalyzer(lexicon: EnglishLexicon(words: words),
                                     zhuyin: ZhuyinSyllableIndex(readings: readings))
        log.info("shadow analyzer ready")
    }

    func reset() { queue.async { self.buffer = "" } }

    /// Feed one key event. Safe to call for every event; does nothing visible.
    func observe(_ event: NSEvent) {
        guard event.type == .keyDown else { return }
        let flags = event.modifierFlags
        let chars = event.characters ?? ""
        let key = event.keyCode
        queue.async {
            if flags.contains(.command) || flags.contains(.control) || flags.contains(.option) {
                self.buffer = ""; return
            }
            if key == 51 {  // delete
                if !self.buffer.isEmpty { self.buffer.removeLast() }
                return
            }
            guard chars.count == 1, let scalar = chars.unicodeScalars.first,
                  scalar.value >= 0x20, scalar.value < 0x7F else {
                self.buffer = ""; return  // return, escape, arrows, tab, non-ASCII, ...
            }
            self.buffer.append(chars)
            guard chars == " " else { return }
            let run = self.buffer
            self.buffer = ""
            self.record(run)
        }
    }

    private func record(_ run: String) {
        guard let analyzer = analyzer else { return }
        for segment in analyzer.analyze(run) {
            let name: String
            switch segment.kind {
            case .chinese: name = "chinese"
            case .english: name = "english"
            case .undecided: name = "undecided"
            }
            counts[name, default: 0] += 1
        }
        unsaved += 1
        if unsaved >= 20 { save() }
    }

    private func save() {
        unsaved = 0
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ZhuyinLM", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: counts, options: [.sortedKeys]) {
            try? data.write(to: dir.appendingPathComponent("bilingual-shadow-counts.json"), options: .atomic)
        }
    }
}
