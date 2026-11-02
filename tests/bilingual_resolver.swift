import Foundation

@main
struct BilingualResolverTests {
    static func main() {
        func check(_ raw: String, word: Bool = false, prefix: Bool = false,
                   zh: Bool = false, boundary: Bool = true,
                   expected: BilingualDecision) {
            let actual = BilingualResolver.decide(BilingualEvidence(
                rawKeys: raw, englishIsWord: word, englishIsPrefix: prefix,
                validZhuyin: zh, boundary: boundary))
            precondition(actual == expected, "Unexpected decision for \(raw): \(actual)")
        }
        check("hello", word: true, expected: .english)
        check("su3", zh: true, expected: .chinese)
        check("hello", word: true, boundary: false, expected: .undecided)
        check("a", word: true, zh: true, expected: .undecided)
        check("hel", prefix: true, zh: true, expected: .undecided)
        check("newbrand", expected: .undecided)
        check("", word: true, expected: .undecided)
        let lexicon = EnglishLexicon(words: ["hello", "Mac", "not-valid!", ""])
        precondition(lexicon.contains("HELLO"))
        precondition(lexicon.containsPrefix("HeL"))
        precondition(lexicon.contains("mac"))
        precondition(!lexicon.contains("hel"))
        precondition(!lexicon.containsPrefix(""))
        precondition(!lexicon.contains("not-valid!"))
        let english = BilingualEvidence(rawKeys: "hello", englishIsWord: lexicon.contains("hello"),
            englishIsPrefix: lexicon.containsPrefix("hello"), validZhuyin: false, boundary: true)
        precondition(BilingualResolver.decide(english) == .english)
        var buffer = BilingualCompositionBuffer()
        for key in "hello" { buffer.append(key) }
        precondition(buffer.rawKeys == "hello")
        precondition(buffer.backspace() && buffer.rawKeys == "hell")
        buffer.append("o")
        precondition(buffer.take() == "hello" && buffer.rawKeys.isEmpty)
        precondition(!buffer.backspace())
        for key in "su3cl3" { buffer.append(key) }
        precondition(buffer.take() == "su3cl3")
        print("Bilingual prototype: decision, lexicon and buffer preservation passed")
    }
}
