import Foundation
import ZhizhiCore

// Measures the engine. `zhizhi-eval <repo root> sentences [file.json]` and `... replay <log>`.
// The replay reads the owner's private key log from outside the repo and prints only to stdout.
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: zhizhi-eval <root> sentences|replay [path]"); exit(2) }
let root = args[1]

func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

let loadStart = Date()
let lexicon = Lexicon()
lexicon.loadChinese(tsv: read(root + "/data/chinese-lexicon.tsv"))
lexicon.loadEnglish(text: read(root + "/data/english-words.txt"))
print(String(format: "lexicon loaded in %.2f s", Date().timeIntervalSince(loadStart)))
let decoder = Decoder(lexicon: lexicon)

let equivalent: [Character: Character] = ["她": "他", "它": "他", "牠": "他", "儘": "盡", "覆": "復", "複": "復", "週": "周"]
func normalized(_ s: String) -> String { String(s.map { equivalent[$0] ?? $0 }) }

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    return values.sorted()[min(values.count - 1, Int(Double(values.count) * p))]
}

switch args[2] {
case "sentences":
    struct Row: Decodable { let gold: String; let syllables: [String] }
    let path = args.count > 3 ? args[3] : root + "/eval/baseline.json"
    let rows = try! JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    var exact = 0, wrongChars = 0, totalChars = 0, toneless = 0
    var prefixes = 0, englishPrefixes = 0, englishFinals = 0
    var failures: [String] = []
    var times: [Double] = []
    for row in rows {
        let keys = row.syllables.map(Zhuyin.keys(forSyllable:)).joined()
        var prefix: [Character] = []
        var output = ""
        for k in keys {
            prefix.append(k)
            let t = Date()
            let segments = decoder.decode(keys: prefix)
            times.append(Date().timeIntervalSince(t) * 1000)
            output = decoder.render(segments)
            // Chinese-only sentences: any Latin letter while typing is a false English reading.
            prefixes += 1
            if segments.contains(where: { $0.kind == .english }) { englishPrefixes += 1 }
        }
        if output.contains(where: { $0.isASCII && $0.isLetter }) { englishFinals += 1 }
        let gold = normalized(row.gold), got = normalized(output)
        totalChars += gold.count
        if gold == got { exact += 1 } else {
            failures.append("\(row.gold) -> \(output)")
            wrongChars += zip(gold, got).filter { $0 != $1 }.count + abs(gold.count - got.count)
        }
        // The same sentence with every tone key removed (space-free toneless typing).
        let bare = String(keys.filter { !"3467 ".contains($0) })
        if normalized(decoder.render(decoder.decode(bare))) == gold { toneless += 1 }
    }
    print("sentences \(rows.count); exact \(exact) (\(exact * 100 / max(rows.count, 1))%); char errors \(wrongChars)/\(totalChars); toneless exact \(toneless)")
    print("false English: \(englishPrefixes)/\(prefixes) prefixes while typing; \(englishFinals) finished sentences")
    print(String(format: "decode per key: p50 %.2f ms, p95 %.2f ms, max %.2f ms", percentile(times, 0.5), percentile(times, 0.95), times.max() ?? 0))
    failures.forEach { print("  " + $0) }
case "ai":
    // zhizhi-eval <root> ai <helper executable> <model folder>: the sentence set through the real helper.
    struct Row: Decodable { let gold: String; let syllables: [String] }
    let rows = try! JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: root + "/eval/baseline.json")))
    let client = HelperClient(executable: URL(fileURLWithPath: args[3]), model: URL(fileURLWithPath: args[4]))
    func scored(_ texts: [String]) -> [Float] {
        let done = DispatchSemaphore(value: 0)
        var result: [Float] = []
        client.score(texts) { result = $0 ?? []; done.signal() }
        done.wait()
        return result
    }
    var runs: [(row: Row, keys: [Character], segments: [Segment], plan: CorrectionPlan?, scores: [Float])] = []
    var times: [Double] = []
    for row in rows {
        let keys = Array(row.syllables.map(Zhuyin.keys(forSyllable:)).joined())
        let segments = decoder.decode(keys: keys)
        let plan = decoder.correctionPlan(keys: keys, segments: segments)
        let t = Date()
        runs.append((row, keys, segments, plan, plan.map { scored($0.texts) } ?? []))
        times.append(Date().timeIntervalSince(t) * 1000)
    }
    print(String(format: "helper per sentence: p50 %.0f ms, p95 %.0f ms", percentile(times, 0.5), percentile(times, 0.95)))
    for threshold: Float in [1, 1.5, 2, 2.5, 3, 4] {
        var exact = 0, wrongBefore = 0, fixed = 0, broken = 0, rightBefore = 0
        var failures: [String] = []
        for run in runs {
            let before = normalized(decoder.render(run.segments))
            var after = before
            if let plan = run.plan {
                let constraints = decoder.corrections(plan: plan, logprobs: run.scores, threshold: threshold)
                after = normalized(decoder.render(decoder.decode(keys: run.keys, constraints: constraints)))
            }
            let gold = normalized(run.row.gold)
            if after == gold { exact += 1 } else { failures.append("\(run.row.gold) -> \(after)") }
            guard before.count == gold.count, after.count == gold.count else { continue }
            for (b, (a, g)) in zip(before, zip(after, gold)) {
                if b == g { rightBefore += 1; if a != g { broken += 1 } }
                else { wrongBefore += 1; if a == g { fixed += 1 } }
            }
        }
        print("tau \(threshold): exact \(exact)/\(runs.count) (\(exact * 100 / max(runs.count, 1))%); fixed \(fixed)/\(wrongBefore); broken \(broken)/\(rightBefore)")
        if threshold == 2 { failures.forEach { print("  " + $0) } }
    }
