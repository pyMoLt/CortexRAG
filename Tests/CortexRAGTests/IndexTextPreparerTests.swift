import XCTest
@testable import CortexCore

final class IndexTextPreparerTests: XCTestCase {
    /// Slide pages of a lecture: footer date, institute logo OCR and page number repeat on every page.
    private let slides = [
        "25.11.2025\nunivERSITYI<iNsTiTuTe\nTheorem 1:\nAsynchrone Konsensprotokolle unter\nPartitionen (?)\n5",
        "25.11.2025\nunivERSITYI<iNsTiTuTe\nLeader-Wahl im Raft-Cluster\n• 50–60 % der Knoten bilden ein Quorum\n6",
        "25.11.2025\nunivERSITYI<iNsTiTuTe\nReplikation des Logs\n• Heartbeat-Nachrichten\n• Commit-Index des Leaders\n7",
        "25.11.2025\nunivERSITYI<iNsTiTuTe\nSystemmodell\nNetzwerk\nSpeicher-\nKnoten\nQuorum\n© fotolia.com\n8",
    ]

    func testFootersLogosCreditsAndPageNumbersAreRemoved() {
        let profile = DocumentTextProfile.build(from: slides)
        let cleaned = slides.enumerated().map { IndexTextPreparer.cleanPage($1, page: $0 + 5, profile: profile) }
        for page in cleaned {
            XCTAssertFalse(page.contains("25.11.2025"), page)
            XCTAssertFalse(page.contains("iNsTiTuTe"), page)
            XCTAssertFalse(page.contains("fotolia"), page)
        }
        XCTAssertTrue(cleaned[0].hasPrefix("Theorem 1:"))
        XCTAssertFalse(cleaned[1].hasSuffix("6"))
    }

    func testCreditLines() {
        XCTAssertTrue(IndexTextPreparer.isCreditLine("@ BilllonPhotos.com I fotoliaLom"))
        XCTAssertTrue(IndexTextPreparer.isCreditLine("© Shutterstock"))
        XCTAssertFalse(IndexTextPreparer.isCreditLine("Quelle: ACM Symposium on Operating Systems Principles"))
        XCTAssertFalse(IndexTextPreparer.isCreditLine("Timeout 150–300 ms"))
    }

    func testCyrillicOCRNoiseIsDropped() {
        XCTAssertEqual(IndexTextPreparer.stripForeignScriptNoise("30 мо. Knoten bilden ein Cluster"), "30 Knoten bilden ein Cluster")
        XCTAssertEqual(IndexTextPreparer.stripForeignScriptNoise("Timeout 250 ms"), "Timeout 250 ms")
    }

    func testSlideTitleFromLargestOCRLineIsMovedToFront() {
        let page = "Durchsatz nach Paketgröße\nLeader-Wahl ist fehlertolerant\n• 50–60 % der Knoten bestätigen"
        let title = IndexTextPreparer.slideTitle(cleanedPage: page, ocrCandidate: "Leader-Wahl ist fehlertolerant")
        XCTAssertEqual(title, "Leader-Wahl ist fehlertolerant")
        let reordered = IndexTextPreparer.titleFirst(page, title: title)
        XCTAssertTrue(reordered.hasPrefix("Leader-Wahl ist fehlertolerant\nDurchsatz nach Paketgröße"))
    }

    func testGenericOutlineLabels() {
        XCTAssertTrue(IndexTextPreparer.isGenericOutlineLabel("Foliennummer 13"))
        XCTAssertTrue(IndexTextPreparer.isGenericOutlineLabel("Folie 4"))
        XCTAssertTrue(IndexTextPreparer.isGenericOutlineLabel("Slide 2"))
        XCTAssertFalse(IndexTextPreparer.isGenericOutlineLabel("Theorem 1: FLP Impossibility"))
    }

    func testOCRLinesAreMergedOnlyWhenNew() {
        let page = "Verteilung der Antwortzeiten\nP50 Latenz 4,4 %"
        let merged = IndexTextPreparer.mergeOCRLines(["P50 Latenz 4,4 %", "P99 Latenz 0,2 %", "x"], into: page)
        XCTAssertEqual(merged, page + "\nP99 Latenz 0,2 %")
    }

    func testChunksNeverCutInsideWords() {
        let sentence = "Die Konsensbildung erfordert regelmäßige Heartbeats und eine Überwachung der Netzwerkverbindungen."
        let text = Array(repeating: sentence, count: 12).joined(separator: " ")
        let chunks = IndexTextPreparer.chunk(text, target: 300, overlap: 80)
        XCTAssertGreaterThan(chunks.count, 3)
        for c in chunks {
            XCTAssertLessThanOrEqual(c.count, 300)
            XCTAssertTrue(c.hasPrefix("Die "), "starts at a sentence: \(c.prefix(30))")
            XCTAssertTrue(c.hasSuffix("."), "ends at a sentence: \(c.suffix(30))")
        }
    }

