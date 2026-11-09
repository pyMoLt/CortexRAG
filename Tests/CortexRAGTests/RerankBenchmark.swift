import XCTest
@testable import CortexCore
@testable import CortexEmbedders
@testable import CortexIPC

/// Reranker comparison on the real library. Skipped unless `CORTEX_RERANK_BENCH=<dir>` is set; the directory must
/// contain `eval.json` (questions with gold chunk). Run with `CORTEXRAG_HOME` pointing to a copy of the data.
///   A: hybrid search only · B: lexical heuristic · C: bge-reranker-v2-m3 · D: Qwen3-Reranker-0.6B · E: LLM listwise (oMLX)
final class RerankBenchmark: XCTestCase {
    struct EvalItem: Decodable { let q: String; let chunk_id: String; let doc: String; let idx: Int }

    struct Stats {
        var hits1 = 0, hits3 = 0, hits8 = 0, rr = 0.0, n = 0, ms: [Double] = []
        mutating func add(rank: Int?, ms t: Double) {
            n += 1; ms.append(t)
            guard let r = rank else { return }
            if r <= 1 { hits1 += 1 }
            if r <= 3 { hits3 += 1 }
            if r <= 8 { hits8 += 1; rr += 1.0 / Double(r) }
        }
        func line(_ name: String, extraMB: Double?) -> String {
            let sorted = ms.sorted()
            let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            func pct(_ v: Int) -> String { String(format: "%5.1f %%", 100 * Double(v) / Double(max(n, 1))) }
            return String(format: "| %@ | %@ | %@ | %@ | %.3f | %.0f ms | %.0f ms | %@ |",
                          name, pct(hits1), pct(hits3), pct(hits8), rr / Double(max(n, 1)), p50, p95,
                          extraMB.map { String(format: "%.0f MB", $0) } ?? "–")
        }
    }

