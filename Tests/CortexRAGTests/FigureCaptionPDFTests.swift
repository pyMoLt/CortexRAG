import XCTest
import PDFKit
import AppKit
@testable import CortexCore
@testable import CortexVision

final class FigureCaptionPDFTests: XCTestCase {
    /// A4 page: running header at the top, a figure box in the middle, the caption right below it.
    private func makePage() throws -> PDFPage {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = try XCTUnwrap(CGDataConsumer(data: data as CFMutableData))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        ctx.beginPDFPage(nil)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        ("612 E 6.3 Fehlertolerante Replikation" as NSString).draw(at: CGPoint(x: 60, y: 800), withAttributes: font)
        ctx.setFillColor(NSColor.gray.cgColor)
        ctx.fill(CGRect(x: 100, y: 420, width: 400, height: 250))            // figure: top 172 … bottom 422 (from top)
        ("E-6.4 Konsensphasen zur Bestimmung des aktiven Leaders" as NSString).draw(at: CGPoint(x: 100, y: 400), withAttributes: font)
        ("Die Abstimmung erfolgt über ein Mehrheitsquorum der Knoten." as NSString).draw(at: CGPoint(x: 60, y: 300), withAttributes: font)
        NSGraphicsContext.current = nil
        ctx.endPDFPage()
        ctx.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
    }

    func testCaptionIsReadFromTextLayerBelowTheFigure() throws {
        let page = try makePage()
        // Normalized top-left bbox of the grey figure.
        let bbox = NormalizedRect(x: 100.0 / 595, y: (842 - 670) / 842.0, width: 400.0 / 595, height: 250.0 / 842)
        XCTAssertEqual(PDFVisionPipeline.pdfCaption(for: bbox, on: page, pageNumber: 612),
                       "E-6.4 Konsensphasen zur Bestimmung des aktiven Leaders")
    }

    func testNoTextLayerGivesNil() throws {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let ctx = try XCTUnwrap(CGContext(consumer: XCTUnwrap(CGDataConsumer(data: data as CFMutableData)), mediaBox: &box, nil))
        ctx.beginPDFPage(nil); ctx.fill(CGRect(x: 100, y: 420, width: 400, height: 250)); ctx.endPDFPage(); ctx.closePDF()
        let page = try XCTUnwrap(PDFDocument(data: data as Data)?.page(at: 0))
        XCTAssertNil(PDFVisionPipeline.pdfCaption(for: NormalizedRect(x: 0.17, y: 0.2, width: 0.67, height: 0.3), on: page, pageNumber: 1))
    }
}
