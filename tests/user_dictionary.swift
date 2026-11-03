import Foundation

@main struct UserDictionaryTests {
 static func main() {
var failures = 0
func check(_ ok: Bool, _ what: String) { if !ok { failures += 1; print("FAIL: \(what)") } }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zlm-ud-\(UUID().uuidString)")
let file = dir.appendingPathComponent("ud.json")
let ud = UserDictionary(file: file)
ud.characterReadings = ["亞": "ㄧㄚˋ", "東": "ㄉㄨㄥ"]

try! ud.add(word: "MyJAV", reading: nil)
let zh = try! ud.add(word: "亞東", reading: "")
check(zh.reading == "ㄧㄚˋ-ㄉㄨㄥ", "reading guessed from characters")
check(ud.englishWords == ["MyJAV"], "english words listed")
do { try ud.add(word: "MyJAV", reading: nil); check(false, "duplicate rejected") } catch UserDictionaryError.duplicate {} catch { check(false, "wrong error") }
do { try ud.add(word: "Claude Code", reading: nil); check(false, "space rejected") } catch UserDictionaryError.invalidEnglish {} catch { check(false, "wrong error") }
do { try ud.add(word: "稀有字", reading: nil); check(false, "missing reading") } catch UserDictionaryError.missingReading {} catch { check(false, "wrong error") }
check(UserDictionary(file: file).entries.count == 2, "persisted")
ud.remove(word: "亞東")
check(UserDictionary(file: file).entries.map { $0.word } == ["MyJAV"], "removed and persisted")

let lex = EnglishLexicon(words: ["the", "myself", "myth"], user: ["MyJAV"])
check(lex.completion(for: "my", top: 20) == "myjav", "user word wins completion")
check(lex.display("myjav") == "MyJAV", "user spelling kept")
check(lex.isCommon("myjav", top: 5), "user word counts as common")
let spell = EnglishLexicon(words: ["the", "word", "world", "would", "myself"])
check(spell.correction(for: "wrold") == "world", "swapped letters")
check(spell.correction(for: "wrld") == nil || spell.correction(for: "wrld") == "world", "dropped letter handled")
check(spell.correction(for: "wordd") == "word", "extra letter")
check(spell.correction(for: "worle") != nil, "wrong letter")
check(spell.correction(for: "world") == nil, "known word untouched")
check(spell.correction(for: "teh") == nil, "too short to guess")

let ls = LearningStore(file: dir.appendingPathComponent("l.json"))
check(!ls.recordEnglish("kubernetes") && !ls.recordEnglish("kubernetes"), "not learned before threshold")
check(ls.recordEnglish("kubernetes"), "learned at threshold")
check(!ls.recordEnglish("ab") && !ls.recordEnglish("has2"), "short or non-letter words ignored")
ls.block("terraform")
check(!ls.recordEnglish("terraform") && !ls.recordEnglish("terraform") && !ls.recordEnglish("terraform"), "blocked word never learned")
ls.enabled = false
check(!ls.recordEnglish("grafana") && ls.state.counts["grafana"] == nil, "paused learning records nothing")
ls.enabled = true
check(ls.repairMargin == 1.5, "default margin")
for _ in 0..<40 { ls.recordRepairShown() }
check(ls.repairMargin == 2.5, "ignored offers raise the margin")
for _ in 0..<30 { ls.recordRepairAccepted() }
check(ls.repairMargin == 1.0, "accepted offers lower the margin")
check(LearningStore(file: dir.appendingPathComponent("l.json")).state.repairShown == 40, "learning persisted")
ls.clear()
check(ls.state.counts.isEmpty && ls.state.repairShown == 0 && ls.state.blocked.isEmpty, "clear")

let suite = UserDefaults(suiteName: "zlm-test-\(UUID().uuidString)")!
let log = DebugLog(file: dir.appendingPathComponent("debug.txt"), defaults: suite)
log.record("key=a")
log.flush()
check(!FileManager.default.fileExists(atPath: log.file.path), "nothing written while logging is off")
log.enabled = true
log.record("key=b")
log.flush()
check((try? String(contentsOf: log.file, encoding: .utf8))?.contains("key=b") == true, "written while on")
let perms = (try? FileManager.default.attributesOfItem(atPath: log.file.path))?[.posixPermissions] as? Int
check(perms == 0o600, "owner-only permissions")
log.prune(now: Date().addingTimeInterval(8 * 86400))
check((try? String(contentsOf: log.file, encoding: .utf8))?.isEmpty == true, "entries older than 7 days pruned")
suite.set(Date().addingTimeInterval(-25 * 3600), forKey: "DebugLogEnabledAt")
check(!log.enabled, "auto-off after 24 hours")
log.enabled = true; log.record("key=c"); log.flush(); log.clear()
check(!FileManager.default.fileExists(atPath: log.file.path), "clear removes the file")

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "user dictionary: OK" : "user dictionary: \(failures) failures")
exit(failures == 0 ? 0 : 1)

 }
}
