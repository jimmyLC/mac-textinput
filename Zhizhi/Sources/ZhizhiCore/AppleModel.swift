import Foundation
#if canImport(FoundationModels)
@_weakLinked import FoundationModels
#endif

/// Something that can judge a correction plan. Scores line up with `plan.texts`; nil means no answer.
public protocol CorrectionBackend: AnyObject {
    var isAvailable: Bool { get }
    func score(plan: CorrectionPlan, completion: @escaping ([Float]?) -> Void)
    func stop()
}

extension HelperClient: CorrectionBackend {
    public func score(plan: CorrectionPlan, completion: @escaping ([Float]?) -> Void) {
        score(plan.texts, completion: completion)
    }
}

public extension CorrectionPlan {
    /// Turns a rewritten sentence into scores. A model that rewrites cannot be trusted with the
    /// sentence itself, so only same-sound swaps the plan already allows can come through it.
    func scores(forRewrite rewrite: String) -> [Float]? {
        // Models like to add a full stop or a space; only the words are compared.
        func words(_ s: String) -> [Character] { s.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol } }
        let base = words(texts[0]), new = words(rewrite)
        guard base.count == new.count else { return nil }
        var result: [Float] = [0]
        for variant in texts.dropFirst() {
            let characters = words(variant)
            guard characters.count == base.count,
                  let position = base.indices.first(where: { base[$0] != characters[$0] }) else {
                result.append(-CorrectionPlan.decisive)
                continue
            }
            result.append(new[position] == characters[position] ? CorrectionPlan.decisive : -CorrectionPlan.decisive)
        }
        return result
    }

    /// Far past any threshold: a rewrite gives a yes or no, not a degree of confidence.
    static let decisive: Float = 100
}

/// Apple's on-device model. It lives in the system, so 知之 downloads nothing and holds no memory for it.
public final class AppleModelBackend: CorrectionBackend {
    public enum Status: Equatable {
        case available
        case osTooOld
        case deviceNotEligible
        case appleIntelligenceOff
        case modelNotReady
        case unknown
    }

    static let instructions = "你是繁體中文注音輸入法的校對器。使用者句子由注音輸入產生，可能有同音字選錯的錯字。只修正同音錯字，不改寫、不增刪、不加標點。若沒有錯字，原樣輸出。只輸出句子本身。"

    /// Why the last request gave no answer, without any of the text; for the debug log.
    public private(set) var lastFailure: String?

    public init() {}

    public static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(.deviceNotEligible): return .deviceNotEligible
            case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceOff
            case .unavailable(.modelNotReady): return .modelNotReady
            case .unavailable: return .unknown
            }
        }
        #endif
        return .osTooOld
    }

    public var isAvailable: Bool { Self.status == .available }

    public func score(plan: CorrectionPlan, completion: @escaping ([Float]?) -> Void) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), isAvailable {
            let text = plan.texts[0]
            Task { [weak self] in
                do {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    let answer = try await session.respond(to: text, options: GenerationOptions(temperature: 0))
                    self?.lastFailure = nil
                    completion(plan.scores(forRewrite: answer.content.trimmingCharacters(in: .whitespacesAndNewlines)))
                } catch {
                    self?.lastFailure = String(describing: type(of: error))
                    completion(nil)
                }
            }
            return
        }
        #endif
        completion(nil)
    }

    public func stop() {}    // the system manages this model's memory
}
