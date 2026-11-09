import XCTest
import PDFKit
import AppKit
@testable import CortexCore
@testable import CortexEmbedders
@testable import CortexVision
@testable import CortexIPC

final class CortexRAGTests: XCTestCase {
    func testDatabaseHierarchyAndScopedSearch() throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("cortex_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let dbPath = tmpDir.appendingPathComponent("test.sqlite").path
        let db = try CortexDatabase(path: dbPath)
        try db.seedExampleLibrary()

        let modules = try db.listModules()
        XCTAssertFalse(modules.isEmpty, "Default modules should be seeded")

        let doc = LibraryDocument(
            id: "doc_sys_test",
            collectionID: "col_systems",
            title: "Raft_Vorlesung",
            filePath: "/tmp/Raft_Vorlesung.pdf",
            pageCount: 2,
            abstractSummary: "Übersicht über verteilte Konsensprotokolle",
            toc: [TOCItem(title: "1. Raft-Konsens", pageNumber: 1, level: 1)]
        )

        var v1 = [Float](repeating: 0, count: 768); v1[0] = 0.8; v1[1] = 0.6
        var v2 = [Float](repeating: 0, count: 768); v2[0] = 0.6; v2[1] = 0.8

        let chunks = [
            DocumentChunk(
                id: "chk_1",
                documentID: doc.id,
                pageNumber: 1,
                chunkIndex: 0,
                prevChunkID: nil,
                nextChunkID: "chk_2",
                breadcrumb: "Raft_Vorlesung > 1. Raft-Konsens",
                content: "Einleitung: Die Replikation der Zustandsmaschine erfolgt über das Quorum.",
                embedding: v1
            ),
            DocumentChunk(
                id: "chk_2",
                documentID: doc.id,
                pageNumber: 1,
                chunkIndex: 1,
                prevChunkID: "chk_1",
                nextChunkID: nil,
                breadcrumb: "Raft_Vorlesung > 1. Raft-Konsens",
                content: "Das Raft-Protokoll nutzt Leader-Election und garantiert lineare Konsistenz über Log-Matching.",
                embedding: v2
            )
        ]

        let figs = [
            DocumentFigure(
                id: "fig_1",
                documentID: doc.id,
                pageNumber: 1,
                breadcrumb: "Raft_Vorlesung > 1. Raft-Konsens",
                figureLabel: "Abb. 1.1",
                captionText: "Abb. 1.1: Zustandsübergänge zwischen Follower, Candidate und Leader.",
                surroundingContext: "Raft-Konsens Zustandsautomat",
                croppedImagePath: "/tmp/crop1.png",
                fullPageImagePath: "/tmp/page1.png",
                bbox: NormalizedRect(x: 0.1, y: 0.2, width: 0.8, height: 0.4),
                visualEmbedding: v2,
                captionEmbedding: v2
            )
        ]

        try db.saveDocumentIndex(document: doc, chunks: chunks, figures: figs)

        // 1. Test hybrid search scoped to Verteilte Systeme
        let results = try db.hybridSearch(
            queryText: "Raft Leader-Election",
            queryVector: v2,
            scope: ScopeFilter(collectionNames: ["Verteilte Systeme"]),
            contextChunks: 1,
            includeFigures: true,
            topK: 5
        )
        // chk_1 and chk_2 are neighbours of the same document: merged into one hit, chk_1 moves into the context
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.chunkID, "chk_2")
        XCTAssertEqual(results.first?.mergedNeighborCount, 1)
        XCTAssertTrue(results.first?.contextBefore.contains("Quorum") ?? false, "Context before should be automatically attached")
        XCTAssertEqual(results.first?.figuresOnPage.count, 1)

        // 2. Test negative scope filter (Datenbanksysteme should return 0 matches for this Verteilte Systeme doc)
        let dbResults = try db.hybridSearch(
            queryText: "Raft",
            queryVector: v2,
            scope: ScopeFilter(collectionNames: ["Datenbanksysteme"]),
            contextChunks: 1,
            includeFigures: true,
            topK: 5
        )
        XCTAssertTrue(dbResults.isEmpty)

