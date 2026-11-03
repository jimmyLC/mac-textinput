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

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "user dictionary: OK" : "user dictionary: \(failures) failures")
exit(failures == 0 ? 0 : 1)

 }
}
