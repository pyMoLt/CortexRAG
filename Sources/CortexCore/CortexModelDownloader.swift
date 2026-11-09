import Foundation

public enum EmbeddingGemmaStatus: Equatable, Sendable {
    case ready(textPath: String, mmprojPath: String)
    case missing(missingText: Bool, missingVision: Bool)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public enum CortexModelDownloader {
    public static let textModelFileName = "embeddinggemma-2-Q8_0.gguf"
    public static let mmprojModelFileName = "mmproj-embeddinggemma-2-Q8_0.gguf"

    public static let textModelURL = URL(string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/embeddinggemma-2-Q8_0.gguf")!
    public static let mmprojModelURL = URL(string: "https://huggingface.co/ggml-org/embeddinggemma-2-GGUF/resolve/main/mmproj-embeddinggemma-2-Q8_0.gguf")!

    public static var localTextModelURL: URL {
        CortexPaths.llamaModelsDir.appendingPathComponent(textModelFileName)
    }

    public static var localMMProjModelURL: URL {
        CortexPaths.llamaModelsDir.appendingPathComponent(mmprojModelFileName)
    }

    /// Checks whether the required embedding model weights exist in CortexRAG or in the DigUp fallback directory.
    public static func checkEmbeddingGemmaStatus() -> EmbeddingGemmaStatus {
        let fm = FileManager.default

        // 1. Check primary CortexRAG directory
        let cortexTextExists = fm.fileExists(atPath: localTextModelURL.path)
        let cortexVisionExists = fm.fileExists(atPath: localMMProjModelURL.path)

        if cortexTextExists && cortexVisionExists {
            return .ready(textPath: localTextModelURL.path, mmprojPath: localMMProjModelURL.path)
        }

        // 2. Check fallback DigUp directory
        let digupDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DigUp/Models")
        let digupText = digupDir.appendingPathComponent(textModelFileName)
        let digupVision = digupDir.appendingPathComponent(mmprojModelFileName)

        let textFinal = cortexTextExists ? localTextModelURL.path : (fm.fileExists(atPath: digupText.path) ? digupText.path : nil)
        let visionFinal = cortexVisionExists ? localMMProjModelURL.path : (fm.fileExists(atPath: digupVision.path) ? digupVision.path : nil)

        if let textFinal, let visionFinal {
            return .ready(textPath: textFinal, mmprojPath: visionFinal)
        }

        return .missing(missingText: textFinal == nil, missingVision: visionFinal == nil)
    }

    /// Downloads the EmbeddingGemma model files directly into CortexPaths.llamaModelsDir with progress reporting.
    public static func downloadEmbeddingGemma(
        progress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        try CortexPaths.ensureDirectories()
        let fm = FileManager.default

        let status = checkEmbeddingGemmaStatus()
        let needText: Bool
        let needVision: Bool

        switch status {
        case .ready:
            progress(1.0, "Modelle bereits vorhanden")
            return
        case .missing(let missingText, let missingVision):
            needText = missingText
            needVision = missingVision
        }

        if needText {
            progress(0.05, "Lade EmbeddingGemma-2 Textmodell herunter (~310 MB)...")
            try await downloadSingleFile(
                url: textModelURL,
                destination: localTextModelURL,
                progressWeight: needVision ? 0.40 : 1.0,
                progressOffset: 0.0,
                statusPrefix: "Textmodell",
                onProgress: progress
            )
        }

        if needVision {
            let offset = needText ? 0.40 : 0.0
            let weight = needText ? 0.60 : 1.0
            progress(offset + 0.02, "Lade EmbeddingGemma-2 Bild-Projektor herunter (~555 MB)...")
            try await downloadSingleFile(
                url: mmprojModelURL,
                destination: localMMProjModelURL,
                progressWeight: weight,
                progressOffset: offset,
                statusPrefix: "Bild-Projektor",
                onProgress: progress
            )
        }

        progress(1.0, "EmbeddingGemma 2 vollständig installiert!")
    }

    private static func downloadSingleFile(
        url: URL,
        destination: URL,
        progressWeight: Double,
        progressOffset: Double,
        statusPrefix: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws {
        let box = ObservationBox()
        defer { box.observation?.invalidate() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    cont.resume(throwing: NSError(
                        domain: "CortexRAG",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "\(statusPrefix): Download fehlgeschlagen (HTTP \(http.statusCode))"]
                    ))
                    return
                }
                guard let tmp else {
                    cont.resume(throwing: URLError(.badServerResponse))
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tmp, to: destination)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }

            box.observation = task.progress.observe(\.fractionCompleted) { p, _ in
                let frac = min(p.fractionCompleted, 0.99)
                let totalFrac = progressOffset + (frac * progressWeight)
                let mbReceived = Double(p.completedUnitCount) / (1024 * 1024)
                let mbTotal = Double(p.totalUnitCount) / (1024 * 1024)
                let detail = mbTotal > 0
                    ? String(format: "%@: %.1f / %.1f MB (%.0f%%)", statusPrefix, mbReceived, mbTotal, frac * 100)
                    : String(format: "%@: %.1f MB", statusPrefix, mbReceived)
                onProgress(totalFrac, detail)
            }
            task.resume()
        }
    }

    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
    }
}
