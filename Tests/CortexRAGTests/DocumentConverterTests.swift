import XCTest
import PDFKit
@testable import CortexCore
@testable import CortexVision

final class DocumentConverterTests: XCTestCase {
    func testFormatDetection() {
        XCTAssertTrue(DocumentFormats.isSupported(URL(fileURLWithPath: "/a/VL.pptx")))
        XCTAssertTrue(DocumentFormats.isSupported(URL(fileURLWithPath: "/a/Skript.DOCX")))
        XCTAssertFalse(DocumentFormats.isSupported(URL(fileURLWithPath: "/a/bild.png")))
        XCTAssertEqual(DocumentFormats.readablePDFPath(for: "/a/x.pdf"), "/a/x.pdf")
        let converted = DocumentFormats.readablePDFPath(for: "/a/VL 1.pptx")
        XCTAssertTrue(converted.hasSuffix(".pdf") && converted.contains("/Converted/VL 1-"))
        XCTAssertNotEqual(converted, DocumentFormats.readablePDFPath(for: "/b/VL 1.pptx"), "same name, other folder")
    }

    /// Real conversion of Word and PowerPoint files. Runs only with `CORTEX_FORMAT_DIR` (needs LibreOffice for pptx).
    func testConvertsWordAndPowerPoint() throws {
        guard let dir = ProcessInfo.processInfo.environment["CORTEX_FORMAT_DIR"] else { throw XCTSkip("format test not requested") }
        for (file, expected) in [("Lithium.docx", "Hämodialyse"), ("Schmerzen.pptx", "Schmerz"), ("Buch.epub", "Kapitel 1: Angst"), ("Alice.epub", "Alice")] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
            let t0 = Date()
            let pdf = try DocumentConverter.pdfURL(for: url)
            let doc = try XCTUnwrap(PDFDocument(url: pdf))
            print("\(file): \(doc.pageCount) Seiten in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            XCTAssertGreaterThan(doc.pageCount, 0)
            XCTAssertTrue((doc.string ?? "").contains(expected), "\(file) text")
            if file == "Buch.epub" {
                let t = doc.string ?? ""
                XCTAssertLessThan(t.range(of: "Kapitel 1")!.lowerBound, t.range(of: "Kapitel 2")!.lowerBound, "spine order")
                XCTAssertTrue(t.contains("Herzrasen & Atemnot"), "entities decoded")
            }
            // Second call uses the cache.
            let t1 = Date()
            _ = try DocumentConverter.pdfURL(for: url)
            XCTAssertLessThan(Date().timeIntervalSince(t1), 0.2)
        }
    }
}