case "mixed":
    struct Row: Decodable { let gold: String; let keys: String }
    let rows = try! JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: root + "/eval/mixed.json")))
    var exact = 0
    var englishRight = 0, englishTotal = 0
    var failures: [String] = []
    for row in rows {
        let output = decoder.render(decoder.decode(row.keys))
        if normalized(output) == normalized(row.gold) { exact += 1 } else { failures.append("\(row.gold) -> \(output)") }
        // Language split only: the English words survive, whatever the homophones.
        let words = { (s: String) in s.split(whereSeparator: { !($0.isASCII && $0.isLetter) }).map(String.init) }
        let want = words(row.gold)
        englishTotal += 1
        if words(output) == want { englishRight += 1 }
    }
    print("mixed \(rows.count); exact \(exact); language split right \(englishRight)/\(englishTotal)")
    failures.forEach { print("  " + $0) }
case "replay":
    let rx = try! NSRegularExpression(pattern: #"key=(\S+) composing=\S+ run=\S+ mode=(\S+) prevEn=\S+ -> (\S+)"#)
    var buffer: [Character] = []
    var times: [Double] = []
    var english = 0, compositions = 0
    var englishWords: [String: Int] = [:]
    var misfires: [(tail: String, keys: [Character], after: Int)] = []
    var commandDown = false   // keys typed with Cmd held are shortcuts, not text
    let lines = read(args[3]).split(separator: "\n").map(String.init)
    for (index, line) in lines.enumerated() {
        guard let m = rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { continue }
        func group(_ i: Int) -> String { String(line[Range(m.range(at: i), in: line)!]) }
        let key = group(1), mode = group(2), action = group(3)
        if key == "mod55" || key == "mod54" { commandDown.toggle(); continue }
        if key.hasPrefix("mod") { continue }
        if commandDown { continue }
        if action.hasPrefix("beginEnglish") { misfires.append((action, buffer + [Character(key)], index)) }
        if key == "code36" || mode == "en" {
            if !buffer.isEmpty {
                compositions += 1
                for s in decoder.decode(keys: buffer) where s.kind == .english && s.text == s.text.lowercased() {
                    english += 1
                    englishWords[s.text, default: 0] += 1
                }
            }
            buffer = []
            continue
        }
        if key == "code51" { if !buffer.isEmpty { buffer.removeLast() }; continue }
        if key == "code49" { buffer.append(" ") }
        else if key.count == 1 { buffer.append(Character(key)) }
        else { buffer = []; continue }
        if buffer.count > 120 { buffer.removeFirst(60) }
        let t = Date()
        _ = decoder.decode(keys: buffer)
        times.append(Date().timeIntervalSince(t) * 1000)
    }
    print("keys decoded \(times.count); compositions \(compositions); lowercase English segments at commit \(english)")
    print(String(format: "decode per key: p50 %.2f ms, p95 %.2f ms, max %.2f ms", percentile(times, 0.5), percentile(times, 0.95), times.max() ?? 0))
    print("old auto-English triggers replayed (keys through the next tone key or space):")
    for m in misfires {
        var keys = m.keys
        var i = m.after + 1
        var added = 0
        while i < lines.count, added < 6 {
            guard let g = rx.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) else { i += 1; continue }
            let k = String(lines[i][Range(g.range(at: 1), in: lines[i])!])
            i += 1
            if k.count != 1 { if k == "code49" { keys.append(" ") }; break }
            keys.append(Character(k)); added += 1
            if "3467".contains(k) { break }
        }
        let tailKeys = Array(keys.suffix(10))
        let at = decoder.decode(keys: m.keys)
        let end = decoder.decode(keys: keys)
        print("  \(m.tail): at trigger last=\(at.last.map { "\($0.kind)" } ?? "-"); after tone: \(end.suffix(2).map { "\($0.kind):\($0.text)" }) keys=\(String(tailKeys))")
    }
    print("lowercase English at commit: \(englishWords.sorted { $0.value > $1.value }.prefix(30).map { "\($0.key)×\($0.value)" })")
default:
    print("unknown command")
}
