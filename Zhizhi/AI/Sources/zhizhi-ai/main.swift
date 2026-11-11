import Foundation
import MLX
import MLXNN
import Tokenizers

// Local scoring helper for 知之. Reads JSON lines on stdin and writes JSON lines on stdout:
//   {"id":1,"texts":["一句話","一句活"]}  ->  {"id":1,"logprobs":[-20.1,-31.7]}
// Never opens a network connection and never stores or prints the text it scores. It exits when
// stdin closes, so it cannot outlive the input method, and after five idle minutes, to free memory.

struct Qwen2Config: Decodable {
    let hidden_size: Int
    let num_hidden_layers: Int
    let num_attention_heads: Int
    let num_key_value_heads: Int
    let intermediate_size: Int
    let rms_norm_eps: Float
    let rope_theta: Float
    let vocab_size: Int
    let quantization: Quantization?
    struct Quantization: Decodable { let group_size: Int; let bits: Int }
}

final class Attention: Module {
    let heads: Int, keyValueHeads: Int, scale: Float
    @ModuleInfo(key: "q_proj") var q: Linear
    @ModuleInfo(key: "k_proj") var k: Linear
    @ModuleInfo(key: "v_proj") var v: Linear
    @ModuleInfo(key: "o_proj") var o: Linear
    let rope: RoPE

    init(_ c: Qwen2Config) {
        heads = c.num_attention_heads
        keyValueHeads = c.num_key_value_heads
        let headDim = c.hidden_size / heads
        scale = pow(Float(headDim), -0.5)
        _q.wrappedValue = Linear(c.hidden_size, heads * headDim, bias: true)
        _k.wrappedValue = Linear(c.hidden_size, keyValueHeads * headDim, bias: true)
        _v.wrappedValue = Linear(c.hidden_size, keyValueHeads * headDim, bias: true)
        _o.wrappedValue = Linear(heads * headDim, c.hidden_size, bias: false)
        rope = RoPE(dimensions: headDim, traditional: false, base: c.rope_theta)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let (batch, length) = (x.dim(0), x.dim(1))
        var queries = q(x).reshaped(batch, length, heads, -1).transposed(0, 2, 1, 3)
        var keys = k(x).reshaped(batch, length, keyValueHeads, -1).transposed(0, 2, 1, 3)
        let values = v(x).reshaped(batch, length, keyValueHeads, -1).transposed(0, 2, 1, 3)
        queries = rope(queries, offset: 0)
        keys = rope(keys, offset: 0)
        // Grouped-query attention: every query head group shares one key/value head.
        let repeats = heads / keyValueHeads
        let output = MLXFast.scaledDotProductAttention(
            queries: queries,
            keys: repeated(keys, count: repeats, axis: 1),
            values: repeated(values, count: repeats, axis: 1),
            scale: scale, mask: .array(mask))
        return o(output.transposed(0, 2, 1, 3).reshaped(batch, length, -1))
    }
}

