import XCTest
@testable import CortexCore

final class DisplayCleanerTests: XCTestCase {
    func testSlideFooterLogoAndGlyphsAreRemoved() {
        let chunks = (1...6).map { i in "25.11.2025\nunivERSITYI<iNsTiTuTeLogo\nThema \(i)\n\u{F0E0} Folgerung \(i)\n\u{FFFC}\n\(i)" }
        let profile = DocumentTextProfile.build(from: chunks)
        let clean = ChunkDisplayCleaner.clean(chunks[2], page: 3, profile: profile)
        XCTAssertEqual(clean, "Thema 3\n→ Folgerung 3")
    }

    func testRunningHeaderPrefixIsStripped() {
        let chunks = (1...6).map { "Lecture Notes Distributed Systems \($0).1. Kapitel \($0)\nText über Thema \($0)." }
        let profile = DocumentTextProfile.build(from: chunks)
        XCTAssertEqual(profile.headerPrefix, "Lecture Notes Distributed Systems")
        XCTAssertEqual(ChunkDisplayCleaner.clean(chunks[0], profile: profile), "1.1. Kapitel 1\nText über Thema 1.")
    }

    func testWrappedBulletsAndHyphenationAreJoined() {
        let raw = "Wichtige Eigenschaften:\n\u{F0A7} Konsistenz der\nZustandsmaschine\nØ Fehlertoleranz des\nSpeicherclusters\nDie Architektur eines Daten-\nbanksystems ist modular. 45"
        let clean = ChunkDisplayCleaner.clean(raw, page: 45)
        XCTAssertEqual(clean, "Wichtige Eigenschaften:\n• Konsistenz der Zustandsmaschine\n• Fehlertoleranz des Speicherclusters\nDie Architektur eines Datenbanksystems ist modular.")
    }

    func testDefinitionRowsKeepTheirLines() {
        let raw = "Systemvergleich\nKonsens: Raft, Paxos, Viewstamped Replication\nSpeicher: B-Tree, LSM-Tree, WAL"
        XCTAssertEqual(ChunkDisplayCleaner.clean(raw), raw)
    }

    func testOCRGarbageAndDotLeadersAreCleaned() {
        let raw = "P4Er%Trkirnt2021.Nlf*2-1074 httpsJi&yatylOlm71dW115I234]15\n2.1. Verteilte Transaktionen . . . . . . . . . 18"
        XCTAssertEqual(ChunkDisplayCleaner.clean(raw), "2.1. Verteilte Transaktionen … 18")
    }

    func testTechnicalTokensAreNotGarbage() {
        XCTAssertFalse(ChunkDisplayCleaner.isGarbled("SHA256 und CRC32C bei WAL-Prüfsummen"))
        XCTAssertFalse(ChunkDisplayCleaner.isGarbled("RFC-9000 QUIC ↔ HTTP/3"))
    }
}
