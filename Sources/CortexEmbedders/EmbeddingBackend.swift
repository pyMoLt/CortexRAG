import Foundation
import CoreGraphics
import Darwin
import CortexCore
import EmbeddingGemma2MLX

public enum EmbeddingModality: Sendable {
    case queryText(String)
    case documentText(title: String?, body: String)
    case imageURL(URL, softTokens: Int)
    case cgImage(CGImage, softTokens: Int)
}

public enum EmbedderError: Error, CustomStringConvertible {
    case modelNotFound(String)
    case initializationFailed(String)
    case encodingFailed(String)

    public var description: String {
        switch self {
        case .modelNotFound(let msg): return "Model not found: \(msg)"
        case .initializationFailed(let msg): return "Engine initialization failed: \(msg)"
        case .encodingFailed(let msg): return "Encoding failed: \(msg)"
        }
    }
}

public protocol EmbeddingBackend: Actor {
    var engineKind: EngineKind { get }
    var engineName: String { get }
    var isTextLoaded: Bool { get }
    var isVisionLoaded: Bool { get }

    func loadTextTowerOnly() async throws
    func loadVisionTower() async throws
    func unloadVisionTower() async
    func unloadAll() async
    func currentMemoryBytes() async -> UInt64

    func embedQuery(_ text: String, dimension: MatryoshkaDimension) async throws -> [Float]
    func embedDocuments(_ docs: [(title: String?, body: String)], dimension: MatryoshkaDimension) async throws -> [[Float]]
    func embedImage(url: URL, softTokens: Int, dimension: MatryoshkaDimension) async throws -> [Float]
    func embedCGImage(_ image: CGImage, softTokens: Int, dimension: MatryoshkaDimension) async throws -> [Float]
}

// MARK: - Process Memory Helper

public enum ProcessMemory {
    public static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }

    public static func hardwareChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "Apple Silicon" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}

// MARK: - MLX Swift Backend

public actor MLXSwiftBackend: EmbeddingBackend {
    public let engineKind: EngineKind = .mlxSwift
    public let engineName: String = "MLX Swift (EmbeddingGemma-2 Q8 + BF16)"

    private let baseDir: URL
    private var encoder: TextEncoder?
    public private(set) var isTextLoaded: Bool = false
    public private(set) var isVisionLoaded: Bool = false

    public init(modelsDirectory: URL = CortexPaths.mlxModelsDir) {
        self.baseDir = modelsDirectory
    }

    private var textModelDir: URL { baseDir.appendingPathComponent("text-q8") }
    private var visionModelDir: URL { baseDir.appendingPathComponent("vision-q8") }

    public func loadTextTowerOnly() async throws {
        if let encoder {
            if isVisionLoaded {
                await encoder.disableVision()
                isVisionLoaded = false
            }
            return
        }
        guard FileManager.default.fileExists(atPath: textModelDir.appendingPathComponent("model.safetensors").path) else {
            throw EmbedderError.modelNotFound("Missing MLX text-q8 weights at \(textModelDir.path)")
        }
        encoder = try await TextEncoder(directory: textModelDir, float32: false)
        isTextLoaded = true
        isVisionLoaded = false
    }

    public func loadVisionTower() async throws {
        if encoder == nil {
            try await loadTextTowerOnly()
        }
        guard let encoder else { throw EmbedderError.initializationFailed("MLX TextEncoder unavailable") }
        if !isVisionLoaded {
            guard FileManager.default.fileExists(atPath: visionModelDir.appendingPathComponent("vision.safetensors").path) else {
                throw EmbedderError.modelNotFound("Missing MLX vision-q8 weights at \(visionModelDir.path)")
            }
            try await encoder.enableVision(directory: visionModelDir)
            isVisionLoaded = true
        }
    }

    public func unloadVisionTower() async {
        if let encoder, isVisionLoaded {
            await encoder.disableVision()
            isVisionLoaded = false
        }
    }

    public func unloadAll() async {
        if let encoder {
            await encoder.disableVision()
        }
        encoder = nil
        TextEncoder.clearMLXCache()
        isTextLoaded = false
        isVisionLoaded = false
    }

    public func currentMemoryBytes() async -> UInt64 {
        if let encoder {
            let stats = await encoder.memory()
            let active = UInt64(max(0, stats["mlx_active_bytes"] ?? 0))
            if active > 0 { return active }
        }
        return ProcessMemory.residentBytes()
    }

    public func embedQuery(_ text: String, dimension: MatryoshkaDimension = .d768) async throws -> [Float] {
        if encoder == nil { try await loadTextTowerOnly() }
        guard let encoder else { throw EmbedderError.initializationFailed("MLX TextEncoder not loaded") }
        let s = CortexSettingsManager.shared.settings
        let formatted = s.embeddingTaskMode.formatQuery(text, isAIMode: s.enableAISynthesis)
        let vectors = try await encoder.encode([formatted], task: .raw, dimensions: dimension.rawValue)
        guard let first = vectors.first else { throw EmbedderError.encodingFailed("Empty query embedding") }
        return first
    }

    public func embedDocuments(_ docs: [(title: String?, body: String)], dimension: MatryoshkaDimension = .d768) async throws -> [[Float]] {
        guard !docs.isEmpty else { return [] }
        if encoder == nil { try await loadTextTowerOnly() }
        guard let encoder else { throw EmbedderError.initializationFailed("MLX TextEncoder not loaded") }
        var allResults: [[Float]] = []
        let batchSize = 8
        for start in stride(from: 0, to: docs.count, by: batchSize) {
            let slice = docs[start..<min(start + batchSize, docs.count)]
            let formatted = slice.map { doc in
                let trimmed = String(doc.body.prefix(6000))
                return EmbeddingTaskMode.formatDocument(title: doc.title, body: trimmed)
            }
            let batchVectors = try await encoder.encode(formatted, task: .raw, dimensions: dimension.rawValue)
            allResults.append(contentsOf: batchVectors)
        }
        return allResults
    }

    public func embedImage(url: URL, softTokens: Int = 280, dimension: MatryoshkaDimension = .d768) async throws -> [Float] {
        try await loadVisionTower()
        guard let encoder else { throw EmbedderError.initializationFailed("MLX TextEncoder not loaded") }
        return try await encoder.encodeImage(url: url, maxSoftTokens: softTokens, dimensions: dimension.rawValue)
    }

    public func embedCGImage(_ image: CGImage, softTokens: Int = 280, dimension: MatryoshkaDimension = .d768) async throws -> [Float] {
        try await loadVisionTower()
        guard let encoder else { throw EmbedderError.initializationFailed("MLX TextEncoder not loaded") }
        return try await encoder.encodeImage(cgImage: image, maxSoftTokens: softTokens, dimensions: dimension.rawValue)
    }
}
