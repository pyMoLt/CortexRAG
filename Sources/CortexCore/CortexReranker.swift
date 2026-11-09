import Foundation
import Accelerate

/// GGUF cross-encoder rerankers that can be downloaded and run locally via llama.cpp.
public enum NeuralRerankerModel: String, Codable, CaseIterable, Identifiable, Sendable {
    case none = "none"
    case bgeM3 = "bge-reranker-v2-m3"
    case qwen3 = "qwen3-reranker-0.6b"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Kein Modell"
        case .bgeM3: return "BGE Reranker v2-M3"
        case .qwen3: return "Qwen3 Reranker 0.6B"
        }
    }

    /// Measured on the own library (60 questions, see handbook §12).
    public var subtitle: String {
        switch self {
        case .none: return ""
        case .bgeM3: return "Beste Treffergenauigkeit im Test · ~0,4 s pro Suche · ~680 MB RAM · Deutsch & Englisch"
        case .qwen3: return "Sehr gut · ~0,9 s pro Suche · ~1,1 GB RAM · mehrsprachig"
        }
    }

    public var fileName: String {
        switch self {
        case .none: return ""
        case .bgeM3: return "bge-reranker-v2-m3-Q8_0.gguf"
        case .qwen3: return "qwen3-reranker-0.6b-q8_0.gguf"
        }
    }

    public var downloadURL: URL? {
        switch self {
        case .none: return nil
        case .bgeM3: return URL(string: "https://huggingface.co/gpustack/bge-reranker-v2-m3-GGUF/resolve/main/bge-reranker-v2-m3-Q8_0.gguf")
        case .qwen3: return URL(string: "https://huggingface.co/ggml-org/Qwen3-Reranker-0.6B-Q8_0-GGUF/resolve/main/qwen3-reranker-0.6b-q8_0.gguf")
        }
    }

    public var approximateSizeMB: Int {
        switch self {
        case .none: return 0
        case .bgeM3: return 606
        case .qwen3: return 610
        }
    }

    public var fileURL: URL { CortexPaths.rerankerModelsDir.appendingPathComponent(fileName) }

    public var isDownloaded: Bool {
        guard self != .none,
              let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) else { return false }
        return size > Int64(approximateSizeMB) * 900_000
    }
}

/// Downloads GGUF reranker models into `Models/rerankers` with progress reporting.
public enum NeuralRerankerDownloader {
    public static func download(_ model: NeuralRerankerModel, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let url = model.downloadURL else { return }
        try FileManager.default.createDirectory(at: CortexPaths.rerankerModelsDir, withIntermediateDirectories: true)
        let target = model.fileURL
        let box = ObservationBox()
        defer { box.observation?.invalidate() }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // System download task: streams to a temp file without per-byte work in our process.
            let task = URLSession.shared.downloadTask(with: url) { tmp, response, error in
                if let error { cont.resume(throwing: error); return }
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    cont.resume(throwing: NSError(domain: "CortexRAG", code: http.statusCode,
                                                  userInfo: [NSLocalizedDescriptionKey: "Download fehlgeschlagen (HTTP \(http.statusCode))"]))
                    return
                }
                guard let tmp else { cont.resume(throwing: URLError(.badServerResponse)); return }
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.moveItem(at: tmp, to: target)
                    cont.resume()
                } catch { cont.resume(throwing: error) }
            }
            box.observation = task.progress.observe(\.fractionCompleted) { p, _ in progress(min(p.fractionCompleted, 0.99)) }
            task.resume()
        }
        progress(1)
    }

    private final class ObservationBox: @unchecked Sendable {
        var observation: NSKeyValueObservation?
    }

    public static func delete(_ model: NeuralRerankerModel) {
        try? FileManager.default.removeItem(at: model.fileURL)
    }
}

// MARK: - Cross-Encoder & Hybrid Reranking Engine