final class FeedForward: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "down_proj") var down: Linear
    @ModuleInfo(key: "up_proj") var up: Linear

    init(_ c: Qwen2Config) {
        _gate.wrappedValue = Linear(c.hidden_size, c.intermediate_size, bias: false)
        _down.wrappedValue = Linear(c.intermediate_size, c.hidden_size, bias: false)
        _up.wrappedValue = Linear(c.hidden_size, c.intermediate_size, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { down(silu(gate(x)) * up(x)) }
}

final class Block: Module {
    @ModuleInfo(key: "self_attn") var attention: Attention
    let mlp: FeedForward
    @ModuleInfo(key: "input_layernorm") var inputNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var outputNorm: RMSNorm

    init(_ c: Qwen2Config) {
        _attention.wrappedValue = Attention(c)
        mlp = FeedForward(c)
        _inputNorm.wrappedValue = RMSNorm(dimensions: c.hidden_size, eps: c.rms_norm_eps)
        _outputNorm.wrappedValue = RMSNorm(dimensions: c.hidden_size, eps: c.rms_norm_eps)
    }

    func callAsFunction(_ x: MLXArray, mask: MLXArray) -> MLXArray {
        let h = x + attention(inputNorm(x), mask: mask)
        return h + mlp(outputNorm(h))
    }
}

final class Backbone: Module {
    @ModuleInfo(key: "embed_tokens") var embed: Embedding
    let layers: [Block]
    let norm: RMSNorm

    init(_ c: Qwen2Config) {
        _embed.wrappedValue = Embedding(embeddingCount: c.vocab_size, dimensions: c.hidden_size)
        layers = (0..<c.num_hidden_layers).map { _ in Block(c) }
        norm = RMSNorm(dimensions: c.hidden_size, eps: c.rms_norm_eps)
    }
}

final class Qwen2: Module {
    let model: Backbone
    init(_ c: Qwen2Config) { model = Backbone(c) }

    /// Tied weights: the output layer is the embedding read backwards.
    func logits(_ ids: MLXArray) -> MLXArray {
        var h = model.embed(ids)
        let mask = MultiHeadAttention.createAdditiveCausalMask(h.dim(1), dtype: h.dtype)
        for layer in model.layers { h = layer(h, mask: mask) }
        return model.embed.asLinear(model.norm(h))
    }
}

struct Request: Decodable { let id: Int; let texts: [String] }

final class Scorer {
    static let batchSize = 16
    let model: Qwen2
    let tokenizer: Tokenizer
    let start: [Int]

    init(folder: URL) async throws {
        let config = try JSONDecoder().decode(Qwen2Config.self, from: Data(contentsOf: folder.appendingPathComponent("config.json")))
        model = Qwen2(config)
        if let q = config.quantization { quantize(model: model, groupSize: q.group_size, bits: q.bits) }
        let weights = try loadArrays(url: folder.appendingPathComponent("model.safetensors"))
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        eval(model)
        tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        start = tokenizer.encode(text: "\n", addSpecialTokens: false)   // Qwen has no BOS token
    }

    /// Whole-sentence log-probability of each text, conditioned on a leading newline.
    func score(_ texts: [String]) -> [Float] {
        var results: [Float] = []
        results.reserveCapacity(texts.count)
        for from in stride(from: 0, to: texts.count, by: Self.batchSize) {
            let chunk = texts[from..<min(from + Self.batchSize, texts.count)]
            let rows = chunk.map { start + tokenizer.encode(text: $0, addSpecialTokens: false) }
            let width = rows.map(\.count).max() ?? 0
            guard width >= 2 else { results += rows.map { _ in 0 }; continue }
            // Right padding is safe: attention is causal, and padded targets are masked out below.
            let flat = rows.flatMap { $0.map(Int32.init) + Array(repeating: 0, count: width - $0.count) }
            let ids = MLXArray(flat, [rows.count, width])
            let logits = model.logits(ids[0..., 0..<(width - 1)]).asType(.float32)
            let targets = ids[0..., 1...]
            let picked = takeAlong(logSoftmax(logits, axis: -1), expandedDimensions(targets, axis: -1), axis: -1).squeezed(axis: -1)
            let valid = MLXArray(rows.flatMap { row in (1..<width).map { Float($0 < row.count ? 1 : 0) } }, [rows.count, width - 1])
            results += (picked * valid).sum(axis: 1).asArray(Float.self)
        }
        return results
    }
}

func reply(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
    FileHandle.standardOutput.write(data + Data([0x0A]))
}

@main
struct Helper {
    static func main() async {
        guard CommandLine.arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: zhizhi-ai <model folder>\n".utf8))
            exit(2)
        }
        let scorer: Scorer
        do {
            scorer = try await Scorer(folder: URL(fileURLWithPath: CommandLine.arguments[1]))
        } catch {
            reply(["error": "load failed: \(error)"])
            exit(1)
        }
        _ = scorer.score(["預熱"])
        reply(["ready": true])

        let idleLimit: TimeInterval = 300
        let lock = NSLock()
        var last = Date()
        Thread.detachNewThread {
            while true {
                Thread.sleep(forTimeInterval: 15)
                lock.lock(); let idle = Date().timeIntervalSince(last); lock.unlock()
                if idle > idleLimit { exit(0) }
            }
        }
        while let line = readLine(strippingNewline: true) {
            lock.lock(); last = Date(); lock.unlock()
            guard let request = try? JSONDecoder().decode(Request.self, from: Data(line.utf8)) else { continue }
            reply(["id": request.id, "logprobs": scorer.score(request.texts).map(Double.init)])
            lock.lock(); last = Date(); lock.unlock()
        }
    }
}