        // 3. Test folder-level scope and LibraryHierarchy tree
        let folder = WatchedFolder(id: "fol_ws26", collectionID: "col_systems", name: "Vorlesungswoche_3_Konsens", path: "/tmp/Vorlesungswoche_3")
        try db.saveWatchedFolder(folder)
        var docWithFolder = doc
        docWithFolder.folderID = folder.id
        try db.saveDocumentIndex(document: docWithFolder, chunks: chunks, figures: figs)

        let folderScoped = try db.hybridSearch(
            queryText: "Raft",
            queryVector: v2,
            scope: ScopeFilter(folderNames: ["Vorlesungswoche_3"]),
            contextChunks: 1,
            includeFigures: true,
            topK: 5
        )
        XCTAssertEqual(folderScoped.count, 1)
        XCTAssertEqual(folderScoped.first?.documentID, doc.id)

        let tree = try db.buildLibraryHierarchy(activeUIScope: ScopeFilter(folderIDs: ["fol_ws26"]))
        let sysNode = tree.flatMap(\.collections).first(where: { $0.id == "col_systems" })
        XCTAssertEqual(sysNode?.folders.first?.name, "Vorlesungswoche_3_Konsens")
        XCTAssertTrue(sysNode?.folders.first?.isSelectedInUI ?? false)

        // 4. Test asymmetric expandChunkContext (before=0, after=1)
        let expandedAfterOnly = try db.expandChunkContext(chunkID: "chk_1", before: 0, after: 1)
        XCTAssertEqual(expandedAfterOnly?.contextBefore, "")
        XCTAssertTrue(expandedAfterOnly?.contextAfter.contains("Leader-Election") ?? false)