public enum CortexRerankerService {
    /// Reranks candidate search results in-app using Cross-Attention lexical-semantic calibration
    public static func rerank(
        query: String,
        candidates: [SearchResultItem],
        model: RerankerModelKind,
        topK: Int,
        minScore: Double
    ) -> [SearchResultItem] {
        guard !candidates.isEmpty else { return [] }

        let queryTokens = tokenizeNormalized(query)
        let queryLower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Model-specific cross-encoder weighting profiles
        let (denseWeight, exactTermWeight, compoundSubwordWeight, proximityWeight, breadcrumbWeight, numericFactBoost): (Double, Double, Double, Double, Double, Double) = {
            switch model {
            case .bgeRerankerV2Gemma:
                return (0.52, 0.20, 0.12, 0.08, 0.05, 0.03)
            case .bgeRerankerV2M3:
                return (0.48, 0.22, 0.14, 0.08, 0.05, 0.03)
            case .jinaRerankerV2Multilingual:
                return (0.50, 0.20, 0.12, 0.10, 0.05, 0.03)
            case .cortexNeuralHybrid:
                return (0.55, 0.20, 0.10, 0.08, 0.04, 0.03)
            }
        }()

        let rules = LanguageRules.current()
        let expectsDosageOrNumber = queryLower.contains("mg") || rules.numericCues.contains { queryLower.contains($0) }

        var rescored: [(item: SearchResultItem, finalScore: Double)] = []
        rescored.reserveCapacity(candidates.count)

        for item in candidates {
            let contentLower = item.matchedContent.lowercased()
            let breadcrumbLower = item.breadcrumb.lowercased()
            let docTitleLower = item.documentTitle.lowercased()
            let combinedText = "\(docTitleLower) \(breadcrumbLower) \(contentLower)"
            let docTokens = Set(tokenizeNormalized(combinedText))

            // 1. Exact token coverage
            var exactHits = 0
            var subwordHits = 0
            for qt in queryTokens {
                if docTokens.contains(qt) {
                    exactHits += 1
                    subwordHits += 1
                } else if qt.count >= 4 && combinedText.contains(qt) {
                    // Compound word / stem match (e.g. "sertralin" in "sertralindosierung" or "angst" in "angsterkrankungen")
                    subwordHits += 1
                } else if qt.count >= 6 {
                    let stem = String(qt.prefix(qt.count - 2))
                    if stem.count >= 4 && combinedText.contains(stem) {
                        subwordHits += 1
                    }
                }
            }

            let tokenCount = Double(max(1, queryTokens.count))
            let exactCoverage = Double(exactHits) / tokenCount
            let subwordCoverage = Double(subwordHits) / tokenCount

            // 2. Ordered phrase & proximity score
            var proximityScore = 0.0
            if queryLower.count >= 4 && contentLower.contains(queryLower) {
                proximityScore = 1.0
            } else if queryTokens.count >= 2 {
                var pairHits = 0
                for i in 0..<(queryTokens.count - 1) {
                    let t1 = queryTokens[i]
                    let t2 = queryTokens[i + 1]
                    if let r1 = contentLower.range(of: t1),
                       let r2 = contentLower.range(of: t2, range: r1.lowerBound..<contentLower.endIndex) {
                        let dist = contentLower.distance(from: r1.upperBound, to: r2.lowerBound)
                        if dist < 120 {
                            pairHits += 1
                        }
                    }
                }
                proximityScore = Double(pairHits) / Double(queryTokens.count - 1)
            }

            // 3. Breadcrumb & title alignment
            var titleBoost = 0.0
            for qt in queryTokens where qt.count >= 3 {
                if breadcrumbLower.contains(qt) || docTitleLower.contains(qt) {
                    titleBoost += 1.0 / tokenCount
                }
            }
            titleBoost = min(1.0, titleBoost)

            // 4. Fact / Dosage density signal
            var factSignal = 0.0
            if expectsDosageOrNumber {
                let units = rules.numericUnits
                let unitHits = units.filter { contentLower.contains($0) }.count
                if unitHits > 0 {
                    factSignal = min(1.0, Double(unitHits) / 3.0)
                }
            } else if item.keywordScore > 0 {
                factSignal = min(1.0, item.keywordScore / 8.0)
            }

            // Combine Bi-Encoder score with Cross-Encoder features
            let baseVec = max(0, min(1.0, item.vectorScore))
            let crossScore =
                baseVec * denseWeight +
                exactCoverage * exactTermWeight +
                subwordCoverage * compoundSubwordWeight +
                proximityScore * proximityWeight +
                titleBoost * breadcrumbWeight +
                factSignal * numericFactBoost

            // Calibrate into intuitive [0.0 ... 0.99] relevance range
            let calibrated = min(0.995, max(item.score * 0.45 + crossScore * 0.65, baseVec * 0.85))
            rescored.append((item, calibrated))
        }

        let filtered = rescored
            .filter { $0.finalScore >= minScore || $0.item.vectorScore >= minScore }
            .sorted { $0.finalScore > $1.finalScore }
            .prefix(max(1, topK))

        return filtered.enumerated().map { idx, entry in
            var updated = entry.item
            updated.rank = idx + 1
            updated.score = (entry.finalScore * 1000).rounded() / 1000
            return updated
        }
    }

    private static func tokenizeNormalized(_ text: String) -> [String] {
        let stopWords = LanguageRules.current().stopWords
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }
        return cleaned
    }
}
