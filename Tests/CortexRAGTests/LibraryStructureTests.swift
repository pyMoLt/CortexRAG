import XCTest
import SQLite3
@testable import CortexCore

/// Library structure: area (optional) > topic > imported folder tree > documents.
final class LibraryStructureTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cortex_lib_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func vec() -> [Float] { var v = [Float](repeating: 0, count: 768); v[0] = 1; return v }

    private func add(_ db: CortexDatabase, id: String, topic: String, path: String, folder: String? = nil) throws {
        let doc = LibraryDocument(id: id, collectionID: topic, folderID: folder, title: id, filePath: path, pageCount: 1)
        let chunk = DocumentChunk(id: "c_\(id)", documentID: id, pageNumber: 1, chunkIndex: 0, prevChunkID: nil, nextChunkID: nil,
                                  breadcrumb: id, content: "Consensus Protokoll \(id)", embedding: vec())
        try db.saveDocumentIndex(document: doc, chunks: [chunk], figures: [])
    }

    func testFreshLibraryIsEmpty() throws {
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        XCTAssertTrue(try db.listModules().isEmpty)
        XCTAssertTrue(try db.listCollections().isEmpty)
    }

    func testTopicWithoutAreaIsSearchableAndListed() throws {
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        try db.saveCollection(LibraryCollection(id: "t1", moduleID: "", name: "Verteilte Systeme"))
        try add(db, id: "d1", topic: "t1", path: "/x/a.pdf")

        let hits = try db.hybridSearch(queryText: "Consensus", queryVector: vec(), scope: ScopeFilter(collectionIDs: ["t1"], matchAnyLevel: true),
                                       contextChunks: 0, includeFigures: false, topK: 5)
        XCTAssertEqual(hits.map(\.documentID), ["d1"])
        let tree = try db.buildLibraryHierarchy()
        XCTAssertEqual(tree.map(\.id), [""], "loose topics appear under the synthetic 'Ohne Bereich' node")
        XCTAssertEqual(tree.first?.collections.map(\.id), ["t1"])
    }

    func testDeletingAreaKeepsTopicsAndDocuments() throws {
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        try db.saveModule(LibraryModule(id: "m", name: "Informatik"))
        try db.saveCollection(LibraryCollection(id: "t1", moduleID: "m", name: "Verteilte Systeme"))
        try add(db, id: "d1", topic: "t1", path: "/x/a.pdf")
        try db.deleteModule(id: "m")
        XCTAssertEqual(try db.listCollections().first?.moduleID, "")
        XCTAssertEqual(try db.listDocuments().count, 1)
    }

    func testSubfolderPrefixSelectsWholeSubtreeOnly() throws {
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        try db.saveCollection(LibraryCollection(id: "t1", moduleID: "", name: "Verteilte Systeme"))
        try add(db, id: "vl1", topic: "t1", path: "/Courses/Sys/Vorlesungen/VL1.pdf")
        try add(db, id: "vl2", topic: "t1", path: "/Courses/Sys/Vorlesungen/Woche 2/VL2.pdf")
        try add(db, id: "skript", topic: "t1", path: "/Courses/Sys/Skripte/S.pdf")
        // Same prefix string but a different folder must not match.
        try add(db, id: "other", topic: "t1", path: "/Courses/Sys/Vorlesungen-alt/X.pdf")

        let scope = ScopeFilter(pathPrefixes: ["/Courses/Sys/Vorlesungen"], matchAnyLevel: true)
        let hits = try db.hybridSearch(queryText: "Consensus", queryVector: vec(), scope: scope, contextChunks: 0, includeFigures: false, topK: 10)
        XCTAssertEqual(Set(hits.map(\.documentID)), ["vl1", "vl2"])
    }

    /// Renaming or moving a topic and re-saving a folder must not cascade into its documents.
    func testUpdatingTopicAndFolderKeepsDocuments() throws {
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        try db.saveModule(LibraryModule(id: "m", name: "Informatik"))
        try db.saveCollection(LibraryCollection(id: "t1", moduleID: "", name: "Verteilte Systeme"))
        let folder = WatchedFolder(id: "f", collectionID: "t1", name: "VL", path: "/x")
        try db.saveWatchedFolder(folder)
        try add(db, id: "d1", topic: "t1", path: "/x/a.pdf", folder: "f")

        try db.saveCollection(LibraryCollection(id: "t1", moduleID: "m", name: "Verteilte Systeme (neu)"))
        try db.saveWatchedFolder(folder)
        try db.saveModule(LibraryModule(id: "m", name: "Informatik & Systeme"))

        let docs = try db.listDocuments()
        XCTAssertEqual(docs.map(\.id), ["d1"])
        XCTAssertEqual(docs.first?.folderID, "f")
        XCTAssertEqual(try db.listCollections().first?.name, "Verteilte Systeme (neu)")
        XCTAssertEqual(try db.listCollections().first?.moduleID, "m")
        let hits = try db.hybridSearch(queryText: "Consensus", queryVector: vec(), scope: ScopeFilter(), contextChunks: 0, includeFigures: false, topK: 5)
        XCTAssertEqual(hits.map(\.documentID), ["d1"], "chunks survive")
    }

    /// Separately imported areas/topics and single PDFs from other areas can be searched together.
    func testSelectionAcrossAreasTopicsAndSingleDocuments() throws {
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        for (m, t) in [("A", "sys"), ("B", "db"), ("C", "net")] {
            try db.saveModule(LibraryModule(id: m, name: m))
            try db.saveCollection(LibraryCollection(id: t, moduleID: m, name: t))
        }
        try add(db, id: "s1", topic: "sys", path: "/A/s1.pdf")
        try add(db, id: "d1", topic: "db", path: "/B/d1.pdf")
        try add(db, id: "x1", topic: "net", path: "/C/x1.pdf")
        try add(db, id: "x2", topic: "net", path: "/C/x2.pdf")
        for id in ["s1", "d1", "x1", "x2"] {
            try db.run("""
                INSERT INTO figures (id, document_id, page_number, breadcrumb, figure_label, caption_text, surrounding_context,
                    cropped_image_path, full_page_image_path, bbox_json, visual_embedding, caption_embedding)
                VALUES (?, ?, 1, '', 'Abb', 'Consensus', '', '/x.png', '/p.png', '{"x":0,"y":0,"width":1,"height":1}', ?, ?)
            """, [.text("f_\(id)"), .text(id), .blob(VectorMath.encodeFloat32Blob(vec())), .blob(VectorMath.encodeFloat32Blob(vec()))])
        }
        let scope = ScopeFilter(collectionIDs: ["sys", "db"], documentIDs: ["x1"], matchAnyLevel: true)
        let hits = try db.hybridSearch(queryText: "Consensus", queryVector: vec(), scope: scope, contextChunks: 0, includeFigures: false, topK: 10)
        XCTAssertEqual(Set(hits.map(\.documentID)), ["s1", "d1", "x1"])
        let figs = try db.searchFigures(queryText: "Consensus", queryVector: vec(), scope: scope, topK: 10)
        XCTAssertEqual(Set(figs.map(\.documentID)), ["s1", "d1", "x1"])

        let areas = ScopeFilter(moduleIDs: ["A", "B"], matchAnyLevel: true)
        let areaHits = try db.hybridSearch(queryText: "Consensus", queryVector: vec(), scope: areas, contextChunks: 0, includeFigures: false, topK: 10)
        XCTAssertEqual(Set(areaHits.map(\.documentID)), ["s1", "d1"])
    }

    func testDeletingConvertedDocumentRemovesItsPDFRendition() throws {
        let db = try CortexDatabase(path: dir.appendingPathComponent("t.sqlite").path)
        try db.saveCollection(LibraryCollection(id: "t1", moduleID: "", name: "Verteilte Systeme"))
        let original = dir.appendingPathComponent("VL.pptx").path
        try add(db, id: "p", topic: "t1", path: original)
        let rendition = DocumentFormats.convertedPDFURL(forOriginal: original)
        try FileManager.default.createDirectory(at: rendition.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("%PDF".utf8).write(to: rendition)
        try db.deleteDocument(id: "p")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rendition.path))
    }

    /// Databases created before this change bound topics to areas with a foreign key.
    func testOldSchemaIsMigratedWithoutLosingDocuments() throws {
        let path = dir.appendingPathComponent("old.sqlite").path
        var h: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &h), SQLITE_OK)
        let old = """
        PRAGMA foreign_keys = ON;
        CREATE TABLE modules (id TEXT PRIMARY KEY, name TEXT NOT NULL, icon_name TEXT NOT NULL DEFAULT 'x', created_at REAL NOT NULL);
        CREATE TABLE collections (id TEXT PRIMARY KEY, module_id TEXT NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
            name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '', created_at REAL NOT NULL);
        CREATE TABLE documents (id TEXT PRIMARY KEY, collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
            folder_id TEXT, title TEXT NOT NULL, file_path TEXT NOT NULL UNIQUE, file_hash TEXT NOT NULL DEFAULT '',
            page_count INTEGER NOT NULL DEFAULT 0, abstract_summary TEXT NOT NULL DEFAULT '', toc_json TEXT NOT NULL DEFAULT '[]',
            index_status TEXT NOT NULL DEFAULT 'pending', engine_used TEXT NOT NULL DEFAULT 'llama', indexed_at REAL,
            chunk_count INTEGER NOT NULL DEFAULT 0, figure_count INTEGER NOT NULL DEFAULT 0);
        INSERT INTO modules VALUES ('m', 'Informatik', 'x', 0);
        INSERT INTO collections VALUES ('t1', 'm', 'Verteilte Systeme', '', 0);
        INSERT INTO documents (id, collection_id, title, file_path) VALUES ('d1', 't1', 'Doc', '/x/a.pdf');
        """
        XCTAssertEqual(sqlite3_exec(h, old, nil, nil, nil), SQLITE_OK)
        sqlite3_close(h)

        let db = try CortexDatabase(path: path)
        XCTAssertEqual(try db.listDocuments().map(\.id), ["d1"])
        try db.saveCollection(LibraryCollection(id: "t2", moduleID: "", name: "Ohne Bereich"))
        XCTAssertEqual(Set(try db.listCollections().map(\.id)), ["t1", "t2"])
    }
}
