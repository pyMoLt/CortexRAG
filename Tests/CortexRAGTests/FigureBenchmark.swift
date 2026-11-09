import XCTest
@testable import CortexCore
@testable import CortexEmbedders
import SQLite3

/// How should image-heavy slides be represented? Questions about the visual content of a page are matched against:
///   A single crops (image vector of each cropped figure, best per page)
///   B whole page (one image vector of the rendered page)
///   C captions (caption/OCR text vector of the crops)
///   D text (best text chunk of the page, hybrid search)
///   E fusion D + B by rank (what a mixed text/image search would deliver)
/// Skipped unless `CORTEX_FIG_BENCH=<dir>` (with `eval.json`) is set;
/// run with `CORTEXRAG_HOME` pointing to an indexed library.
final class FigureBenchmark: XCTestCase {
    struct Item: Decodable { let q: String; let doc: String; let page: Int; let nfig: Int }
    struct PageKey: Hashable { let doc: String; let page: Int }

    func testSlideRepresentations() async throws {
        guard let dir = ProcessInfo.processInfo.environment["CORTEX_FIG_BENCH"] else { throw XCTSkip("benchmark not requested") }
        let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/eval.json")))
        let db = try CortexDatabase(path: CortexPaths.databaseURL.path)
        let engine = LlamaCppMetalBackend()

        // Figures per page (visual + caption vectors) and the rendered page images.
        var crops: [PageKey: [(vis: Data, cap: Data)]] = [:]
        var pageImages: [PageKey: String] = [:]
        // Duplicate documents (same PDF twice, e.g. "main.pdf") would compete with the target page; leave them out.
        let excluded = Set((try db.listDocuments()).filter { $0.title == ProcessInfo.processInfo.environment["CORTEX_FIG_EXCLUDE"] }.map(\.id))
        try db.query("SELECT document_id, page_number, visual_embedding, caption_embedding, full_page_image_path FROM figures") { st in
            let key = PageKey(doc: String(cString: sqlite3_column_text(st, 0)), page: Int(sqlite3_column_int(st, 1)))
            func blob(_ c: Int32) -> Data {
                guard let p = sqlite3_column_blob(st, c) else { return Data() }
                return Data(bytes: p, count: Int(sqlite3_column_bytes(st, c)))
            }
            guard !excluded.contains(key.doc) else { return }
            crops[key, default: []].append((blob(2), blob(3)))
            pageImages[key] = String(cString: sqlite3_column_text(st, 4))
        }
        let pages = Array(crops.keys)
        print("Seiten mit Abbildungen: \(pages.count), Fragen: \(items.count)")

        // B: one image vector per page.
        try await engine.loadVisionTower()
        var pageVectors: [PageKey: [Float]] = [:]
        let t0 = Date()
        for key in pages {
            if let path = pageImages[key], let v = try? await engine.embedImage(url: URL(fileURLWithPath: path)) { pageVectors[key] = v }
        }
        let perPage = Date().timeIntervalSince(t0) * 1000 / Double(max(pages.count, 1))
        await engine.unloadVisionTower()
        try await engine.loadTextTowerOnly()

        // Also load captions & context per page for reranker comparison
        var pageTexts: [PageKey: String] = [:]
        try db.query("SELECT document_id, page_number, caption_text, surrounding_context FROM figures") { st in
            let key = PageKey(doc: String(cString: sqlite3_column_text(st, 0)), page: Int(sqlite3_column_int(st, 1)))
            guard !excluded.contains(key.doc) else { return }
            let cap = sqlite3_column_text(st, 2).map { String(cString: $0) } ?? ""
            let ctx = sqlite3_column_text(st, 3).map { String(cString: $0) } ?? ""
            let combined = (cap + " " + ctx).trimmingCharacters(in: .whitespacesAndNewlines)
            if !combined.isEmpty {
                let prev = pageTexts[key] ?? ""
                if combined.count > prev.count { pageTexts[key] = combined }
            }
        }

        var ranks: [String: [Int?]] = [:]
        var targetPageScores: [Double] = []
        var nonTargetTopScores: [Double] = []

        func rank(_ scores: [PageKey: Double], _ target: PageKey) -> Int? {
            let sorted = scores.sorted { $0.value > $1.value }.map(\.key)
            return sorted.firstIndex(of: target).map { $0 + 1 }
        }
        for item in items {
            let target = PageKey(doc: item.doc, page: item.page)
            let q = try await engine.embedQuery(item.q)
            var a: [PageKey: Double] = [:], b: [PageKey: Double] = [:], c: [PageKey: Double] = [:]
            for key in pages {
                a[key] = crops[key]!.map { Double(VectorMath.dotProduct(q, $0.vis)) }.max() ?? 0
                c[key] = crops[key]!.map { Double(VectorMath.dotProduct(q, $0.cap)) }.max() ?? 0
                if let v = pageVectors[key] { b[key] = Double(zip(q, v).reduce(Float(0)) { $0 + $1.0 * $1.1 }) }
            }
            if let ts = b[target] { targetPageScores.append(ts) }
            if let nts = b.filter({ $0.key != target }).map(\.value).max() { nonTargetTopScores.append(nts) }

            ranks["A Einzelausschnitte", default: []].append(rank(a, target))
            ranks["B ganze Seite", default: []].append(rank(b, target))
            ranks["C Bildunterschrift", default: []].append(rank(c, target))
            var g: [PageKey: Double] = [:]
            for key in pages { g[key] = max(a[key] ?? 0, b[key] ?? 0) }
            ranks["G max(Ausschnitt, ganze Seite)", default: []].append(rank(g, target))
            var gc: [PageKey: Double] = [:]
            for key in pages { gc[key] = max(g[key] ?? 0, (c[key] ?? 0) * 0.95) }
            ranks["H max(G, Bildunterschrift)", default: []].append(rank(gc, target))

            let text = try db.hybridSearch(queryText: item.q, queryVector: q, scope: ScopeFilter(), contextChunks: 0,
                                           includeFigures: false, topK: 30, lexicalRerank: false)
            var seen: [PageKey] = []
            for t in text where !excluded.contains(t.documentID) && !seen.contains(PageKey(doc: t.documentID, page: t.pageNumber)) { seen.append(PageKey(doc: t.documentID, page: t.pageNumber)) }
            ranks["D Text", default: []].append(seen.firstIndex(of: target).map { $0 + 1 })

            var fused: [PageKey: Double] = [:]
            for (i, k) in seen.enumerated() { fused[k, default: 0] += 1 / (60 + Double(i + 1)) }
            let topBPages = b.sorted(by: { $0.value > $1.value }).prefix(30).map(\.key)
            for (i, k) in topBPages.enumerated() { fused[k, default: 0] += 1 / (60 + Double(i + 1)) }
            ranks["E Text + ganze Seite (RRF)", default: []].append(rank(fused, target))

            var fusedA: [PageKey: Double] = [:]
            for (i, k) in seen.enumerated() { fusedA[k, default: 0] += 1 / (60 + Double(i + 1)) }
            for (i, k) in a.sorted(by: { $0.value > $1.value }).prefix(30).map(\.key).enumerated() { fusedA[k, default: 0] += 1 / (60 + Double(i + 1)) }
            ranks["F Text + Ausschnitte (RRF)", default: []].append(rank(fusedA, target))

            // I: Compare text-reranking on B (whole-page image hits using their caption+context) vs pure RRF/visual rank
            let bCandidates: [SearchResultItem] = topBPages.enumerated().map { idx, pk in
                SearchResultItem(
                    rank: idx + 1, score: b[pk] ?? 0, vectorScore: b[pk] ?? 0, keywordScore: 0,
                    chunkID: "fig:\(pk.doc):\(pk.page)", documentID: pk.doc, documentTitle: pk.doc,
                    documentPath: "", collectionID: "", collectionName: "", moduleID: "", moduleName: "",
                    pageNumber: pk.page, breadcrumb: "", contextBefore: "",
                    matchedContent: pageTexts[pk] ?? "", contextAfter: "", fullPageImagePath: "", figuresOnPage: []
                )
            }
            let rerankedB = CortexRerankerService.rerank(query: item.q, candidates: bCandidates, model: .bgeRerankerV2M3, topK: 30, minScore: 0.0)
            let rerankedKeys = rerankedB.map { PageKey(doc: $0.documentID, page: $0.pageNumber) }
            ranks["I Ganze Seite + Text-Reranker", default: []].append(rerankedKeys.firstIndex(of: target).map { $0 + 1 })
        }

        let sortedTarget = targetPageScores.sorted()
        let p10Target = sortedTarget.isEmpty ? 0 : sortedTarget[max(0, sortedTarget.count / 10)]
        let medianTarget = sortedTarget.isEmpty ? 0 : sortedTarget[sortedTarget.count / 2]
        let meanTarget = targetPageScores.isEmpty ? 0 : targetPageScores.reduce(0, +) / Double(targetPageScores.count)

        var report = "Fragen: \(items.count) · Seiten mit Abbildungen: \(pages.count) · Ganzseiten-Vektor: \(Int(perPage)) ms/Seite\n"
        report += String(format: "Zielseiten-Score (ganze Seite): Mittel %.3f · Median %.3f · P10 %.3f · Min %.3f · Max %.3f\n\n",
                         meanTarget, medianTarget, p10Target, sortedTarget.first ?? 0, sortedTarget.last ?? 0)
        report += "| Variante | Treffer@1 | @5 | @10 | MRR@10 |\n|---|---|---|---|---|\n"
        for (name, r) in ranks.sorted(by: { $0.key < $1.key }) {
            func at(_ k: Int) -> String { String(format: "%.0f %%", 100 * Double(r.filter { ($0 ?? 999) <= k }.count) / Double(r.count)) }
            let mrr = r.map { ($0 ?? 999) <= 10 ? 1 / Double($0!) : 0 }.reduce(0, +) / Double(r.count)
            report += "| \(name) | \(at(1)) | \(at(5)) | \(at(10)) | \(String(format: "%.3f", mrr)) |\n"
        }
        try report.write(toFile: dir + "/report.md", atomically: true, encoding: .utf8)
        print(report)
        await engine.unloadAll()
    }
}
