import Foundation
import FoundationModels

/// Asks Apple's on-device model to fix homophone mistakes in each baseline sentence.
/// Usage: apple_fm_eval baseline.json out.json   (needs Apple Intelligence available)
struct Row: Codable { var gold: String; var syllables: [String]; var baseline: String?; var model: String? }

@main struct Eval {
    static func main() async throws {
        let args = CommandLine.arguments
        var rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        guard case .available = SystemLanguageModel.default.availability else { print("model unavailable"); return }
        let instructions = "你是繁體中文注音輸入法的校對器。使用者句子由注音輸入產生，可能有同音字選錯的錯字。只修正同音錯字，不改寫、不增刪、不加標點。若沒有錯字，原樣輸出。只輸出句子本身。"
        var start = Date()
        for i in rows.indices {
            guard let base = rows[i].baseline else { continue }
            let session = LanguageModelSession(instructions: instructions)
            do {
                let r = try await session.respond(to: base, options: GenerationOptions(temperature: 0))
                rows[i].model = r.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch { rows[i].model = nil }
            if i % 20 == 19 { print("\(i + 1)/\(rows.count) \(Date().timeIntervalSince(start))s"); start = Date() }
        }
        try JSONEncoder().encode(rows).write(to: URL(fileURLWithPath: args[2]))
    }
}
