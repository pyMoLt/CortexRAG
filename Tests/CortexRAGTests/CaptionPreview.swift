import XCTest
import PDFKit
import SQLite3
@testable import CortexCore
@testable import CortexVision

/// Old vs new captions of uncaptioned figures on a real library. Prints only; runs with `CORTEX_CAPTION_PREVIEW=<n>`
/// and `CORTEXRAG_HOME` pointing to an indexed library (a copy – nothing is written).
final class CaptionPreview: XCTestCase {
    func testCompareCaptions() throws {
        guard let nStr = ProcessInfo.processInfo.environment["CORTEX_CAPTION_PREVIEW"], let n = Int(nStr) else {
            throw XCTSkip("preview not requested")
        }
        let filter = ProcessInfo.processInfo.environment["CORTEX_CAPTION_FILTER"] ?? "%"
        let db = try CortexDatabase(path: CortexPaths.databaseURL.path)
        var rows: [(title: String, path: String, page: Int, caption: String, bbox: String)] = []
        try db.query("""
            SELECT d.title, d.file_path, f.page_number, f.caption_text, f.bbox_json FROM figures f
            JOIN documents d ON d.id = f.document_id
            WHERE f.figure_label LIKE 'Abb. S.%' AND d.title LIKE ? ORDER BY random() LIMIT ?
        """, [.text(filter), .int(n)]) { st in
            func t(_ i: Int32) -> String { sqlite3_column_text(st, i).map { String(cString: $0) } ?? "" }
            rows.append((t(0), t(1), Int(sqlite3_column_int(st, 2)), t(3), t(4)))
        }
        var improved = 0
        for r in rows {
            guard let pdf = PDFDocument(url: URL(fileURLWithPath: DocumentFormats.readablePDFPath(for: r.path))),
                  let page = pdf.page(at: r.page - 1),
                  let bbox = try? JSONDecoder().decode(NormalizedRect.self, from: Data(r.bbox.utf8)) else { continue }
            let new = PDFVisionPipeline.pdfCaption(for: bbox, on: page, pageNumber: r.page)
            if new != nil { improved += 1 }
            print("— \(r.title.prefix(28)) S.\(r.page)\n   alt: \(r.caption.prefix(110))\n   neu: \(new?.prefix(140) ?? "(keine Textebene → Fallback)")")
        }
        print("PDF-Unterschrift gefunden: \(improved)/\(rows.count)")
    }
}
