import XCTest
import PDFKit
@testable import CortexCore
@testable import CortexRAGApp

final class ChunkLocatorTests: XCTestCase {
    private let page = """
    25.11.2025
    Durchsatz verteilter Datenbanken nach Replikationsfaktor
    Zustandsmaschinen sind fehlertolerant, insbesondere bei Clustern mit
     ungerader Knotenanzahl. Die tatsächlichen Latenzen liegen vermut-
    lich niedriger – viele Systeme nutzen Pipeline-Batching.
    3
    """

    func testCleanedChunkWithMovedTitleIsFound() throws {
        // As indexed: title first, lines joined, hyphenation removed, footer and page number gone.
        let chunk = "Zustandsmaschinen sind fehlertolerant\nZustandsmaschinen sind fehlertolerant, insbesondere bei Clustern mit ungerader Knotenanzahl. Die tatsächlichen Latenzen liegen vermutlich niedriger – viele Systeme nutzen Pipeline-Batching."
        let r = try XCTUnwrap(ReaderController.matchRange(of: chunk, in: page))
        let selected = (page as NSString).substring(with: r)
        XCTAssertTrue(selected.hasPrefix("Zustandsmaschinen sind"), selected)
        XCTAssertTrue(selected.hasSuffix("Pipeline-Batching."), selected)
        XCTAssertFalse(selected.contains("25.11.2025"))
    }

    func testUnrelatedTextIsNotMatched() {
        XCTAssertNil(ReaderController.matchRange(of: "B-Bäume werden in relationalen Datenbanksystemen zur Indexierung eingesetzt und regelmäßig balanciert", in: page))
    }

    func testTinyPagesDoNotCrash() {
        XCTAssertNil(ReaderController.matchRange(of: "eins zwei drei vier fünf", in: "3"))
    }

    /// Share of indexed chunks that the reader can mark on their page. Runs only with `CORTEX_LOCATOR_BENCH=1`
    /// and `CORTEXRAG_HOME` pointing to an indexed library.
    func testLocatorCoverageOnLibrary() throws {
        guard ProcessInfo.processInfo.environment["CORTEX_LOCATOR_BENCH"] != nil else { throw XCTSkip("benchmark not requested") }
        let db = try CortexDatabase(path: CortexPaths.databaseURL.path)
        var total = 0, found = 0, imageOnly = 0, perDoc: [String: (Int, Int)] = [:]
        for doc in try db.listDocuments() {
            guard let pdf = PDFDocument(url: URL(fileURLWithPath: DocumentFormats.readablePDFPath(for: doc.filePath))) else { continue }
            for chunk in try db.listChunks(documentID: doc.id) where !chunk.content.hasPrefix("[Grafik-") {
                guard let p = pdf.page(at: chunk.pageNumber - 1) else { continue }
                // Image-only slides (no text layer): the reader shows the whole slide, nothing to match.
                guard let s = p.string, s.trimmingCharacters(in: .whitespacesAndNewlines).count >= 80 else { imageOnly += 1; continue }
                total += 1
                let ok = ReaderController.matchRange(of: chunk.content, in: s) != nil
                if ok { found += 1 }
                let cur = perDoc[doc.title] ?? (0, 0)
                perDoc[doc.title] = (cur.0 + (ok ? 1 : 0), cur.1 + 1)
            }
        }
        for (t, v) in perDoc.sorted(by: { $0.key < $1.key }) { print(String(format: "%5.1f %%  %@", 100 * Double(v.0) / Double(v.1), t)) }
        print("Bildfolien ohne Textebene (ganze Seite): \(imageOnly)")
        print("Gesamt: \(found)/\(total) = \(String(format: "%.1f", 100 * Double(found) / Double(max(total, 1)))) %")
        XCTAssertGreaterThan(Double(found) / Double(max(total, 1)), 0.9)
    }
}