        // 5. Test clean deletion removes FTS entries
        try db.deleteDocument(id: doc.id)
        let afterDelete = try db.hybridSearch(queryText: "Raft", queryVector: v2)
        XCTAssertTrue(afterDelete.isEmpty)
    }

    func testPDFVisionPipelineAndFigureCropping() throws {
        let tmpPDF = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic_textbook_\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmpPDF) }
        // The pipeline writes page images and crops into the app's asset folders; leave no trace there.
        defer {
            try? FileManager.default.removeItem(at: CortexPaths.pagesAssetsDir.appendingPathComponent("doc_synth_test"))
            try? FileManager.default.removeItem(at: CortexPaths.figuresAssetsDir.appendingPathComponent("doc_synth_test"))
        }

        try Self.createSampleAcademicPDF(at: tmpPDF)
        let pkg = try PDFVisionPipeline.processPDF(
            at: tmpPDF,
            documentID: "doc_synth_test",
            collectionID: "col_systems"
        )

        XCTAssertEqual(pkg.document.pageCount, 1)
        XCTAssertFalse(pkg.chunks.isEmpty, "Chunks should be extracted from PDF")
        XCTAssertFalse(pkg.figureCandidates.isEmpty, "Figure candidate should be detected and cropped via Apple Vision")
        if let firstFig = pkg.figureCandidates.first {
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstFig.croppedImagePath))
            XCTAssertTrue(FileManager.default.fileExists(atPath: firstFig.fullPageImagePath))
        }
    }

    static func createSampleAcademicPDF(at url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "TestPDF", code: 1)
        }

        ctx.beginPDFPage(nil)
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(mediaBox)

        let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 18),
            .foregroundColor: NSColor.black
        ]
        let bodyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.black
        ]

        ("1. Verteilte Konsensprotokolle und Replikation" as NSString).draw(at: NSPoint(x: 50, y: 770), withAttributes: titleAttrs)
        let paragraph = """
        Das Raft-Konsensprotokoll steuert die Zustandsmaschinen-Replikation über einen gewählten Leader-Knoten. Sobald ein Log-Eintrag von einer Mehrheit (Quorum) der Follower-Knoten bestätigt wurde, gilt er als dauerhaft committet und überlebt beliebige Minderheitsausfälle.
        """
        (paragraph as NSString).draw(in: NSRect(x: 50, y: 620, width: 495, height: 130), withAttributes: bodyAttrs)

        // Draw a colorful diagram in the middle of the page
        ctx.setFillColor(red: 0.12, green: 0.38, blue: 0.82, alpha: 1)
        ctx.fill(CGRect(x: 90, y: 310, width: 410, height: 240))
        ctx.setFillColor(red: 0.92, green: 0.25, blue: 0.30, alpha: 1)
        ctx.fillEllipse(in: CGRect(x: 220, y: 360, width: 150, height: 140))

        ("Abb. 1.1: Schematischer Zustandsautomat der Leader-Wahl und Log-Replikation im Cluster." as NSString)
            .draw(in: NSRect(x: 90, y: 260, width: 420, height: 40), withAttributes: bodyAttrs)

        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
    }

    func testMatryoshkaRerankerAndThinkBlockParser() {
        // 1. Test cross-dimension Matryoshka cosine similarity (256D query vs 768D stored blob)
        var fullVec = [Float](repeating: 0, count: 768)
        fullVec[0] = 0.6
        fullVec[1] = 0.8
        let blob768 = VectorMath.encodeFloat32Blob(fullVec)
        let query256 = Array(fullVec.prefix(256))
        XCTAssertEqual(query256.count, 256)
        let sim = VectorMath.dotProduct(query256, blob768)
        XCTAssertGreaterThan(sim, 0.99, "Cross-dimension MRL cosine similarity should be ~1.0 for identical prefix")

        // 2. Test CortexRerankerService reranking boosts exact lexical/phrase matches
        let c1 = SearchResultItem(
            rank: 1,
            score: 0.72,
            vectorScore: 0.72,
            keywordScore: 0.10,
            chunkID: "c1",
            documentID: "d1",
            documentTitle: "Allgemeine Replikation",
            documentPath: "/tmp/a.pdf",
            collectionID: "col_sys",
            collectionName: "Verteilte Systeme",
            moduleID: "mod_inf",
            moduleName: "Informatik",
            pageNumber: 3,
            breadcrumb: "Einleitung",
            contextBefore: "",
            matchedContent: "Allgemeine Hinweise zu verteilten Protokollen und Netzwerken im Überblick.",
            contextAfter: "",
            fullPageImagePath: "",
            figuresOnPage: []
        )
        let c2 = SearchResultItem(
            rank: 2,
            score: 0.68,
            vectorScore: 0.68,
            keywordScore: 0.40,
            chunkID: "c2",
            documentID: "d2",
            documentTitle: "Raft Spezifikation",
            documentPath: "/tmp/b.pdf",
            collectionID: "col_sys",
            collectionName: "Verteilte Systeme",
            moduleID: "mod_inf",
            moduleName: "Informatik",
            pageNumber: 12,
            breadcrumb: "Timeout Raft",
            contextBefore: "",
            matchedContent: "Das empfohlene Election-Timeout für Raft beträgt 150 ms bis 300 ms pro Knoten im lokalen Netzwerk.",
            contextAfter: "",
            fullPageImagePath: "",
            figuresOnPage: []
        )
        let reranked = CortexRerankerService.rerank(
            query: "Timeout Raft 150 ms",
            candidates: [c1, c2],
            model: .bgeRerankerV2M3,
            topK: 2,
            minScore: 0.05
        )
        XCTAssertEqual(reranked.first?.chunkID, "c2", "Reranker should promote exact parameter match c2 above generic c1")

        // 3. Test <think>...</think> separation in CortexLLMService
        let rawStream = "<think>Ich prüfe Quelle [1] zum Raft-Timeout.</think>\nDas empfohlene Timeout beträgt **150 ms** [1]."
        let parsed = CortexLLMService.splitThinkingAndAnswer(rawStream)
        XCTAssertEqual(parsed.thinking, "Ich prüfe Quelle [1] zum Raft-Timeout.")
        XCTAssertEqual(parsed.answer, "Das empfohlene Timeout beträgt **150 ms** [1].")
    }

    func testRound7ImageVectorModesAndPageFigures() throws {
        // 1. ImageVectorMode <-> imageVectorsEnabled synchronization (.adaptive is default)
        var settings = CortexSettings()
        XCTAssertEqual(settings.imageVectorMode, .adaptive)
        XCTAssertTrue(settings.imageVectorsEnabled)
        settings.imageVectorMode = .disabled
        XCTAssertFalse(settings.imageVectorsEnabled)
        settings.imageVectorsEnabled = true
        XCTAssertEqual(settings.imageVectorMode, .adaptive)
        settings.imageVectorMode = .fullPage
        XCTAssertTrue(settings.imageVectorsEnabled)
        settings.imageVectorMode = .cropsOnly
        XCTAssertTrue(settings.imageVectorsEnabled)

        // 2. Logo/noise filter ("ılogo") and slideTitle preference over single all-caps diagram labels ("LATENCY")
        XCTAssertTrue(IndexTextPreparer.isLogoOrNoiseFragment("ılogo"))
        XCTAssertTrue(IndexTextPreparer.isLogoOrNoiseFragment("ilogo"))
        XCTAssertFalse(IndexTextPreparer.isLogoOrNoiseFragment("Verteilte Systeme im Überblick"))
        let slideText = "LATENCY\nDurchsatz und Fehlertoleranz bei Replikation\nWeitere Details im Verlauf."
        XCTAssertEqual(IndexTextPreparer.slideTitle(cleanedPage: slideText, ocrCandidate: nil), "Durchsatz und Fehlertoleranz bei Replikation")

        // 3. Page deduplication in searchFigures & expandChunkContext("fig:<id>") & allFiguresByPage in SearchFusion
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("cortex_r7_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = try CortexDatabase(path: tmpDir.appendingPathComponent("r7.sqlite").path)
        try db.seedExampleLibrary()

        let doc = LibraryDocument(
            id: "doc_r7",
            collectionID: "col_systems",
            title: "Distributed_Consensus_VL",
            filePath: "/tmp/Distributed_Consensus_VL.pdf",
            pageCount: 5
        )
        var v = [Float](repeating: 0, count: 768); v[0] = 1.0
        let chunks = [
            DocumentChunk(id: "chk_p2", documentID: doc.id, pageNumber: 2, chunkIndex: 0,
                          prevChunkID: nil, nextChunkID: nil, breadcrumb: "Folie 2",
                          content: "Durchsatz replizierter Zustandsmaschinen im Cluster.", embedding: v)
        ]
        let figs = [
            DocumentFigure(id: "fig_p2_a", documentID: doc.id, pageNumber: 2, breadcrumb: "Folie 2",
                           figureLabel: "Abb. 2.1", captionText: "Balkendiagramm Durchsatz",
                           surroundingContext: "Kontext A", croppedImagePath: "/tmp/crop_a.png",
                           fullPageImagePath: "/tmp/page_2.png",
                           bbox: NormalizedRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
                           visualEmbedding: v, captionEmbedding: v),
            DocumentFigure(id: "fig_p2_b", documentID: doc.id, pageNumber: 2, breadcrumb: "Folie 2",
                           figureLabel: "Abb. 2.2", captionText: "Verlaufskurve Latenz",
                           surroundingContext: "Kontext B", croppedImagePath: "/tmp/crop_b.png",
                           fullPageImagePath: "/tmp/page_2.png",
                           bbox: NormalizedRect(x: 0.5, y: 0.1, width: 0.4, height: 0.4),
                           visualEmbedding: v, captionEmbedding: v)
        ]
        try db.saveDocumentIndex(document: doc, chunks: chunks, figures: figs)

        let deduped = try db.searchFigures(queryText: "Durchsatz", queryVector: v, topK: 10, deduplicateByPage: true)
        XCTAssertEqual(deduped.count, 1, "searchFigures with deduplicateByPage=true should return 1 representative per page")

        let allCrops = try db.searchFigures(queryText: "Durchsatz", queryVector: v, topK: 10, deduplicateByPage: false)
        XCTAssertEqual(allCrops.count, 2, "searchFigures with deduplicateByPage=false should return all crops on the page")

        let pageFigures = try db.fetchFiguresOnPage(
            documentID: doc.id, documentTitle: doc.title, documentPath: doc.filePath,
            collectionName: "Verteilte Systeme", moduleName: "Informatik", pageNumber: 2
        )
        XCTAssertEqual(pageFigures.count, 2, "fetchFiguresOnPage should return both cropped figures for MCP/CLI")

        let fused = SearchFusion.fuse(
            text: [],
            figures: deduped,
            mode: .figures,
            topK: 5,
            minFigureScore: 0.1,
            allFiguresByPage: ["\(doc.id)#2": pageFigures]
        )
        XCTAssertEqual(fused.first?.figuresOnPage.count, 2, "Fused page hit should carry all cropped figures on that page")

        let expandedFig = try db.expandChunkContext(chunkID: "fig:fig_p2_a", before: 1, after: 1)
        XCTAssertNotNil(expandedFig, "expandChunkContext should support fig:<figureID>")
        XCTAssertEqual(expandedFig?.documentID, doc.id)
    }

    func testDeduplicationBatterySpeedAndPauseCancel() throws {
        // 1. Document deduplication keeps the copy with the deepest subfolder path
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("cortex_dedup_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let db = try CortexDatabase(path: tmpDir.appendingPathComponent("dedup.sqlite").path)
        try db.seedExampleLibrary()

        var v = [Float](repeating: 0, count: 768); v[0] = 1.0
        let shallowDoc = LibraryDocument(
            id: "doc_shallow",
            collectionID: "col_systems",
            title: "Raft_Consensus_Guide",
            filePath: "/tmp/Courses/Systems/Raft_Consensus_Guide.pdf",
            fileHash: "hash_raft_123",
            pageCount: 6
        )
        let deepDoc = LibraryDocument(
            id: "doc_deep",
            collectionID: "col_systems",
            title: "Raft_Consensus_Guide",
            filePath: "/tmp/Courses/Systems/Protocols/Replication/Raft_Consensus_Guide.pdf",
            fileHash: "hash_raft_123",
            pageCount: 6
        )
        let chunkShallow = DocumentChunk(
            id: "chk_s", documentID: shallowDoc.id, pageNumber: 1, chunkIndex: 0,
            prevChunkID: nil, nextChunkID: nil, breadcrumb: "S1", content: "Inhalt", embedding: v
        )
        let chunkDeep = DocumentChunk(
            id: "chk_d", documentID: deepDoc.id, pageNumber: 1, chunkIndex: 0,
            prevChunkID: nil, nextChunkID: nil, breadcrumb: "S1", content: "Inhalt", embedding: v
        )
        try db.saveDocumentIndex(document: shallowDoc, chunks: [chunkShallow], figures: [])
        try db.saveDocumentIndex(document: deepDoc, chunks: [chunkDeep], figures: [])

        XCTAssertEqual(try db.listDocuments(collectionID: "col_systems").count, 2)
        let removed = try db.deduplicateDocuments()
        XCTAssertEqual(removed, 1, "deduplicateDocuments should remove 1 shallow duplicate")
        let remaining = try db.listDocuments(collectionID: "col_systems")
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, "doc_deep", "Should keep the copy in the deeper subfolder")

        // 2. Battery throttling mode in settings
        let settings = CortexSettings()
        XCTAssertEqual(settings.batteryThrottlingMode, .ecoSilent)
        XCTAssertTrue(IndexingThrottleMode.ecoSilent.displayName.hasPrefix("Minimal"))

        // 3. Manual pause and cancel in PowerManager
        let pm = PowerManager.shared
        pm.setManuallyPaused(false)
        XCTAssertFalse(pm.isManuallyPaused)
        pm.setManuallyPaused(true)
        XCTAssertTrue(pm.isManuallyPaused)
        pm.setManuallyPaused(false)
        XCTAssertFalse(pm.isManuallyPaused)

        let genBefore = pm.currentCancelGeneration
        pm.requestCancelDocument(path: "/tmp/test_cancel.pdf")
        XCTAssertTrue(pm.isCancelled(path: "/tmp/test_cancel.pdf"))
        pm.clearCancelledDocument(path: "/tmp/test_cancel.pdf")
        XCTAssertFalse(pm.isCancelled(path: "/tmp/test_cancel.pdf"))
        pm.requestCancelAllIndexing()
        XCTAssertGreaterThan(pm.currentCancelGeneration, genBefore)
    }
}
