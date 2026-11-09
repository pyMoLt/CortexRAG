import XCTest
@testable import CortexCore

final class SearchFusionTests: XCTestCase {
    private func text(_ doc: String, page: Int, _ i: Int) -> SearchResultItem {
        SearchResultItem(rank: i, score: 0.9 - Double(i) * 0.01, vectorScore: 0.8, keywordScore: 0, chunkID: "c\(doc)\(page)",
                         documentID: doc, documentTitle: doc, documentPath: "/\(doc).pdf", collectionID: "t", collectionName: "T",
                         moduleID: "", moduleName: "", pageNumber: page, breadcrumb: doc, contextBefore: "", matchedContent: "Text",
                         contextAfter: "", fullPageImagePath: "", figuresOnPage: [])
    }

    private func figure(_ doc: String, page: Int, score: Double) -> FigureResultItem {
        FigureResultItem(figureID: "f\(doc)\(page)", documentID: doc, documentTitle: doc, documentPath: "/\(doc).pdf",
                         collectionName: "T", moduleName: "", pageNumber: page, breadcrumb: doc, label: "Abb. \(page)",
                         caption: "Diagramm", surroundingContext: "", croppedImagePath: "/x.png", fullPageImagePath: "/p.png",
                         bbox: NormalizedRect(x: 0, y: 0, width: 1, height: 1), score: score)
    }

    func testFiguresBelowFloorDoNotAppear() {
        let hits = SearchFusion.fuse(text: [text("a", page: 1, 1), text("a", page: 2, 2)],
                                     figures: [figure("b", page: 9, score: 0.2)], mode: .all, topK: 8, minFigureScore: 0.5)
        XCTAssertEqual(hits.map(\.isFigure), [false, false])
    }

    func testFittingFigureIsMixedInByRank() {
        let hits = SearchFusion.fuse(text: [text("a", page: 1, 1), text("a", page: 2, 2), text("a", page: 3, 3)],
                                     figures: [figure("b", page: 9, score: 0.7)], mode: .all, topK: 8, minFigureScore: 0.5)
        XCTAssertEqual(hits.count, 4)
        XCTAssertFalse(hits[0].isFigure, "on a tie the text hit stays first")
        XCTAssertTrue(hits[1].isFigure)
        XCTAssertEqual(hits[1].chunkID, "fig:fb9")
        XCTAssertEqual(hits.map(\.rank), [1, 2, 3, 4])
    }

    func testFigureOfAPageThatIsAlreadyATextHitIsNotRepeated() {
        let hits = SearchFusion.fuse(text: [text("a", page: 1, 1)], figures: [figure("a", page: 1, score: 0.9)],
                                     mode: .all, topK: 8, minFigureScore: 0.5)
        XCTAssertEqual(hits.count, 1)
    }

    func testModesFilterKinds() {
        let t = [text("a", page: 1, 1)]
        let f = [figure("b", page: 2, score: 0.1)]
        XCTAssertEqual(SearchFusion.fuse(text: t, figures: f, mode: .text, topK: 8, minFigureScore: 0.5).map(\.isFigure), [false])
        // "Only images" shows figures even below the floor: the user asked for images explicitly.
        XCTAssertEqual(SearchFusion.fuse(text: t, figures: f, mode: .figures, topK: 8, minFigureScore: 0.5).map(\.isFigure), [true])
    }

    func testFigureHitCarriesCaptionAndImage() {
        let hit = SearchResultItem(figureHit: figure("b", page: 4, score: 0.6), rank: 1, score: 0.6)
        XCTAssertEqual(hit.matchedContent, "Abb. 4: Diagramm")
        XCTAssertEqual(hit.figuresOnPage.first?.croppedImagePath, "/x.png")
        XCTAssertEqual(hit.pageNumber, 4)
    }
}
