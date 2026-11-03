import Foundation

@main struct PhraseRepairTests {
    static func main() {
        let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        let text = try! String(contentsOfFile: root + "/data/chinese-lexicon.tsv", encoding: .utf8)
        let lines = text.split(separator: "\n")
        let repair = PhraseRepair(lines: lines)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

        check(repair.suggest(["ㄋㄧˇ", "ㄏㄠˇ"]) == nil, "correct phrase is left alone")
        let s = repair.suggest(["ㄋㄧˇ", "ㄏㄠ"])
        check(s?.word == "你好" && s?.readings == ["ㄋㄧˇ", "ㄏㄠˇ"], "你好 repaired, got \(String(describing: s))")
        check(PhraseRepair.keys(for: "ㄋㄧˇ") == "su3" && PhraseRepair.keys(for: "ㄧ") == "u ", "keys for syllable")
        check(PhraseRepair.syllable(fromKeys: "su3") == "ㄋㄧˇ" && PhraseRepair.syllable(fromKeys: "u ") == "ㄧ", "syllable from keys")

        // Recall: perturb the tone of one syllable in frequent phrases.
        let tones = ["", "ˊ", "ˇ", "ˋ"]
        var tried = 0, recovered = 0, wrongWord = 0
        for line in lines.prefix(30000) {
            let f = line.split(separator: "\t")
            guard f.count >= 3, f[0].count >= 2, f[0].count <= 4, let score = Double(f[1]), score >= -6.0,
                  let reading = f[2].split(separator: "|").first else { continue }
            let syl = reading.split(separator: "-").map(String.init)
            guard syl.count == f[0].count else { continue }
            let i = syl.count - 1
            guard PhraseRepair.tone(syl[i]) != "˙" else { continue }
            var typed = syl
            let order = ["", "ˊ", "ˇ", "ˋ"]
            let current = PhraseRepair.tone(syl[i]).map(String.init) ?? ""
            typed[i] = PhraseRepair.stripTone(syl[i]) + order[((order.firstIndex(of: current) ?? 0) + 1) % 4]
            if typed == syl { continue }
            tried += 1
            if let s = repair.suggest(typed) { if s.word == String(f[0]) { recovered += 1 } else { wrongWord += 1 } }
        }
        print("tone-slip recall: \(recovered)/\(tried) recovered, \(wrongWord) different word")

        // False positives: two-syllable windows across word boundaries of common 4-char phrases.
        var windows = 0, flagged = 0
        for line in lines.prefix(30000) {
            let f = line.split(separator: "\t")
            guard f.count >= 3, f[0].count == 4, let r = f[2].split(separator: "|").first else { continue }
            let syl = r.split(separator: "-").map(String.init)
            guard syl.count == 4 else { continue }
            windows += 1
            if repair.suggest(Array(syl[1...2])) != nil { flagged += 1 }
        }
        print("boundary windows flagged: \(flagged)/\(windows)")
        check(windows == 0 || Double(flagged) / Double(windows) < 0.10, "false-positive rate acceptable")
        check(tried > 0 && Double(recovered) / Double(tried) > 0.7, "recall acceptable")
        print(failures == 0 ? "phrase repair: OK" : "phrase repair: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
