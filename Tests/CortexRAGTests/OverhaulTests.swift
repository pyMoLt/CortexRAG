import XCTest
import PDFKit
import AppKit
@testable import CortexCore
@testable import CortexRAGApp
@testable import CortexVision

final class OverhaulTests: XCTestCase {
    private func makeDB() throws -> (CortexDatabase, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cortex_overhaul_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        try db.seedExampleLibrary()
        return (db, dir)
    }

    private func chunk(_ id: String, doc: String, _ text: String, _ vec: [Float]) -> DocumentChunk {
        DocumentChunk(id: id, documentID: doc, pageNumber: 1, chunkIndex: 0, prevChunkID: nil, nextChunkID: nil,
                      breadcrumb: "B", content: text, embedding: vec)
    }

    /// Checkbox selection across levels must be a union (collection A + single PDF of collection B).
    func testMultiLevelSelectionIsUnion() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        var v = [Float](repeating: 0, count: 768); v[0] = 1
        let sysDoc = LibraryDocument(id: "doc_s", collectionID: "col_systems", title: "Systems", filePath: "/tmp/s.pdf", pageCount: 1)
        let dbDoc = LibraryDocument(id: "doc_d", collectionID: "col_databases", title: "Databases", filePath: "/tmp/d.pdf", pageCount: 1)
        try db.saveDocumentIndex(document: sysDoc, chunks: [chunk("cs", doc: "doc_s", "Consensus Verteilte Systeme", v)], figures: [])
        try db.saveDocumentIndex(document: dbDoc, chunks: [chunk("cd", doc: "doc_d", "Consensus Datenbanksysteme", v)], figures: [])

        let union = ScopeFilter(collectionIDs: ["col_databases"], documentIDs: ["doc_s"], matchAnyLevel: true)
        let hits = try db.hybridSearch(queryText: "Consensus", queryVector: v, scope: union, contextChunks: 0, includeFigures: false, topK: 10)
        XCTAssertEqual(Set(hits.map(\.documentID)), ["doc_s", "doc_d"])

