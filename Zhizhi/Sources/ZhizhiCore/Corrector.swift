import Foundation

/// A silent homophone correction: the sentences for the model to score, and what each one means.
/// Text the user has fixed, and any character without a same-sound alternative, is left out.
public struct CorrectionPlan: Equatable {
    public struct Swap: Equatable {
        public var segment: Int        // index in `segments`
        public var character: Int      // index inside that segment's text
        public var replacement: Character
    }
    public var segments: [Segment]
    public var texts: [String]         // texts[0] is the sentence as decoded; texts[i + 1] applies swaps[i]
    public var swaps: [Swap]
}

public extension Decoder {
    /// How many same-sound characters are tried per position.
    static let alternativesPerCharacter = 8

    /// Everything still open to correction in `keys`; nil when there is nothing to try.
    func correctionPlan(keys: [Character], segments: [Segment]) -> CorrectionPlan? {
        // An unfinished syllable says nothing yet: score only what is complete before it.
        let finished = segments.last?.kind == .pending ? Array(segments.dropLast()) : segments
        var swaps: [CorrectionPlan.Swap] = []
        var texts = [render(finished)]
        for (index, segment) in finished.enumerated() where segment.kind == .chinese {
            let characters = Array(segment.text)
            guard characters.count == segment.syllableEnds.count else { continue }   // fixed text
            var start = segment.range.lowerBound
            for (position, end) in segment.syllableEnds.enumerated() {
                for replacement in alternatives(keys: keys, range: start..<end) where replacement != characters[position] {
                    var changed = characters
                    changed[position] = replacement
                    var variant = finished
                    variant[index].text = String(changed)
                    swaps.append(.init(segment: index, character: position, replacement: replacement))
                    texts.append(render(variant))
                }
                start = end
            }
        }
        return swaps.isEmpty ? nil : CorrectionPlan(segments: finished, texts: texts, swaps: swaps)
    }

    /// Constraints that keep each corrected word, given the model's score for every text.
    /// A swap needs to raise the sentence's log-probability by at least `threshold`.
    func corrections(plan: CorrectionPlan, logprobs: [Float], threshold: Float) -> [Constraint] {
        guard logprobs.count == plan.texts.count else { return [] }
        var best: [Int: (gain: Float, swap: CorrectionPlan.Swap)] = [:]   // per character position
        for (i, swap) in plan.swaps.enumerated() {
            let gain = logprobs[i + 1] - logprobs[0]
            let key = swap.segment << 16 | swap.character
            if gain >= threshold, gain > best[key]?.gain ?? -.infinity { best[key] = (gain, swap) }
        }
        var bySegment: [Int: [CorrectionPlan.Swap]] = [:]
        for (_, value) in best { bySegment[value.swap.segment, default: []].append(value.swap) }
        return bySegment.keys.sorted().map { index in
            let segment = plan.segments[index]
            var characters = Array(segment.text)
            for swap in bySegment[index]! { characters[swap.character] = swap.replacement }
            var constraint = Constraint(range: segment.range, fix: .text(String(characters), .chinese))
            constraint.syllableEnds = segment.syllableEnds.map { $0 - segment.range.lowerBound }
            constraint.correctedFrom = segment.text
            return constraint
        }
    }
}