    func testChunkOverlapRepeatsWholeLines() {
        let lines = (1...30).map { "Zeile \($0) mit etwas Inhalt zur Füllung" }.joined(separator: "\n")
        let chunks = IndexTextPreparer.chunk(lines, target: 200, overlap: 60)
        XCTAssertGreaterThan(chunks.count, 2)
        let lastOfFirst = chunks[0].components(separatedBy: "\n").last!
        XCTAssertTrue(chunks[1].hasPrefix(lastOfFirst), "overlap = whole trailing line")
    }

    func testChartAxisTicksAndOCRScrapsAreDropped() {
        let page = "Anfragen pro Sekunde 2024\n5.000\n4.500\n4.000\n3.500\nReplikation\n30.,\n30мо.\n80%\n4.531"
        let cleaned = IndexTextPreparer.cleanPage(page, page: 3, profile: .empty)
        XCTAssertFalse(cleaned.contains("4.500"), cleaned)
        XCTAssertFalse(cleaned.contains("30.,"), cleaned)
        XCTAssertFalse(cleaned.contains("мо"), cleaned)
        XCTAssertTrue(cleaned.contains("80%"), "single values stay: \(cleaned)")
        XCTAssertTrue(cleaned.contains("4.531"), cleaned)
    }

    func testTitleTakesPDFWordsAndRejectsNumberScraps() {
        let page = "Zustandsmaschinen sind deterministisch, insbesondere bei replizierten Datenbanken und weiteren Knoten im Clusterverlauf\n• 50–60 %"
        XCTAssertEqual(IndexTextPreparer.slideTitle(cleanedPage: page, ocrCandidate: "Zustandsmaschinen sind deterministisch, insbesondere"),
                       "Zustandsmaschinen sind deterministisch, insbesondere")
        XCTAssertEqual(IndexTextPreparer.slideTitle(cleanedPage: "KNOTEN\nsynchronisieren das Transaktionsprotokoll im Cluster.", ocrCandidate: "30.,"), "KNOTEN")
    }

    func testFigureCaptionCleaning() {
        // Running headers of textbooks are no captions.
        XCTAssertTrue(IndexTextPreparer.isRunningHeader("672 F 1 Fehlertoleranz in verteilten Datenbanksystemen"))
        XCTAssertTrue(IndexTextPreparer.isRunningHeader("389 D 1.3 Vektorquantisierung"))
        XCTAssertFalse(IndexTextPreparer.isRunningHeader("E-1.7 B-Baum mit Blattknoten"))
        XCTAssertNil(IndexTextPreparer.cleanCaption("316 B 7 Speicherverwaltung\n12", page: 306))
        // Duplicated textbook label, ligature, bullet symbol and panel letters are tidied.
        XCTAssertEqual(IndexTextPreparer.cleanCaption("⊙ E-6.15 ⊙ E-6.15 Zustandsübergang im Leader-Knoten a b", page: 581),
                       "E-6.15 Zustandsübergang im Leader-Knoten")
        XCTAssertEqual(IndexTextPreparer.cleanCaption("F-1.6 Pufferpool-Zugriff", page: 677), "F-1.6 Pufferpool-Zugriff")
        // Publisher footers never become captions.
        XCTAssertNil(IndexTextPreparer.cleanCaption("Tanenbaum, Distributed Systems (ISBN 978-3-13-125344-6), © 2023 Academic Verlag KG", page: 3))
        XCTAssertNil(IndexTextPreparer.cleanCaption("All rights reserved. Usage subject to terms and conditions of license.", page: 3))
        // A caption line inside surrounding text is found, with its continuation.
        XCTAssertEqual(IndexTextPreparer.captionLine(in: "Text davor.\nAbb. 3 Konsensphasen zur\nbestimmung des aktiven Leaders\nweiter"),
                       "Abb. 3 Konsensphasen zur bestimmung des aktiven Leaders")
        // Long captions are cut at a sentence or word boundary.
        let long = String(repeating: "Der Leader repliziert Log-Einträge an alle Follower. ", count: 8)
        let cut = IndexTextPreparer.cleanCaption(long, page: 1)!
        XCTAssertLessThanOrEqual(cut.count, 222)
        XCTAssertTrue(cut.hasSuffix(".") || cut.hasSuffix("…"))
    }
}
