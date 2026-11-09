import Foundation
import CoreGraphics
import CLlama
import CortexCore
import EmbeddingGemma2MLX

public actor LlamaCppMetalBackend: EmbeddingBackend {
    public let engineKind: EngineKind = .llamaMetal
    public let engineName: String = "llama.cpp (Metal Q8_0 GGUF)"

    private let modelsDir: URL
    nonisolated(unsafe) private var model: OpaquePointer?
    nonisolated(unsafe) private var context: OpaquePointer?
    nonisolated(unsafe) private var media: OpaquePointer?
    nonisolated(unsafe) private var batch: OpaquePointer?
    nonisolated(unsafe) private var vocab: OpaquePointer?
    private var embeddingSize: Int = 768
    private var rowSize: Int = 768
    private var maxTokens: Int = 512
    private var sequences: Int32 = 0
    private var tokens: Int = 0
    private var position: llama_pos = 0
    private static let maxSequences = 16

    public private(set) var isTextLoaded: Bool = false
    public private(set) var isVisionLoaded: Bool = false

    nonisolated(unsafe) private static var backendInitialized: Bool = false
    private static let initLock = NSLock()

    /// Shared llama.cpp backend initialisation for other llama-based components (e.g. the reranker).
    public static func ensureBackendInitializedPublic() { ensureBackendInitialized() }

    private static func ensureBackendInitialized() {
        initLock.withLock {
            guard !backendInitialized else { return }
            llama_log_set({ level, text, _ in
                guard level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text else { return }
                FileHandle.standardError.write(Data(String(cString: text).utf8))
            }, nil)
            mtmd_helper_log_set({ level, text, _ in
                guard level.rawValue >= GGML_LOG_LEVEL_ERROR.rawValue, let text else { return }
                FileHandle.standardError.write(Data(String(cString: text).utf8))
            }, nil)
            // ggml keeps Metal memory wired (polling every 5 ms) for this long after the last GPU use; the 3 min
            // default is meant for chat servers. Embedding queries are short, so release the GPU sooner.
            setenv("GGML_METAL_RESIDENCY_KEEP_ALIVE_S", "60", 0)
            llama_backend_init()
            backendInitialized = true
        }
    }

    public init(modelsDirectory: URL = CortexPaths.llamaModelsDir) {
        self.modelsDir = modelsDirectory
    }

    deinit {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
    }

    private var textModelURL: URL {
        let primary = modelsDir.appendingPathComponent("embeddinggemma-2-Q8_0.gguf")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        let digupFallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DigUp/Models/embeddinggemma-2-Q8_0.gguf")
        return digupFallback
    }

    private var mmprojModelURL: URL {
        let primary = modelsDir.appendingPathComponent("mmproj-embeddinggemma-2-Q8_0.gguf")
        if FileManager.default.fileExists(atPath: primary.path) { return primary }
        let digupFallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DigUp/Models/mmproj-embeddinggemma-2-Q8_0.gguf")
        return digupFallback
    }

    public func loadTextTowerOnly() async throws {
        Self.ensureBackendInitialized()
        if isTextLoaded {
            return
        }
        try initializeContext(withVision: false)
    }

    public func loadVisionTower() async throws {
        Self.ensureBackendInitialized()
        if isTextLoaded && isVisionLoaded { return }
        if isTextLoaded && !isVisionLoaded {
            if maxTokens >= 2048, let loadedModel = model {
                let mmURL = mmprojModelURL
                if FileManager.default.fileExists(atPath: mmURL.path) {
                    var mparams = mtmd_context_params_default()
                    mparams.use_gpu = true
                    mparams.print_timings = false
                    mparams.warmup = true
                    mparams.image_min_tokens = 1
                    mparams.image_max_tokens = 1120
                    if let loadedMedia = mtmd_init_from_file(mmURL.path, loadedModel, mparams) {
                        self.media = loadedMedia
                        self.isVisionLoaded = true
                        return
                    }
                }
            }
            // Re-init context with 2048 tokens for vision soft tokens + attach mtmd
            await unloadAll()
        }
        try initializeContext(withVision: true)
    }

    public func unloadVisionTower() async {
        guard isVisionLoaded else { return }
        if let media {
            mtmd_free(media)
            self.media = nil
        }
        isVisionLoaded = false
    }

    public func unloadAll() async {
        if let batch { llama_batch_ext_free(batch) }
        if let media { mtmd_free(media) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        batch = nil
        media = nil
        context = nil
        model = nil
        vocab = nil
        sequences = 0
        tokens = 0
        position = 0
        isTextLoaded = false
        isVisionLoaded = false
    }

    public func currentMemoryBytes() async -> UInt64 {
        ProcessMemory.residentBytes()
    }

    private func initializeContext(withVision: Bool) throws {
        let textURL = textModelURL
        guard FileManager.default.fileExists(atPath: textURL.path) else {
            throw EmbedderError.modelNotFound("Missing GGUF text model at \(textURL.path)")
        }
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999
        guard let loadedModel = llama_model_load_from_file(textURL.path, modelParams) else {
            throw EmbedderError.initializationFailed("llama_model_load_from_file failed for \(textURL.path)")
        }

        let isTurbo = PowerManager.shared.activeThrottlingMode() == .turbo
        let targetTokens = (withVision || isTurbo) ? 2048 : 512
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(targetTokens)
        cparams.n_batch = UInt32(targetTokens)
        cparams.n_ubatch = UInt32(targetTokens)
        cparams.n_seq_max = UInt32(Self.maxSequences)
        cparams.kv_unified = true
        cparams.embeddings = true
        cparams.pooling_type = LLAMA_POOLING_TYPE_MEAN

        guard let loadedCtx = llama_init_from_model(loadedModel, cparams) else {
            llama_model_free(loadedModel)
            throw EmbedderError.initializationFailed("llama_init_from_model failed")
        }

        var loadedMedia: OpaquePointer?
        if withVision {
            let mmURL = mmprojModelURL
            guard FileManager.default.fileExists(atPath: mmURL.path) else {
                llama_free(loadedCtx)
                llama_model_free(loadedModel)
                throw EmbedderError.modelNotFound("Missing GGUF mmproj model at \(mmURL.path)")
            }
            var mparams = mtmd_context_params_default()
            mparams.use_gpu = true
            mparams.print_timings = false
            mparams.warmup = true
            mparams.image_min_tokens = 1
            mparams.image_max_tokens = 1120
            loadedMedia = mtmd_init_from_file(mmURL.path, loadedModel, mparams)
            if loadedMedia == nil {
                llama_free(loadedCtx)
                llama_model_free(loadedModel)
                throw EmbedderError.initializationFailed("mtmd_init_from_file failed for \(mmURL.path)")
            }
        }

        self.model = loadedModel
        self.context = loadedCtx
        self.media = loadedMedia
        self.batch = llama_batch_ext_init(loadedCtx)
        self.vocab = llama_model_get_vocab(loadedModel)
        self.embeddingSize = Int(llama_model_n_embd_out(loadedModel))
        self.rowSize = Int(llama_model_n_embd_inp(loadedModel))
        self.maxTokens = targetTokens
        self.isTextLoaded = true
        self.isVisionLoaded = withVision

        // Warm up Metal pipeline
        _ = try encodeFormattedTexts(["task: search result | query: warmup"], dimension: .d768)
    }

    // MARK: - EmbeddingBackend Methods

    public func embedQuery(_ text: String, dimension: MatryoshkaDimension = .d768) async throws -> [Float] {
        if !isTextLoaded { try await loadTextTowerOnly() }
        let s = CortexSettingsManager.shared.settings
        let prompt = s.embeddingTaskMode.formatQuery(text, isAIMode: s.enableAISynthesis)
        let vectors = try encodeFormattedTexts([prompt], dimension: dimension)
        guard let first = vectors.first else { throw EmbedderError.encodingFailed("No query vector produced") }
        return first
    }

    public func embedDocuments(_ docs: [(title: String?, body: String)], dimension: MatryoshkaDimension = .d768) async throws -> [[Float]] {
        guard !docs.isEmpty else { return [] }
        if !isTextLoaded { try await loadTextTowerOnly() }
        let prompts = docs.map { d in
            EmbeddingTaskMode.formatDocument(title: d.title, body: d.body)
        }
        return try encodeFormattedTexts(prompts, dimension: dimension)
    }

    public func embedImage(url: URL, softTokens: Int = 280, dimension: MatryoshkaDimension = .d768) async throws -> [Float] {
        let rgb = try RGBImage.load(url)
        return try await embedRGBBytes(rgb.bytes, width: rgb.width, height: rgb.height, budget: softTokens, dimension: dimension)
    }

    public func embedCGImage(_ image: CGImage, softTokens: Int = 280, dimension: MatryoshkaDimension = .d768) async throws -> [Float] {
        let rgb = try RGBImage.fromCGImage(image)
        return try await embedRGBBytes(rgb.bytes, width: rgb.width, height: rgb.height, budget: softTokens, dimension: dimension)
    }

    // MARK: - Internal Llama / MTMD Execution

    private func embedRGBBytes(_ rgb: [UInt8], width: Int, height: Int, budget: Int, dimension: MatryoshkaDimension) async throws -> [Float] {
        if !isVisionLoaded { try await loadVisionTower() }
        guard let media else { throw EmbedderError.initializationFailed("Vision media context not loaded") }
        guard let target = ImageSizing.targetSize(height: height, width: width, budget: budget) else {
            throw EmbedderError.encodingFailed("Image too small or thin (\(width)x\(height))")
        }
        let resizedPixels: [UInt8] = rgb.withUnsafeBufferPointer { ptr in
            ImageSizing.resizeBicubic(ptr.baseAddress!, width: width, height: height, toWidth: target.width, toHeight: target.height)
        }
        guard let bitmap = resizedPixels.withUnsafeBufferPointer({ ptr in
            mtmd_bitmap_init(UInt32(target.width), UInt32(target.height), ptr.baseAddress)
        }) else {
            throw EmbedderError.encodingFailed("mtmd_bitmap_init failed")
        }
        defer { mtmd_bitmap_free(bitmap) }

        let chunks = mtmd_input_chunks_init()
        defer { mtmd_input_chunks_free(chunks) }

        var bitmaps: [OpaquePointer?] = [bitmap]
        let status = String(cString: mtmd_default_marker()).withCString { marker in
            var inputText = mtmd_input_text(text: marker, text_len: strlen(marker), add_special: true, parse_special: true)
            return mtmd_tokenize(media, chunks, &inputText, &bitmaps, 1)
        }
        guard status == 0 else {
            throw EmbedderError.encodingFailed("mtmd_tokenize failed with status \(status)")
        }

        resetBatch()
        beginSequence()
        for index in 0..<mtmd_input_chunks_size(chunks) {
            let chunk = mtmd_input_chunks_get(chunks, index)
            if mtmd_input_chunk_get_type(chunk) == MTMD_INPUT_CHUNK_TYPE_TEXT {
                var count = 0
                guard let tokPtr = mtmd_input_chunk_get_tokens_text(chunk, &count) else { continue }
                for i in 0..<count { try addToken(tokPtr[i]) }
            } else {
                guard mtmd_encode_chunk(media, chunk) == 0, let rows = mtmd_get_output_embd(media) else {
                    throw EmbedderError.encodingFailed("mtmd_encode_chunk failed")
                }
                try addRows(rows, count: Int(mtmd_input_chunk_get_n_tokens(chunk)))
            }
        }
        let out = try runBatch(dimension: dimension)
        guard let vec = out.first else { throw EmbedderError.encodingFailed("Empty image embedding") }
        return vec
    }

    private func encodeFormattedTexts(_ texts: [String], dimension: MatryoshkaDimension) throws -> [[Float]] {
        resetBatch()
        var results: [[Float]] = []
        for text in texts {
            let toks = tokenize(text)
            if sequences == Self.maxSequences || (tokens + toks.count > maxTokens && sequences > 0) {
                results += try runBatch(dimension: dimension)
            }
            beginSequence()
            for tok in toks { try addToken(tok) }
        }
        if sequences > 0 {
            results += try runBatch(dimension: dimension)
        }
        return results
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        var out = [llama_token](repeating: 0, count: utf8.count + 8)
        var count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), true, true)
        if count < 0 {
            out = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, utf8, Int32(utf8.count - 1), &out, Int32(out.count), true, true)
        }
        out.removeLast(out.count - Int(max(count, 0)))
        let textLimit = min(maxTokens, 512)
        if out.count > textLimit {
            out = Array(out[0..<(textLimit - 1)]) + [llama_vocab_eos(vocab)]
        }
        return out
    }

    private func beginSequence() {
        sequences += 1
        position = 0
    }

    private func resetBatch() {
        if let batch { llama_batch_ext_clear(batch) }
        sequences = 0
        tokens = 0
    }

    private func addToken(_ token: llama_token) throws {
        guard let batch else { throw EmbedderError.initializationFailed("No batch allocated") }
        try place(llama_batch_ext_add_token(batch, sequences - 1, token))
    }

    private func addRows(_ rows: UnsafeMutablePointer<Float>, count: Int) throws {
        guard let batch else { throw EmbedderError.initializationFailed("No batch allocated") }
        for row in 0..<count {
            let embd = llama_embd(data: rows + row * rowSize, n_rows: 1, n_embd: rowSize)
            try place(llama_batch_ext_add_embd(batch, sequences - 1, embd))
        }
    }

    private func place(_ index: Int32) throws {
        guard let batch, index >= 0 else { throw EmbedderError.encodingFailed("llama_batch full (\(index))") }
        var pos: [llama_pos] = [position, 0, 0, 0]
        guard llama_batch_ext_set_pos(batch, index, &pos), llama_batch_ext_set_output_embd(batch, index, true) else {
            throw EmbedderError.encodingFailed("Failed to place token \(index)")
        }
        position += 1
        tokens += 1
    }

    private func runBatch(dimension: MatryoshkaDimension) throws -> [[Float]] {
        defer { resetBatch() }
        guard let context, let batch else { throw EmbedderError.initializationFailed("No context/batch") }
        let status = llama_process(context, LLAMA_PROCESS_TYPE_ENCODE, batch)
        guard status == 0 else {
            throw EmbedderError.encodingFailed("llama_process failed with status \(status)")
        }
        let targetDim = min(dimension.rawValue, embeddingSize)
        return try (0..<sequences).map { seq in
            guard let pooled = llama_get_embeddings_seq(context, seq) else {
                throw EmbedderError.encodingFailed("Missing pooled embedding for seq \(seq)")
            }
            var sum = 0.0
            for i in 0..<targetDim {
                sum += Double(pooled[i]) * Double(pooled[i])
            }
            let scale = sum > 0 ? Float(1.0 / sum.squareRoot()) : 0
            return (0..<targetDim).map { pooled[$0] * scale }
        }
    }
}