    func testRerankerComparison() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CORTEX_RERANK_BENCH"] else { throw XCTSkip("benchmark not requested") }
        let items = try JSONDecoder().decode([EvalItem].self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/eval.json")))
        CortexSettingsManager.shared.update { $0.enableReranker = false; $0.defaultEngine = .llamaMetal }
        let service = try CortexService(defaultEngine: .llamaMetal)
        try await service.warmUpTextDaemon()

        func chunkIndex(_ id: String) -> Int { Int(id.split(separator: "_").last ?? "") ?? -999 }
        func rank(_ list: [SearchResultItem], _ gold: EvalItem) -> Int? {
            list.prefix(8).firstIndex { $0.documentID == gold.doc && abs(chunkIndex($0.chunkID) - gold.idx) <= 1 }.map { $0 + 1 }
        }

        // Candidate pools (same for every variant)
        var pools: [[SearchResultItem]] = []
        var stats: [String: Stats] = [:]
        var recallPool = 0
        var tops: [String: [[String]]] = [:]   // variant → per question top-3 chunk IDs (for LLM relevance judging)
        func keepTop(_ key: String, _ list: [SearchResultItem]) { tops[key, default: []].append(list.prefix(3).map(\.chunkID)) }
        for item in items {
            let t0 = Date()
            let resp = try await service.search(query: item.q, scope: ScopeFilter(useUISelection: false), contextChunks: 0,
                                                includeFigures: false, topK: 18, source: "bench")
            let ms = Date().timeIntervalSince(t0) * 1000
            pools.append(resp.results)
            keepTop("A", resp.results)
            stats["A", default: Stats()].add(rank: rank(resp.results, item), ms: ms)
            if resp.results.contains(where: { $0.documentID == item.doc && abs(chunkIndex($0.chunkID) - item.idx) <= 1 }) { recallPool += 1 }
        }

        // B: lexical heuristic
        for (item, pool) in zip(items, pools) {
            let t0 = Date()
            let rr = CortexRerankerService.rerank(query: item.q, candidates: pool, model: .cortexNeuralHybrid, topK: 8, minScore: 0)
            stats["B", default: Stats()].add(rank: rank(rr, item), ms: Date().timeIntervalSince(t0) * 1000)
            keepTop("B", rr)
        }

        // C/D: cross-encoders via llama.cpp
        let models = CortexPaths.appSupport.appendingPathComponent("Models/rerankers")
        var extraMB: [String: Double] = [:]
        for (key, file) in [("C", "bge-reranker-v2-m3-Q8_0.gguf"), ("D", "qwen3-reranker-0.6b-q8_0.gguf")] {
            let url = models.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let before = Double(ProcessMemory.residentBytes()) / 1_048_576
            let reranker = LlamaReranker(modelURL: url)
            let tLoad = Date()
            try await reranker.load()
            let loadMs = Date().timeIntervalSince(tLoad) * 1000
            extraMB[key] = Double(ProcessMemory.residentBytes()) / 1_048_576 - before
            for (item, pool) in zip(items, pools) {
                let t0 = Date()
                let scores = try await reranker.score(query: item.q, documents: pool.map { $0.breadcrumb + "\n" + $0.matchedContent })
                let order = zip(pool, scores).sorted { $0.1 > $1.1 }.map(\.0)
                stats[key, default: Stats()].add(rank: rank(order, item), ms: Date().timeIntervalSince(t0) * 1000)
                keepTop(key, order)
            }
            await reranker.unload()
            print("[\(key)] load \(Int(loadMs)) ms")
        }

        // E: listwise reranking by the local LLM (oMLX)
        let llmModel = ProcessInfo.processInfo.environment["CORTEX_RERANK_LLM"] ?? "Qwen3.5-4B-MLX-4bit"
        for (item, pool) in zip(items, pools) {
            let t0 = Date()
            let order = await llmRerank(query: item.q, pool: pool, model: llmModel)
            stats["E", default: Stats()].add(rank: rank(order, item), ms: Date().timeIntervalSince(t0) * 1000)
            keepTop("E", order)
        }
        try JSONSerialization.data(withJSONObject: tops).write(to: URL(fileURLWithPath: dir + "/tops.json"))

        var report = "Fragen: \(items.count) · Kandidaten-Pool 18 · Gold im Pool: \(recallPool) (\(100 * recallPool / max(items.count, 1)) %)\n\n"
        report += "| Variante | Treffer@1 | @3 | @8 | MRR@8 | Zeit p50 | p95 | Zusatz-RAM |\n|---|---|---|---|---|---|---|---|\n"
        let names = ["A": "A ohne Nachsortierung", "B": "B Wortregel (aktuell)", "C": "C bge-reranker-v2-m3", "D": "D Qwen3-Reranker-0.6B", "E": "E LLM \(llmModel)"]
        for key in ["A", "B", "C", "D", "E"] {
            if let s = stats[key] { report += s.line(names[key]!, extraMB: extraMB[key]) + "\n" }
        }
        try report.write(toFile: dir + "/report.md", atomically: true, encoding: .utf8)
        print(report)
        await service.shutdown()
    }

    private func llmRerank(query: String, pool: [SearchResultItem], model: String) async -> [SearchResultItem] {
        let passages = pool.enumerated().map { "[\($0.offset + 1)] \(CortexTextSanitizer.cleanText($0.element.matchedContent).prefix(350))" }.joined(separator: "\n\n")
        let prompt = "Frage: \(query)\n\nPassagen:\n\(passages)\n\nSortiere die Passagen nach Relevanz für die Frage. Antworte NUR mit den Nummern der 8 relevantesten Passagen, absteigend, kommagetrennt (z. B. 4,1,9)."
        let body: [String: Any] = ["model": model, "messages": [["role": "user", "content": prompt]], "temperature": 0, "max_tokens": 60,
                                   "enable_thinking": false, "chat_template_kwargs": ["thinking": false]]
        var req = URLRequest(url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer admin", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = ((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String else { return pool }
        let answer = CortexLLMService.splitThinkingAndAnswer(content).answer
        var seen = Set<Int>()
        let nums = answer.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init).filter { (1...pool.count).contains($0) && seen.insert($0).inserted }
        return nums.map { pool[$0 - 1] } + pool.enumerated().filter { !seen.contains($0.offset + 1) }.map(\.element)
    }
}