        let intersection = ScopeFilter(collectionIDs: ["col_databases"], documentIDs: ["doc_s"])
        let none = try db.hybridSearch(queryText: "Consensus", queryVector: v, scope: intersection, contextChunks: 0, includeFigures: false, topK: 10)
        XCTAssertTrue(none.isEmpty, "Agent filters keep AND semantics")
    }

    /// Keyword hits inside a narrow scope must not be cut off by matches elsewhere.
    func testKeywordScoreSurvivesNarrowScope() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        var v = [Float](repeating: 0, count: 768); v[0] = 1
        // Filler documents keep the term rare enough for a positive BM25 IDF.
        for i in 0..<200 {
            let d = LibraryDocument(id: "fill\(i)", collectionID: "col_ml", title: "Fill \(i)", filePath: "/tmp/fill\(i).pdf", pageCount: 1)
            try db.saveDocumentIndex(document: d, chunks: [chunk("fc\(i)", doc: d.id, "Vektordatenbank Einbettung Suche", v)], figures: [])
        }
        for i in 0..<60 {
            let d = LibraryDocument(id: "noise\(i)", collectionID: "col_ml", title: "Noise \(i)", filePath: "/tmp/noise\(i).pdf", pageCount: 1)
            try db.saveDocumentIndex(document: d, chunks: [chunk("nc\(i)", doc: d.id, "Paxos Paxos Paxos Quorum", v)], figures: [])
        }
        let target = LibraryDocument(id: "target", collectionID: "col_systems", title: "Target", filePath: "/tmp/target.pdf", pageCount: 1)
        try db.saveDocumentIndex(document: target, chunks: [chunk("tc", doc: "target", "Unter Paxos Konsensprotokoll", v)], figures: [])
        let hits = try db.hybridSearch(queryText: "Paxos", queryVector: v, scope: ScopeFilter(documentIDs: ["target"]), contextChunks: 0, includeFigures: false, topK: 3)
        XCTAssertEqual(hits.first?.chunkID, "tc")
        XCTAssertGreaterThan(hits.first?.keywordScore ?? 0, 0)
    }

    /// Overlapping neighbour chunks must not appear as separate hits; their text moves into the context.
    func testAdjacentChunksAreMerged() throws {
        let (db, dir) = try makeDB()
        defer { try? FileManager.default.removeItem(at: dir) }
        var v = [Float](repeating: 0, count: 768); v[0] = 1
        let doc = LibraryDocument(id: "d", collectionID: "col_systems", title: "Doc", filePath: "/tmp/d.pdf", pageCount: 3)
        let texts = ["Raft Leader Election Term", "Raft Log Replication Quorum", "Raft Safety Commit Index", "Ganz anderes Thema Routing"]
        let chunks = texts.enumerated().map { i, t in
            DocumentChunk(id: "c\(i)", documentID: "d", pageNumber: i + 1, chunkIndex: i, prevChunkID: nil, nextChunkID: nil,
                          breadcrumb: "B", content: t, embedding: v)
        }
        let other = LibraryDocument(id: "o", collectionID: "col_systems", title: "Other", filePath: "/tmp/o.pdf", pageCount: 1)
        try db.saveDocumentIndex(document: doc, chunks: chunks, figures: [])
        try db.saveDocumentIndex(document: other, chunks: [chunk("x", doc: "o", "Raft Cluster Membership", v)], figures: [])
        let hits = try db.hybridSearch(queryText: "Raft", queryVector: v, contextChunks: 0, includeFigures: false, topK: 5)
        let fromDoc = hits.filter { $0.documentID == "d" }
        let indices = fromDoc.compactMap { Int($0.chunkID.dropFirst()) }.sorted()
        for (a, b) in zip(indices, indices.dropFirst()) { XCTAssertGreaterThan(b - a, 1, "neighbours must be merged") }
        XCTAssertTrue(hits.contains { $0.documentID == "o" })
        XCTAssertTrue(fromDoc.contains { ($0.mergedNeighborCount ?? 0) > 0 && !($0.contextBefore + $0.contextAfter).isEmpty })
    }

    func testFollowUpStrategyRules() {
        typealias VM = AppViewModel
        XCTAssertEqual(VM.classifyFollowUp("Fasse das bitte kürzer zusammen", hasNewTerms: false, mode: .auto), .noSearch)
        XCTAssertEqual(VM.classifyFollowUp("und bei Netzwerkpartitionen?", hasNewTerms: true, mode: .auto), .appended)
        XCTAssertEqual(VM.classifyFollowUp("Replikation?", hasNewTerms: true, mode: .auto), .appended)
        XCTAssertEqual(VM.classifyFollowUp("Welche Rolle spielt das Quorum bei der Leader-Wahl in verteilten Konsensprotokollen?",
                                           hasNewTerms: true, mode: .auto), .standalone)
        XCTAssertEqual(VM.classifyFollowUp("Mach eine Tabelle", hasNewTerms: false, mode: .always), .appended)
        XCTAssertEqual(VM.classifyFollowUp("und bei Knotenausfall?", hasNewTerms: true, mode: .never), .noSearch)
    }

    func testUnknownTermsDetectCompounds() {
        let corpus = "bei normalem netzwerkbetrieb wird die replikation synchronisiert. knoten und cluster"
        XCTAssertEqual(AppViewModel.unknownTerms(["netzwerkpartition"], in: corpus), ["netzwerkpartition"])
        XCTAssertEqual(AppViewModel.unknownTerms(["knoten", "clustern"], in: corpus), [])
    }

    func testServerProfileMigrationAndMirroring() throws {
        let old = #"{"llmEndpointURL":"https://remote-host.local:8072/v1","llmApiKey":"k","llmSelectedModel":"Qwen-big"}"#
        var s = try JSONDecoder().decode(CortexSettings.self, from: Data(old.utf8))
        XCTAssertEqual(s.llmProfiles.map(\.name), ["Lokal", "Remote"])
        XCTAssertEqual(s.activeLLMProfile?.endpointURL, "https://remote-host.local:8072/v1")
        XCTAssertEqual(s.fallbackLLMProfile?.id, "local")
        s.activeLLMProfileID = "local"
        s.applyActiveProfile()
        XCTAssertEqual(s.llmEndpointURL, "http://127.0.0.1:8000/v1")
        s.llmSelectedModel = "Qwen-small"
        s.storeFieldsIntoActiveProfile()
        XCTAssertEqual(s.activeLLMProfile?.model, "Qwen-small")
        XCTAssertNil(s.fallbackLLMProfile, "fallback equal to active is ignored")
        let fresh = CortexSettings()
        XCTAssertEqual(fresh.llmProfiles.count, 2)
        XCTAssertEqual(fresh.llmProfiles.map(\.id), ["local", "remote"])
        XCTAssertEqual(fresh.llmProfiles.first(where: { $0.id == "remote" })?.endpointURL, "http://remote-host.local:8072/v1")
        XCTAssertEqual(fresh.activeLLMProfileID, "local")
    }

    func testPreferredChatModelSkipsNonChatModels() {
        let ids = ["OmniVoice-bf16", "Qwen3-Embedding-4B-MLX-8bit", "Qwen3-Reranker-0.6B-8bit-mlx", "Qwen3-TTS-12Hz-1.7B-VoiceDesign-8bit",
                   "Qwen3.5-4B-MLX-4bit", "Qwen3.6-35B-A3B-oQ6e-fp16-mtp", "chatterbox-8bit", "mlx-community--S3TokenizerV2"]
        let models = ids.map { DiscoveredLLMModel(id: $0) }
        XCTAssertEqual(DiscoveredLLMModel.preferredChatModel(in: models)?.id, "Qwen3.6-35B-A3B-oQ6e-fp16-mtp")
        var loaded = models
        loaded[4].isLoaded = true
        XCTAssertEqual(DiscoveredLLMModel.preferredChatModel(in: loaded)?.id, "Qwen3.5-4B-MLX-4bit")
    }

    func testLanguageRules() {
        XCTAssertEqual(LanguageRules.detectLanguage("How does leader election work in distributed consensus?"), .english)
        XCTAssertEqual(LanguageRules.detectLanguage("Wie funktioniert die Leader-Wahl in verteilten Systemen?"), .german)
        XCTAssertNil(LanguageRules.detectLanguage("Consensus"))
        XCTAssertTrue(ChunkDisplayCleaner.isDateLike("10/17/2025"))
        XCTAssertTrue(ChunkDisplayCleaner.isDateLike("Oct 17, 2025"))
        XCTAssertTrue(ChunkDisplayCleaner.isDateLike("17. Oktober 2025"))
        XCTAssertFalse(ChunkDisplayCleaner.isDateLike("Stufe 3 von 2025"))
        XCTAssertFalse(ChunkDisplayCleaner.isDateLike("Version 2025"))
        XCTAssertTrue(ChunkDisplayCleaner.isDateLike("März 2026"))
        let en = LanguageRules.english
        XCTAssertEqual(AppViewModel.classifyFollowUp("and during partitions?", hasNewTerms: true, mode: .auto, rules: en), .appended)
        XCTAssertEqual(AppViewModel.classifyFollowUp("Which role does quorum intersection play in fault-tolerant state machines?",
                                                     hasNewTerms: true, mode: .auto, rules: en), .standalone)
        XCTAssertTrue(LanguageRules.for(.mixed).followUpInstructionWords.contains("summarize"))
        XCTAssertTrue(LanguageRules.for(.mixed).followUpInstructionWords.contains("zusammenfassen"))
    }

    func testFigureFilters() {
        XCTAssertFalse(FigureFilter.isPlausibleStandalone(NormalizedRect(x: 0, y: 0, width: 1, height: 0.08)), "banner")
        XCTAssertFalse(FigureFilter.isPlausibleStandalone(NormalizedRect(x: 0, y: 0, width: 0.98, height: 0.95)), "background")
        XCTAssertTrue(FigureFilter.isPlausibleStandalone(NormalizedRect(x: 0.2, y: 0.3, width: 0.5, height: 0.4)))
        // bullet list: one column of lines covering the box
        let box = NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.3)
        let bullets = (0..<6).map { NormalizedRect(x: 0.12, y: 0.21 + Double($0) * 0.045, width: 0.5, height: 0.035) }
        XCTAssertTrue(FigureFilter.isPlainTextBlock(box, lines: bullets))
        // table: three columns
        let table = (0..<6).flatMap { r in [0.12, 0.32, 0.52].map { NormalizedRect(x: $0, y: 0.21 + Double(r) * 0.045, width: 0.15, height: 0.035) } }
        XCTAssertFalse(FigureFilter.isPlainTextBlock(box, lines: table))
        // repeated logo on 3 pages
        XCTAssertEqual(FigureFilter.repeatedHashes([(0xF0F0, 1), (0xF0F1, 2), (0xF0F0, 5), (0x1234_5678_9ABC, 3)]), [0xF0F0])
    }

    func testMojibakeTitleRepair() {
        XCTAssertEqual(CortexTextSanitizer.repairEncoding("VL_NebenlÃ¤ufigkeit"), "VL_Nebenläufigkeit")
        XCTAssertEqual(CortexTextSanitizer.repairEncoding("Abschlu\u{00C3}\u{009F}vorlesung"), "Abschlußvorlesung")
        // NFD input as delivered by APFS
        XCTAssertEqual(CortexTextSanitizer.repairEncoding("Einfu\u{00CC}\u{0088}hrung".decomposedStringWithCanonicalMapping), "Einführung")
        XCTAssertEqual(CortexTextSanitizer.repairEncoding("Größe ändern"), "Größe ändern", "Correct text stays untouched")
        XCTAssertEqual(CortexTextSanitizer.displayTitle("VL_VerteilteSysteme_2025"), "VL VerteilteSysteme 2025")
    }

    func testThinkParserHandlesMissingOpenTag() {
        let parsed = CortexLLMService.splitThinkingAndAnswer("Ich prüfe [1].\n</think>\n\nAntwort **fett** [1].")
        XCTAssertEqual(parsed.thinking, "Ich prüfe [1].")
        XCTAssertEqual(parsed.answer, "Antwort **fett** [1].")
    }

    func testMarkdownBlocksAndCitations() {
        let md = """
        ### Architektur
        Einleitung mit Quelle [1, 2].

        - Punkt A [3]
          - Unterpunkt
        1. Erstens

        | Protokoll | Latenz |
        |---|---|
        | Raft | 1,2–2,4 ms |
        """
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks.first, .heading(3, "Architektur"))
        XCTAssertTrue(blocks.contains(.listItem(ordered: false, marker: "•", indent: 1, content: "Unterpunkt")))
        XCTAssertTrue(blocks.contains(.listItem(ordered: true, marker: "1.", indent: 0, content: "Erstens")))
        XCTAssertTrue(blocks.contains(.table(header: ["Protokoll", "Latenz"], rows: [["Raft", "1,2–2,4 ms"]])))
        let linked = MarkdownParser.linkCitations("Siehe [1, 2] und [3-4], aber nicht [Link](x)")
        XCTAssertTrue(linked.contains("[1](cortex-cite://1)"))
        XCTAssertTrue(linked.contains("[2](cortex-cite://2)"))
        XCTAssertTrue(linked.contains("[4](cortex-cite://4)"))
        XCTAssertTrue(linked.contains("[Link](x)"))
        let cell = String(MarkdownParser.inlineAttributed("A<br>B<br/>C", citationTint: .blue).characters)
        XCTAssertEqual(cell, "A\nB\nC")
    }

    /// The reader must locate a chunk inside the page text despite different line breaks.
    @MainActor
    func testReaderFindsChunkOnPage() throws {
        let pageText = "Kapitel 3 Replikation\nKonsensbildung durch\nLeader-Wahl erfordert ein Quorum\nbei Clustern ab 3 Knoten. Weitere Schritte folgen."
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return XCTFail("no ctx") }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (pageText as NSString).draw(in: CGRect(x: 40, y: 400, width: 500, height: 400),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
        NSGraphicsContext.current = nil
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: pdfData as Data), let page = doc.page(at: 0) else { return XCTFail("no pdf") }

        let chunk = "Konsensbildung durch Leader-Wahl erfordert ein Quorum bei Clustern ab 3 Knoten."
        let sel = ReaderController.selection(of: chunk, on: page)
        XCTAssertNotNil(sel)
        let found = (sel?.string ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        XCTAssertEqual(found, chunk)
    }

    /// Conversation follow-ups must keep the exact prompt of earlier turns in history (for KV cache hits)
    /// and append only delta sources for subsequent questions.
    func testConversationKVCacheOptimizationAndDeltaSources() {
        let exchange = ConversationExchange(
            question: "Wie wird das Timeout in Raft gewählt?",
            answer: "Das Election-Timeout liegt meist zwischen 150 und 300 ms [1].",
            fullPrompt: "Frage: Wie wird das Timeout in Raft gewählt?\n[1] Election-Timeout 150-300 ms\nAufgabe: Beantworte präzise..."
        )
        XCTAssertEqual(exchange.fullPrompt, "Frage: Wie wird das Timeout in Raft gewählt?\n[1] Election-Timeout 150-300 ms\nAufgabe: Beantworte präzise...")

        let state = AISynthesisStreamState(
            isGenerating: false,
            answerText: "Antwort",
            fullPrompt: "Vollständiger Prompt für KV-Cache"
        )
        XCTAssertEqual(state.fullPrompt, "Vollständiger Prompt für KV-Cache")

        let turn = ConversationTurn(
            question: "Erste Frage",
            state: state,
            addedSources: 4
        )
        XCTAssertEqual(turn.fullPrompt, "Vollständiger Prompt für KV-Cache")
    }
}
