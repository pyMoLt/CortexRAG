import Foundation
import CLlama
import CortexCore

/// Cross-encoder reranking with GGUF models via llama.cpp (pooling type RANK), e.g. bge-reranker-v2-m3
/// or Qwen3-Reranker. Mirrors llama.cpp's server prompt format: the model's "rerank" chat template if present,
/// otherwise `<bos> query <eos><sep> document <eos>`.
public actor LlamaReranker {
    public enum RerankError: Error, CustomStringConvertible {
        case modelNotFound(String), initFailed(String), processFailed(String)
        public var description: String {
            switch self {
            case .modelNotFound(let s), .initFailed(let s), .processFailed(let s): return s
            }
        }
    }

    public let modelURL: URL
    nonisolated(unsafe) private var model: OpaquePointer?
    nonisolated(unsafe) private var context: OpaquePointer?
    nonisolated(unsafe) private var vocab: OpaquePointer?
    nonisolated(unsafe) private var batch: OpaquePointer?
    private var template: String?
    private let maxBatchTokens = 4096
    private let maxSequences = 8
    /// Documents are truncated to this many tokens (chunks are ~850 characters ≈ 250 tokens).
    private let maxDocTokens = 512

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    deinit {
        if let batch { llama_batch_ext_free(batch) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    public var isLoaded: Bool { context != nil }

    public func load() throws {
        guard context == nil else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw RerankError.modelNotFound("Reranker-Modell fehlt: \(modelURL.path)")
        }
        LlamaCppMetalBackend.ensureBackendInitializedPublic()
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 999
        guard let m = llama_model_load_from_file(modelURL.path, mparams) else {
            throw RerankError.initFailed("llama_model_load_from_file fehlgeschlagen")
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(maxBatchTokens)
        cparams.n_batch = UInt32(maxBatchTokens)
        cparams.n_ubatch = UInt32(maxBatchTokens)
        cparams.n_seq_max = UInt32(maxSequences)
        cparams.kv_unified = true
        cparams.embeddings = true
        cparams.pooling_type = LLAMA_POOLING_TYPE_RANK
        guard let ctx = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            throw RerankError.initFailed("llama_init_from_model fehlgeschlagen")
        }
        model = m
        context = ctx
        vocab = llama_model_get_vocab(m)
        batch = llama_batch_ext_init(ctx)
        template = llama_model_chat_template(m, "rerank").map { String(cString: $0) }
    }

    public func unload() {
        if let batch { llama_batch_ext_free(batch) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        batch = nil
        context = nil
        model = nil
        vocab = nil
    }

    /// Relevance score per document (higher = more relevant), in input order.
    public func score(query: String, documents: [String]) throws -> [Float] {
        try load()
        guard let context, let batch else { throw RerankError.initFailed("Kontext fehlt") }
        let sequences = documents.map { tokensFor(query: query, document: $0) }
        var scores = [Float](repeating: 0, count: documents.count)
        var start = 0
        while start < sequences.count {
            llama_memory_clear(llama_get_memory(context), true)
            llama_batch_ext_clear(batch)
            var used = 0
            var seq: Int32 = 0
            var end = start
            while end < sequences.count, seq < Int32(maxSequences), used + sequences[end].count <= maxBatchTokens {
                for (pos, tok) in sequences[end].enumerated() {
                    let idx = llama_batch_ext_add_token(batch, seq, tok)
                    guard idx >= 0 else { throw RerankError.processFailed("Batch voll") }
                    var p: [llama_pos] = [llama_pos(pos), 0, 0, 0]
                    _ = llama_batch_ext_set_pos(batch, idx, &p)
                    _ = llama_batch_ext_set_output_embd(batch, idx, true)
                }
                used += sequences[end].count
                seq += 1
                end += 1
            }
            if end == start { end = start + 1 } // single over-long sequence: already truncated, cannot happen
            let status = llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch)
            guard status == 0 else { throw RerankError.processFailed("llama_process Status \(status)") }
            for s in 0..<Int32(end - start) {
                if let out = llama_get_embeddings_seq(context, s) {
                    scores[start + Int(s)] = out[0]
                }
            }
            start = end
        }
        return scores
    }

    private func tokenize(_ text: String, special: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var out = [llama_token](repeating: 0, count: utf8.count + 8)
        var n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), false, special)
        if n < 0 {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), false, special)
        }
        return Array(out.prefix(Int(max(n, 0))))
    }

    private func truncatedDoc(_ doc: String) -> String {
        // Character-level pre-cut keeps tokenization cheap; exact limit is enforced on tokens below.
        String(doc.prefix(maxDocTokens * 4))
    }

    private func tokensFor(query: String, document: String) -> [llama_token] {
        let doc = truncatedDoc(document)
        if let template {
            let prompt = template.replacingOccurrences(of: "{query}", with: query).replacingOccurrences(of: "{document}", with: doc)
            return Array(tokenize(prompt, special: true).suffix(maxBatchTokens / maxSequences * 2))
        }
        var out: [llama_token] = []
        var eos = llama_vocab_eos(vocab)
        if eos == LLAMA_TOKEN_NULL { eos = llama_vocab_sep(vocab) }
        if llama_vocab_get_add_bos(vocab) { out.append(llama_vocab_bos(vocab)) }
        out += tokenize(query, special: false).prefix(128)
        if llama_vocab_get_add_eos(vocab) { out.append(eos) }
        if llama_vocab_get_add_sep(vocab) { out.append(llama_vocab_sep(vocab)) }
        out += tokenize(doc, special: false).prefix(maxDocTokens)
        if llama_vocab_get_add_eos(vocab) { out.append(eos) }
        return out
    }
}
