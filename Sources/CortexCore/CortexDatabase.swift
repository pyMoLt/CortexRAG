import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class CortexDatabase: @unchecked Sendable {
    public struct DBError: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
        public init(_ message: String) { self.message = message }
    }

    private let lock = NSRecursiveLock()
    private var handle: OpaquePointer?
    public let path: String

    public init(path: String = CortexPaths.databaseURL.path) throws {
        try CortexPaths.ensureDirectories()
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let opened = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open SQLite DB at \(path)"
            if let db { sqlite3_close(db) }
            throw DBError(msg)
        }
        self.handle = opened
        sqlite3_busy_timeout(opened, 5000)
        try execute("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            PRAGMA foreign_keys = ON;
        """)
        try migrateSchema()
        try detachTopicsFromAreas()
        try repairStoredTitles()
    }

    /// One-time repair of document titles that were stored with broken (double-decoded) UTF-8.
    private func repairStoredTitles() throws {
        var fixes: [(String, String)] = []
        try query("SELECT id, title FROM documents") { stmt in
            let title = colText(stmt, 1)
            let repaired = CortexTextSanitizer.repairEncoding(title)
            if repaired != title { fixes.append((colText(stmt, 0), repaired)) }
        }
        for (id, title) in fixes {
            try run("UPDATE documents SET title = ? WHERE id = ?", [.text(title), .text(id)])
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    private func migrateSchema() throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS modules (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                icon_name TEXT NOT NULL DEFAULT 'books.vertical.fill',
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS collections (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS watched_folders (
                id TEXT PRIMARY KEY,
                collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                last_indexed_at REAL
            );

            CREATE TABLE IF NOT EXISTS documents (
                id TEXT PRIMARY KEY,
                collection_id TEXT NOT NULL REFERENCES collections(id) ON DELETE CASCADE,
                folder_id TEXT REFERENCES watched_folders(id) ON DELETE SET NULL,
                title TEXT NOT NULL,
                file_path TEXT NOT NULL UNIQUE,
                file_hash TEXT NOT NULL DEFAULT '',
                page_count INTEGER NOT NULL DEFAULT 0,
                abstract_summary TEXT NOT NULL DEFAULT '',
                toc_json TEXT NOT NULL DEFAULT '[]',
                index_status TEXT NOT NULL DEFAULT 'pending',
                engine_used TEXT NOT NULL DEFAULT 'llama',
                indexed_at REAL,
                chunk_count INTEGER NOT NULL DEFAULT 0,
                figure_count INTEGER NOT NULL DEFAULT 0
            );

            CREATE TABLE IF NOT EXISTS chunks (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                page_number INTEGER NOT NULL,
                chunk_index INTEGER NOT NULL,
                prev_chunk_id TEXT,
                next_chunk_id TEXT,
                breadcrumb TEXT NOT NULL DEFAULT '',
                content TEXT NOT NULL,
                embedding BLOB NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_chunks_doc_page ON chunks(document_id, page_number);
            CREATE INDEX IF NOT EXISTS idx_chunks_doc_idx ON chunks(document_id, chunk_index);

            CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
                chunk_id UNINDEXED,
                document_id UNINDEXED,
                breadcrumb,
                content,
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE TABLE IF NOT EXISTS figures (
                id TEXT PRIMARY KEY,
                document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
                page_number INTEGER NOT NULL,
                breadcrumb TEXT NOT NULL DEFAULT '',
                figure_label TEXT NOT NULL DEFAULT '',
                caption_text TEXT NOT NULL DEFAULT '',
                surrounding_context TEXT NOT NULL DEFAULT '',
                cropped_image_path TEXT NOT NULL,
                full_page_image_path TEXT NOT NULL,
                bbox_json TEXT NOT NULL,
                visual_embedding BLOB NOT NULL,
                caption_embedding BLOB NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_figures_doc_page ON figures(document_id, page_number);

            CREATE VIRTUAL TABLE IF NOT EXISTS figures_fts USING fts5(
                figure_id UNINDEXED,
                document_id UNINDEXED,
                figure_label,
                caption_text,
                surrounding_context,
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE TABLE IF NOT EXISTS agent_events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                source TEXT NOT NULL,
                operation TEXT NOT NULL,
                query TEXT NOT NULL,
                scope_summary TEXT NOT NULL,
                result_count INTEGER NOT NULL,
                figure_count INTEGER NOT NULL,
                latency_ms REAL NOT NULL,
                engine_used TEXT NOT NULL
            );
        """)
    }

    /// Example areas and topics. The app starts with an empty library; tests and demos call this explicitly.
    public func seedExampleLibrary() throws {
        let sys = LibraryModule(id: "mod_systeme", name: "Systeme & Netze", iconName: "server.rack")
        let inf = LibraryModule(id: "mod_informatik", name: "Informatik & KI", iconName: "cpu.fill")
        try saveModule(sys)
        try saveModule(inf)
        try saveCollection(LibraryCollection(id: "col_systems", moduleID: sys.id, name: "Verteilte Systeme"))
        try saveCollection(LibraryCollection(id: "col_databases", moduleID: sys.id, name: "Datenbanksysteme"))
        try saveCollection(LibraryCollection(id: "col_networks", moduleID: sys.id, name: "Rechnernetze"))
        try saveCollection(LibraryCollection(id: "col_ml", moduleID: inf.id, name: "Machine Learning & RAG"))
    }

    /// Older databases bound every topic to an area via a foreign key. Topics may now exist without an
    /// area (`module_id = ''`), so the table is rebuilt once without that constraint.
    private func detachTopicsFromAreas() throws {
        var sql = ""
        try query("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'collections'") { stmt in sql = colText(stmt, 0) }
        guard sql.contains("REFERENCES modules") else { return }
        // Foreign keys off: dropping the old table must not cascade into folders and documents.
        try execute("""
            PRAGMA foreign_keys = OFF;
            BEGIN;
            CREATE TABLE collections_new (
                id TEXT PRIMARY KEY,
                module_id TEXT NOT NULL DEFAULT '',
                name TEXT NOT NULL,
                description TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL
            );
            INSERT INTO collections_new SELECT id, module_id, name, description, created_at FROM collections;
            DROP TABLE collections;
            ALTER TABLE collections_new RENAME TO collections;
            COMMIT;
            PRAGMA foreign_keys = ON;
        """)
    }

    // MARK: - Low-level SQL Execution

    public func execute(_ sql: String) throws {
        try lock.withLock {
            guard let handle else { throw DBError("Database closed") }
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(handle, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
                if let err { sqlite3_free(err) }
                throw DBError("\(msg) in SQL: \(sql.prefix(140))")
            }
        }
    }

    public enum BindValue {
        case int(Int)
        case double(Double)
        case text(String)
        case blob(Data)
        case null
    }

    public func query(_ sql: String, _ binds: [BindValue] = [], row: (OpaquePointer) throws -> Void) throws {
        try lock.withLock {
            guard let handle else { throw DBError("Database closed") }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
                throw DBError("\(String(cString: sqlite3_errmsg(handle))) in: \(sql.prefix(160))")
            }
            defer { sqlite3_finalize(stmt) }
            try bindValues(stmt, binds)
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_ROW {
                    try row(stmt)
                } else if rc == SQLITE_DONE {
                    break
                } else {
                    throw DBError(String(cString: sqlite3_errmsg(handle)))
                }
            }
        }
    }

    public func run(_ sql: String, _ binds: [BindValue] = []) throws {
        try query(sql, binds) { _ in }
    }

    public func transaction<T>(_ block: () throws -> T) throws -> T {
        try lock.withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let value = try block()
                try execute("COMMIT")
                return value
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func bindValues(_ stmt: OpaquePointer, _ binds: [BindValue]) throws {
        guard let handle else { return }
        for (i, val) in binds.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch val {
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, sqlite3_int64(v))
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, sqliteTransient)
            case .blob(let d):
                rc = d.withUnsafeBytes { ptr in
                    sqlite3_bind_blob(stmt, idx, ptr.baseAddress, Int32(d.count), sqliteTransient)
                }
            case .null: rc = sqlite3_bind_null(stmt, idx)
            }
            if rc != SQLITE_OK {
                throw DBError(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func colText(_ stmt: OpaquePointer, _ col: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: c)
    }

    private func colOptionalText(_ stmt: OpaquePointer, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL, let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }

    private func colInt(_ stmt: OpaquePointer, _ col: Int32) -> Int {
        Int(sqlite3_column_int64(stmt, col))
    }

    private func colDouble(_ stmt: OpaquePointer, _ col: Int32) -> Double {
        sqlite3_column_double(stmt, col)
    }

    private func colOptionalDouble(_ stmt: OpaquePointer, _ col: Int32) -> Double? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, col)
    }

    private func colBlob(_ stmt: OpaquePointer, _ col: Int32) -> Data {
        guard let ptr = sqlite3_column_blob(stmt, col) else { return Data() }
        let count = Int(sqlite3_column_bytes(stmt, col))
        return Data(bytes: ptr, count: count)
    }

    // MARK: - Library Hierarchy CRUD

    public func checkpointWAL() {
        try? execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    // Upserts, never INSERT OR REPLACE: REPLACE deletes the row first, and the ON DELETE CASCADE / SET NULL
    // foreign keys would wipe or detach every document of a topic or folder that is merely renamed or moved.
    public func saveModule(_ m: LibraryModule) throws {
        try run(
            "INSERT INTO modules (id, name, icon_name, created_at) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name = excluded.name, icon_name = excluded.icon_name",
            [.text(m.id), .text(m.name), .text(m.iconName), .double(m.createdAt)]
        )
    }

    /// Deleting an area keeps its topics (and their documents); they simply lose the area.
    public func deleteModule(id: String) throws {
        try run("UPDATE collections SET module_id = '' WHERE module_id = ?", [.text(id)])
        try run("DELETE FROM modules WHERE id = ?", [.text(id)])
    }

    public func listModules() throws -> [LibraryModule] {
        var result: [LibraryModule] = []
        try query("SELECT id, name, icon_name, created_at FROM modules ORDER BY created_at ASC, name ASC") { stmt in
            result.append(LibraryModule(
                id: colText(stmt, 0),
                name: colText(stmt, 1),
                iconName: colText(stmt, 2),
                createdAt: colDouble(stmt, 3)
            ))
        }
        return result
    }

    public func saveCollection(_ c: LibraryCollection) throws {
        try run(
            "INSERT INTO collections (id, module_id, name, description, created_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET module_id = excluded.module_id, name = excluded.name, description = excluded.description",
            [.text(c.id), .text(c.moduleID), .text(c.name), .text(c.description), .double(c.createdAt)]
        )
    }

    public func deleteCollection(id: String) throws {
        let docs = try listDocuments(collectionID: id)
        for doc in docs {
            try deleteDocument(id: doc.id)
        }
        try run("DELETE FROM watched_folders WHERE collection_id = ?", [.text(id)])
        try run("DELETE FROM collections WHERE id = ?", [.text(id)])
    }

    public func listCollections(moduleID: String? = nil) throws -> [LibraryCollection] {
        var result: [LibraryCollection] = []
        let sql: String
        let binds: [BindValue]
        if let moduleID {
            sql = "SELECT id, module_id, name, description, created_at FROM collections WHERE module_id = ? ORDER BY created_at ASC, name ASC"
            binds = [.text(moduleID)]
        } else {
            sql = "SELECT id, module_id, name, description, created_at FROM collections ORDER BY created_at ASC, name ASC"
            binds = []
        }
        try query(sql, binds) { stmt in
            result.append(LibraryCollection(
                id: colText(stmt, 0),
                moduleID: colText(stmt, 1),
                name: colText(stmt, 2),
                description: colText(stmt, 3),
                createdAt: colDouble(stmt, 4)
            ))
        }
        return result
    }

    public func saveWatchedFolder(_ f: WatchedFolder) throws {
        try run(
            "INSERT INTO watched_folders (id, collection_id, name, path, last_indexed_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET collection_id = excluded.collection_id, name = excluded.name, path = excluded.path, last_indexed_at = excluded.last_indexed_at",
            [
                .text(f.id),
                .text(f.collectionID),
                .text(f.name),
                .text(f.path),
                f.lastIndexedAt.map { .double($0) } ?? .null
            ]
        )
    }

    /// Re-files an indexed document (other topic or folder) without touching its chunks and figures.
    public func moveDocument(id: String, collectionID: String, folderID: String?) throws {
        try run("UPDATE documents SET collection_id = ?, folder_id = ? WHERE id = ?",
                [.text(collectionID), folderID.map { .text($0) } ?? .null, .text(id)])
    }

    /// Updates the file path (and optionally hash/collection/folder) of an already indexed document without re-indexing.
    public func updateDocumentFileLocation(
        id: String,
        filePath: String,
        fileHash: String? = nil,
        collectionID: String? = nil,
        folderID: String? = nil
    ) throws {
        let docs = try listDocuments()
        guard let current = docs.first(where: { $0.id == id }) else { return }
        // If another row already occupies `filePath`, remove that duplicate row first.
        for other in docs where other.id != id && (other.filePath as NSString).standardizingPath == (filePath as NSString).standardizingPath {
            try deleteDocument(id: other.id)
        }
        try run(
            "UPDATE documents SET file_path = ?, file_hash = ?, collection_id = ?, folder_id = ? WHERE id = ?",
            [
                .text(filePath),
                .text(fileHash ?? current.fileHash),
                .text(collectionID ?? current.collectionID),
                (folderID ?? current.folderID).map { .text($0) } ?? .null,
                .text(id)
            ]
        )
    }

    /// Removes duplicate documents (same SHA-256 `file_hash`, or same `(collection_id, normalized title, page_count)` when `page_count > 0`),
    /// keeping the copy with an existing file on disk, the deepest subfolder path, and the most chunks.
    @discardableResult
    public func deduplicateDocuments() throws -> Int {
        let allDocs = try listDocuments()
        guard allDocs.count > 1 else { return 0 }

        func bestOf(_ group: [LibraryDocument]) -> LibraryDocument {
            group.max { a, b in
                let aExists = FileManager.default.fileExists(atPath: a.filePath) ? 1 : 0
                let bExists = FileManager.default.fileExists(atPath: b.filePath) ? 1 : 0
                if aExists != bExists { return aExists < bExists }
                let aDepth = (a.filePath as NSString).standardizingPath.components(separatedBy: "/").count
                let bDepth = (b.filePath as NSString).standardizingPath.components(separatedBy: "/").count
                if aDepth != bDepth { return aDepth < bDepth }
                if a.chunkCount != b.chunkCount { return a.chunkCount < b.chunkCount }
                return (a.indexedAt ?? 0) < (b.indexedAt ?? 0)
            }!
        }

        var removedIDs = Set<String>()

        // 1. Exact SHA-256 content hash duplicates
        let byHash = Dictionary(grouping: allDocs.filter { !$0.fileHash.isEmpty }) { $0.fileHash }
        for (_, group) in byHash where group.count > 1 {
            let keep = bestOf(group)
            for doc in group where doc.id != keep.id {
                removedIDs.insert(doc.id)
            }
        }

        // 2. Same topic + normalized title + page_count > 0 (e.g. Via Medici parent-folder vs. subfolder copies)
        let remaining = allDocs.filter { !removedIDs.contains($0.id) && $0.pageCount > 0 }
        let byTitlePage = Dictionary(grouping: remaining) { doc -> String in
            let normTitle = CortexTextSanitizer.displayTitle(doc.title)
                .precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return "\(doc.collectionID)|\(normTitle)|\(doc.pageCount)"
        }
        for (_, group) in byTitlePage where group.count > 1 {
            let keep = bestOf(group)
            for doc in group where doc.id != keep.id {
                removedIDs.insert(doc.id)
            }
        }

        for id in removedIDs {
            try deleteDocument(id: id)
        }
        return removedIDs.count
    }

    public func deleteWatchedFolder(id: String, deleteDocuments: Bool = true) throws {
        if deleteDocuments {
            let docs = try listDocuments(folderID: id)
            for doc in docs {
                try deleteDocument(id: doc.id)
            }
        }
        try run("DELETE FROM watched_folders WHERE id = ?", [.text(id)])
    }

    public func listWatchedFolders(collectionID: String? = nil) throws -> [WatchedFolder] {
        var result: [WatchedFolder] = []
        let sql = collectionID != nil
            ? "SELECT id, collection_id, name, path, last_indexed_at FROM watched_folders WHERE collection_id = ? ORDER BY name ASC"
            : "SELECT id, collection_id, name, path, last_indexed_at FROM watched_folders ORDER BY name ASC"
        let binds: [BindValue] = collectionID.map { [.text($0)] } ?? []
        try query(sql, binds) { stmt in
            result.append(WatchedFolder(
                id: colText(stmt, 0),
                collectionID: colText(stmt, 1),
                name: colText(stmt, 2),
                path: colText(stmt, 3),
                lastIndexedAt: colOptionalDouble(stmt, 4)
            ))
        }
        return result
    }

    public func upsertDocument(_ d: LibraryDocument) throws {
        let tocData = (try? JSONEncoder().encode(d.toc)) ?? Data("[]".utf8)
        let tocStr = String(data: tocData, encoding: .utf8) ?? "[]"
        try run("""
            INSERT INTO documents (
                id, collection_id, folder_id, title, file_path, file_hash,
                page_count, abstract_summary, toc_json, index_status, engine_used,
                indexed_at, chunk_count, figure_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_path) DO UPDATE SET
                collection_id = excluded.collection_id,
                folder_id = excluded.folder_id,
                title = excluded.title,
                file_hash = excluded.file_hash,
                page_count = excluded.page_count,
                abstract_summary = excluded.abstract_summary,
                toc_json = excluded.toc_json,
                index_status = excluded.index_status,
                engine_used = excluded.engine_used,
                indexed_at = excluded.indexed_at,
                chunk_count = excluded.chunk_count,
                figure_count = excluded.figure_count;
        """, [
            .text(d.id),
            .text(d.collectionID),
            d.folderID.map { .text($0) } ?? .null,
            .text(d.title),
            .text(d.filePath),
            .text(d.fileHash),
            .int(d.pageCount),
            .text(d.abstractSummary),
            .text(tocStr),
            .text(d.indexStatus),
            .text(d.engineUsed),
            d.indexedAt.map { .double($0) } ?? .null,
            .int(d.chunkCount),
            .int(d.figureCount)
        ])
    }

    public func listDocuments(collectionID: String? = nil, folderID: String? = nil) throws -> [LibraryDocument] {
        var clauses: [String] = []
        var binds: [BindValue] = []
        if let collectionID {
            clauses.append("collection_id = ?")
            binds.append(.text(collectionID))
        }
        if let folderID {
            clauses.append("folder_id = ?")
            binds.append(.text(folderID))
        }
        let whereSQL = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let sql = """
            SELECT id, collection_id, folder_id, title, file_path, file_hash,
                   page_count, abstract_summary, toc_json, index_status, engine_used,
                   indexed_at, chunk_count, figure_count
            FROM documents \(whereSQL) ORDER BY title ASC
        """
        var docs: [LibraryDocument] = []
        try query(sql, binds) { stmt in
            let tocJSON = colText(stmt, 8)
            let toc = (try? JSONDecoder().decode([TOCItem].self, from: Data(tocJSON.utf8))) ?? []
            docs.append(LibraryDocument(
                id: colText(stmt, 0),
                collectionID: colText(stmt, 1),
                folderID: colOptionalText(stmt, 2),
                title: colText(stmt, 3),
                filePath: colText(stmt, 4),
                fileHash: colText(stmt, 5),
                pageCount: colInt(stmt, 6),
                abstractSummary: colText(stmt, 7),
                toc: toc,
                indexStatus: colText(stmt, 9),
                engineUsed: colText(stmt, 10),
                indexedAt: colOptionalDouble(stmt, 11),
                chunkCount: colInt(stmt, 12),
                figureCount: colInt(stmt, 13)
            ))
        }
        return docs
    }

    public func deleteDocument(id: String) throws {
        var filePath = ""
        try query("SELECT file_path FROM documents WHERE id = ?", [.text(id)]) { stmt in filePath = colText(stmt, 0) }
        try transaction {
            try run("DELETE FROM chunks_fts WHERE document_id = ?", [.text(id)])
            try run("DELETE FROM figures_fts WHERE document_id = ?", [.text(id)])
            try run("DELETE FROM documents WHERE id = ?", [.text(id)])
        }
        let pageDir = CortexPaths.pagesAssetsDir.appendingPathComponent(id, isDirectory: true)
        let figDir = CortexPaths.figuresAssetsDir.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: pageDir)
        try? FileManager.default.removeItem(at: figDir)
        // PDF rendition of Word/PowerPoint/EPUB originals (the original file itself is never touched).
        if !filePath.isEmpty, !DocumentFormats.isPDF(filePath) {
            try? FileManager.default.removeItem(at: DocumentFormats.convertedPDFURL(forOriginal: filePath))
        }
    }

    public func buildLibraryHierarchy(activeUIScope: ScopeFilter = ScopeFilter()) throws -> [LibraryHierarchyModuleNode] {
        let allModules = try listModules()
        let allCols = try listCollections()
        let allFolders = try listWatchedFolders()
        let allDocs = try listDocuments()

        let selMods = Set(activeUIScope.moduleIDs ?? [])
        let selCols = Set(activeUIScope.collectionIDs ?? [])
        let selFols = Set(activeUIScope.folderIDs ?? [])

        // Topics without an area are listed under a synthetic node with an empty ID.
        let knownModuleIDs = Set(allModules.map(\.id))
        let hasLooseTopics = allCols.contains { !knownModuleIDs.contains($0.moduleID) }
        let moduleNodes = allModules + (hasLooseTopics ? [LibraryModule(id: "", name: "Ohne Bereich")] : [])
        return moduleNodes.map { mod in
            let modCols = allCols.filter { mod.id.isEmpty ? !knownModuleIDs.contains($0.moduleID) : $0.moduleID == mod.id }
            let colNodes: [LibraryHierarchyCollectionNode] = modCols.map { col in
                let colFolders = allFolders.filter { $0.collectionID == col.id }
                let colDocs = allDocs.filter { $0.collectionID == col.id }
                let folderNodes: [LibraryHierarchyFolderNode] = colFolders.map { fol in
                    let fDocs = colDocs.filter { $0.folderID == fol.id }
                    return LibraryHierarchyFolderNode(
                        id: fol.id,
                        collectionID: col.id,
                        name: fol.name,
                        path: fol.path,
                        isSelectedInUI: selFols.contains(fol.id),
                        documents: fDocs
                    )
                }
                let directDocs = colDocs.filter { $0.folderID == nil }
                return LibraryHierarchyCollectionNode(
                    id: col.id,
                    moduleID: mod.id,
                    name: col.name,
                    description: col.description,
                    isSelectedInUI: selCols.contains(col.id),
                    folders: folderNodes,
                    directDocuments: directDocs,
                    totalDocumentCount: colDocs.count
                )
            }
            return LibraryHierarchyModuleNode(
                id: mod.id,
                name: mod.name,
                iconName: mod.iconName,
                isSelectedInUI: selMods.contains(mod.id),
                collections: colNodes
            )
        }
    }

    // MARK: - Transactional Document Index Storage

    public func saveDocumentIndex(
        document: LibraryDocument,
        chunks: [DocumentChunk],
        figures: [DocumentFigure]
    ) throws {
        try transaction {
            var updatedDoc = document
            updatedDoc.chunkCount = chunks.count
            updatedDoc.figureCount = figures.count
            updatedDoc.indexStatus = "indexed"
            updatedDoc.indexedAt = Date().timeIntervalSince1970
            try upsertDocument(updatedDoc)

            // Resolve actual ID in case file_path existed previously
            var docID = updatedDoc.id
            try query("SELECT id FROM documents WHERE file_path = ?", [.text(updatedDoc.filePath)]) { stmt in
                docID = colText(stmt, 0)
            }

            try run("DELETE FROM chunks WHERE document_id = ?", [.text(docID)])
            try run("DELETE FROM chunks_fts WHERE document_id = ?", [.text(docID)])
            try run("DELETE FROM figures WHERE document_id = ?", [.text(docID)])
            try run("DELETE FROM figures_fts WHERE document_id = ?", [.text(docID)])

            for chunk in chunks {
                let embBlob = VectorMath.encodeFloat32Blob(chunk.embedding)
                try run("""
                    INSERT INTO chunks (
                        id, document_id, page_number, chunk_index,
                        prev_chunk_id, next_chunk_id, breadcrumb, content, embedding
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(chunk.id),
                    .text(docID),
                    .int(chunk.pageNumber),
                    .int(chunk.chunkIndex),
                    chunk.prevChunkID.map { .text($0) } ?? .null,
                    chunk.nextChunkID.map { .text($0) } ?? .null,
                    .text(chunk.breadcrumb),
                    .text(chunk.content),
                    .blob(embBlob)
                ])

                try run("""
                    INSERT INTO chunks_fts (chunk_id, document_id, breadcrumb, content)
                    VALUES (?, ?, ?, ?)
                """, [
                    .text(chunk.id),
                    .text(docID),
                    .text(chunk.breadcrumb),
                    .text(chunk.content)
                ])
            }

            for fig in figures {
                let bboxData = (try? JSONEncoder().encode(fig.bbox)) ?? Data("{}".utf8)
                let bboxStr = String(data: bboxData, encoding: .utf8) ?? "{}"
                let visBlob = VectorMath.encodeFloat32Blob(fig.visualEmbedding)
                let capBlob = VectorMath.encodeFloat32Blob(fig.captionEmbedding)

                try run("""
                    INSERT INTO figures (
                        id, document_id, page_number, breadcrumb, figure_label,
                        caption_text, surrounding_context, cropped_image_path,
                        full_page_image_path, bbox_json, visual_embedding, caption_embedding
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [
                    .text(fig.id),
                    .text(docID),
                    .int(fig.pageNumber),
                    .text(fig.breadcrumb),
                    .text(fig.figureLabel),
                    .text(fig.captionText),
                    .text(fig.surroundingContext),
                    .text(fig.croppedImagePath),
                    .text(fig.fullPageImagePath),
                    .text(bboxStr),
                    .blob(visBlob),
                    .blob(capBlob)
                ])

                try run("""
                    INSERT INTO figures_fts (
                        figure_id, document_id, figure_label, caption_text, surrounding_context
                    ) VALUES (?, ?, ?, ?, ?)
                """, [
                    .text(fig.id),
                    .text(docID),
                    .text(fig.figureLabel),
                    .text(fig.captionText),
                    .text(fig.surroundingContext)
                ])
            }
        }
    }

    // MARK: - Scope SQL Builder

    private func buildDocumentScopeSQL(_ scope: ScopeFilter, tableAlias: String = "d") -> (whereClauses: [String], binds: [BindValue]) {
        var clauses: [String] = []
        var binds: [BindValue] = []
        // ID filters of the individual levels. In `matchAnyLevel` mode (desktop checkbox multi-selection)
        // they are OR-combined so that e.g. a collection plus a single PDF of another collection both count.
        var idClauses: [(String, [BindValue])] = []

        func inClause(_ column: String, _ ids: [String]?) {
            guard let ids, !ids.isEmpty else { return }
            let ph = Array(repeating: "?", count: ids.count).joined(separator: ",")
            idClauses.append(("\(column) IN (\(ph))", ids.map { .text($0) }))
        }
        inClause("m.id", scope.moduleIDs)
        inClause("c.id", scope.collectionIDs)
        inClause("\(tableAlias).folder_id", scope.folderIDs)
        inClause("\(tableAlias).id", scope.documentIDs)
        if let prefixes = scope.pathPrefixes, !prefixes.isEmpty {
            let sub = prefixes.map { _ in "substr(\(tableAlias).file_path, 1, length(?)) = ?" }.joined(separator: " OR ")
            idClauses.append(("(\(sub))", prefixes.flatMap { p -> [BindValue] in
                let dir = p.hasSuffix("/") ? p : p + "/"
                return [.text(dir), .text(dir)]
            }))
        }

        if scope.matchAnyLevel == true, !idClauses.isEmpty {
            clauses.append("(" + idClauses.map(\.0).joined(separator: " OR ") + ")")
            for (_, b) in idClauses { binds.append(contentsOf: b) }
        } else {
            for (clause, b) in idClauses {
                clauses.append(clause)
                binds.append(contentsOf: b)
            }
        }

        if let names = scope.moduleNames, !names.isEmpty, scope.matchAnyLevel != true {
            let sub = names.map { _ in "(LOWER(m.id) = LOWER(?) OR LOWER(m.name) LIKE LOWER(?))" }.joined(separator: " OR ")
            clauses.append("(\(sub))")
            for n in names {
                binds.append(.text(n))
                binds.append(.text("%\(n)%"))
            }
        }
        if let names = scope.collectionNames, !names.isEmpty, scope.matchAnyLevel != true {
            let sub = names.map { _ in "(LOWER(c.id) = LOWER(?) OR LOWER(c.name) LIKE LOWER(?))" }.joined(separator: " OR ")
            clauses.append("(\(sub))")
            for n in names {
                binds.append(.text(n))
                binds.append(.text("%\(n)%"))
            }
        }
        let folderTerms = scope.matchAnyLevel == true ? [] : (scope.folderNames ?? []) + (scope.folderPaths ?? [])
        if !folderTerms.isEmpty {
            let sub = folderTerms.map { _ in "(LOWER(COALESCE(wf.id, '')) = LOWER(?) OR LOWER(COALESCE(wf.name, '')) LIKE LOWER(?) OR LOWER(COALESCE(wf.path, '')) LIKE LOWER(?))" }.joined(separator: " OR ")
            clauses.append("(\(sub))")
            for fn in folderTerms {
                binds.append(.text(fn))
                binds.append(.text("%\(fn)%"))
                binds.append(.text("%\(fn)%"))
            }
        }
        if let titles = scope.documentTitles, !titles.isEmpty, scope.matchAnyLevel != true {
            let sub = titles.map { _ in "(LOWER(\(tableAlias).id) = LOWER(?) OR REPLACE(LOWER(\(tableAlias).title), '_', ' ') LIKE LOWER(?) OR LOWER(\(tableAlias).file_path) LIKE LOWER(?))" }.joined(separator: " OR ")
            clauses.append("(\(sub))")
            for t in titles {
                binds.append(.text(t))
                binds.append(.text("%\(t.replacingOccurrences(of: "_", with: " "))%"))
                binds.append(.text("%\(t)%"))
            }
        }
        return (clauses, binds)
    }

    // MARK: - Hybrid Semantic + FTS5 Search with Context Window & Figures

    public func hybridSearch(
        queryText: String,
        queryVector: [Float],
        scope: ScopeFilter = ScopeFilter(),
        contextChunks: Int = 1,
        includeFigures: Bool = true,
        topK: Int = 8,
        lexicalRerank: Bool? = nil
    ) throws -> [SearchResultItem] {
        let (docClauses, docBinds) = buildDocumentScopeSQL(scope, tableAlias: "d")
        var allClauses = docClauses
        var allBinds = docBinds

        if let pStart = scope.pageStart {
            allClauses.append("ch.page_number >= ?")
            allBinds.append(.int(pStart))
        }
        if let pEnd = scope.pageEnd {
            allClauses.append("ch.page_number <= ?")
            allBinds.append(.int(pEnd))
        }

        let whereSQL = allClauses.isEmpty ? "" : "WHERE " + allClauses.joined(separator: " AND ")

        struct CandidateChunk {
            let chunkID: String
            let docID: String
            let docTitle: String
            let docPath: String
            let colID: String
            let colName: String
            let modID: String
            let modName: String
            let pageNumber: Int
            let chunkIndex: Int
            let breadcrumb: String
            let content: String
            var vectorScore: Double
            var keywordScore: Double
        }

        // Ranking needs only id, document, position and the two scores; title, path, breadcrumb and the full text are
        // loaded afterwards for the few ranked chunks. (Building every chunk with its text took ~1 s per search on a
        // 30 000-chunk library; the ranking itself is unchanged.)
        struct LightChunk {
            let chunkID: String
            let docID: String
            let chunkIndex: Int
            let vectorScore: Double
            var keywordScore: Double
        }
        var candidates: [String: LightChunk] = [:]

        // 1. Vector Cosine Pass over scoped chunks
        let sql = """
            SELECT ch.id, ch.document_id, ch.chunk_index, ch.embedding
            FROM chunks ch
            JOIN documents d ON ch.document_id = d.id
            JOIN collections c ON d.collection_id = c.id
            LEFT JOIN modules m ON c.module_id = m.id
            LEFT JOIN watched_folders wf ON d.folder_id = wf.id
            \(whereSQL)
        """
        try query(sql, allBinds) { stmt in
            let cid = colText(stmt, 0)
            let sim = Double(VectorMath.dotProduct(queryVector, colBlob(stmt, 3)))
            candidates[cid] = LightChunk(chunkID: cid, docID: colText(stmt, 1), chunkIndex: colInt(stmt, 2),
                                         vectorScore: sim, keywordScore: 0)
        }

        // 2. FTS5 Keyword BM25 Pass
        if let ftsQuery = makeFTSQuery(queryText), !ftsQuery.isEmpty {
            // No LIMIT here: the scope filter is applied via `candidates`, a global cut-off would
            // otherwise drop every keyword hit inside a narrow scope.
            let ftsSQL = """
                SELECT chunk_id, -bm25(chunks_fts, 1.5, 1.0) AS score
                FROM chunks_fts
                WHERE chunks_fts MATCH ?
            """
            try? query(ftsSQL, [.text(ftsQuery)]) { stmt in
                let cid = colText(stmt, 0)
                let bm25Score = max(0, colDouble(stmt, 1))
                if var existing = candidates[cid] {
                    existing.keywordScore = bm25Score
                    candidates[cid] = existing
                }
            }
        }

        // 3. Reciprocal Rank Fusion (RRF) + Score Normalization
        let settings = CortexSettingsManager.shared.settings
        let denseW = max(0.0, min(1.0, settings.hybridDenseWeight))
        let bm25W = max(0.0, min(1.0, settings.hybridBM25Weight))

        let byVector = candidates.values.sorted { $0.vectorScore > $1.vectorScore }
        let byKeyword = candidates.values.filter { $0.keywordScore > 0 }.sorted { $0.keywordScore > $1.keywordScore }

        var vectorRank: [String: Int] = [:]
        for (i, item) in byVector.enumerated() { vectorRank[item.chunkID] = i + 1 }

        var keywordRank: [String: Int] = [:]
        for (i, item) in byKeyword.enumerated() { keywordRank[item.chunkID] = i + 1 }

        let useLexicalRerank = lexicalRerank ?? settings.enableReranker
        let initialLimit = useLexicalRerank
            ? max(topK, settings.rerankCandidatePoolSize, settings.retrievalTopKPool)
            : max(1, topK)

        let sortedCandidates = candidates.values.map { item -> (LightChunk, Double) in
            let vR = Double(vectorRank[item.chunkID] ?? 1000)
            let rrfV = 1.0 / (40.0 + vR)
            let rrfK: Double
            if let kR = keywordRank[item.chunkID] {
                rrfK = 1.2 / (30.0 + Double(kR))
            } else {
                rrfK = 0.0
            }
            let combined = max(0, item.vectorScore) * denseW + (rrfV + rrfK) * 10.0 * bm25W
            return (item, combined)
        }
        .sorted { $0.1 > $1.1 }

        // Merge neighbouring chunks of the same document (they overlap and repeat each other):
        // keep the best-ranked one and widen its context so the neighbour's text stays visible.
        var rankedLight: [(LightChunk, Double)] = []
        var mergedBefore: [String: Int] = [:]
        var mergedAfter: [String: Int] = [:]
        var mergedCount: [String: Int] = [:]
        for (item, score) in sortedCandidates {
            if let primary = rankedLight.first(where: { $0.0.docID == item.docID && abs($0.0.chunkIndex - item.chunkIndex) <= 1 })?.0 {
                let delta = item.chunkIndex - primary.chunkIndex
                if delta < 0 { mergedBefore[primary.chunkID] = 1 }
                if delta > 0 { mergedAfter[primary.chunkID] = 1 }
                mergedCount[primary.chunkID, default: 0] += 1
                continue
            }
            rankedLight.append((item, score))
            if rankedLight.count >= initialLimit { break }
        }

        // Full rows only for the ranked chunks.
        var details: [String: CandidateChunk] = [:]
        if !rankedLight.isEmpty {
            let ph = Array(repeating: "?", count: rankedLight.count).joined(separator: ",")
            try query("""
                SELECT ch.id, d.title, d.file_path, c.id, c.name, m.id, m.name, ch.page_number, ch.breadcrumb, ch.content
                FROM chunks ch
                JOIN documents d ON ch.document_id = d.id
                JOIN collections c ON d.collection_id = c.id
                LEFT JOIN modules m ON c.module_id = m.id
                WHERE ch.id IN (\(ph))
            """, rankedLight.map { .text($0.0.chunkID) }) { stmt in
                let cid = colText(stmt, 0)
                guard let light = candidates[cid] else { return }
                details[cid] = CandidateChunk(
                    chunkID: cid, docID: light.docID, docTitle: colText(stmt, 1), docPath: colText(stmt, 2),
                    colID: colText(stmt, 3), colName: colText(stmt, 4), modID: colText(stmt, 5), modName: colText(stmt, 6),
                    pageNumber: colInt(stmt, 7), chunkIndex: light.chunkIndex, breadcrumb: colText(stmt, 8),
                    content: colText(stmt, 9), vectorScore: light.vectorScore, keywordScore: light.keywordScore
                )
            }
        }
        let ranked: [(CandidateChunk, Double)] = rankedLight.compactMap { light, score in details[light.chunkID].map { ($0, score) } }

        // 4. Assemble Context Before / After & Page Figures
        var candidateResults: [SearchResultItem] = []
        for (idx, (item, combinedScore)) in ranked.enumerated() {
            let (beforeText, afterText) = try fetchAdjacentChunksText(
                documentID: item.docID,
                chunkIndex: item.chunkIndex,
                before: max(contextChunks, mergedBefore[item.chunkID] ?? 0),
                after: max(contextChunks, mergedAfter[item.chunkID] ?? 0)
            )
            let pageImgPath = CortexPaths.pagesAssetsDir
                .appendingPathComponent(item.docID)
                .appendingPathComponent("page_\(item.pageNumber).png").path
            let figs = includeFigures ? try fetchFiguresOnPage(
                documentID: item.docID,
                documentTitle: item.docTitle,
                documentPath: item.docPath,
                collectionName: item.colName,
                moduleName: item.modName,
                pageNumber: item.pageNumber
            ) : []

            candidateResults.append(SearchResultItem(
                rank: idx + 1,
                score: (combinedScore * 1000).rounded() / 1000,
                vectorScore: (item.vectorScore * 1000).rounded() / 1000,
                keywordScore: (item.keywordScore * 1000).rounded() / 1000,
                chunkID: item.chunkID,
                documentID: item.docID,
                documentTitle: item.docTitle,
                documentPath: item.docPath,
                collectionID: item.colID,
                collectionName: item.colName,
                moduleID: item.modID,
                moduleName: item.modName,
                pageNumber: item.pageNumber,
                breadcrumb: item.breadcrumb,
                contextBefore: beforeText,
                matchedContent: item.content,
                contextAfter: afterText,
                fullPageImagePath: pageImgPath,
                figuresOnPage: figs,
                mergedNeighborCount: mergedCount[item.chunkID]
            ))
        }

        // 5. Optional Cross-Encoder Re-Ranking & Threshold Filtering
        if useLexicalRerank && candidateResults.count > 1 {
            let reranked = CortexRerankerService.rerank(
                query: queryText,
                candidates: candidateResults,
                model: settings.selectedRerankerModel,
                topK: topK,
                minScore: settings.minCosineScore
            )
            if !reranked.isEmpty {
                return reranked
            }
        }

        let thresholdFiltered = candidateResults.filter {
            $0.score >= settings.minCosineScore || $0.vectorScore >= settings.minCosineScore
        }
        let sourceList = thresholdFiltered.isEmpty ? candidateResults : thresholdFiltered
        return Array(sourceList.prefix(max(1, topK))).enumerated().map { idx, item in
            var copy = item
            copy.rank = idx + 1
            return copy
        }
    }

    // MARK: - Dedicated Figure & Diagram Search (Visual + Caption Vector + FTS5)

    public func searchFigures(
        queryText: String,
        queryVector: [Float],
        scope: ScopeFilter = ScopeFilter(),
        topK: Int = 8,
        deduplicateByPage: Bool = true
    ) throws -> [FigureResultItem] {
        let (docClauses, docBinds) = buildDocumentScopeSQL(scope, tableAlias: "d")
        var allClauses = docClauses
        var allBinds = docBinds
        if let pStart = scope.pageStart {
            allClauses.append("f.page_number >= ?")
            allBinds.append(.int(pStart))
        }
        if let pEnd = scope.pageEnd {
            allClauses.append("f.page_number <= ?")
            allBinds.append(.int(pEnd))
        }
        let whereSQL = allClauses.isEmpty ? "" : "WHERE " + allClauses.joined(separator: " AND ")

        var ftsBoosts: [String: Double] = [:]
        if let ftsQuery = makeFTSQuery(queryText), !ftsQuery.isEmpty {
            try? query("""
                SELECT figure_id, -bm25(figures_fts, 2.0, 1.5, 1.0) AS score
                FROM figures_fts WHERE figures_fts MATCH ?
            """, [.text(ftsQuery)]) { stmt in
                ftsBoosts[colText(stmt, 0)] = max(0, colDouble(stmt, 1))
            }
        }

        // Score with ids, page, label and vectors only; titles, captions, context and paths are loaded for the
        // returned figures alone (reading every figure row in full cost most of the search time on large libraries).
        struct LightFigure {
            let id: String
            let docID: String
            let page: Int
            let label: String
            let bboxJSON: String
            let score: Double
        }
        let sql = """
            SELECT f.id, f.document_id, f.page_number, f.figure_label, f.bbox_json, f.visual_embedding, f.caption_embedding
            FROM figures f
            JOIN documents d ON f.document_id = d.id
            JOIN collections c ON d.collection_id = c.id
            LEFT JOIN modules m ON c.module_id = m.id
            LEFT JOIN watched_folders wf ON d.folder_id = wf.id
            \(whereSQL)
        """
        var light: [LightFigure] = []
        try query(sql, allBinds) { stmt in
            let fid = colText(stmt, 0)
            let visSim = Double(VectorMath.dotProduct(queryVector, colBlob(stmt, 5)))
            let capSim = Double(VectorMath.dotProduct(queryVector, colBlob(stmt, 6)))
            let fts = min(0.25, (ftsBoosts[fid] ?? 0) * 0.04)
            // Combine caption semantic similarity, visual vector similarity, and exact keyword match
            let combined = max(visSim, capSim * 0.95) * 0.65 + ((visSim + capSim) * 0.5) * 0.35 + fts
            light.append(LightFigure(id: fid, docID: colText(stmt, 1), page: colInt(stmt, 2), label: colText(stmt, 3),
                                     bboxJSON: colText(stmt, 4), score: (combined * 1000).rounded() / 1000))
        }

        func area(_ json: String) -> Double {
            guard let r = try? JSONDecoder().decode(NormalizedRect.self, from: Data(json.utf8)) else { return 1 }
            return r.width * r.height
        }
        let sorted = light.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let aHasNamedCaption = !a.label.hasPrefix("Abb. S.")
            let bHasNamedCaption = !b.label.hasPrefix("Abb. S.")
            if aHasNamedCaption != bHasNamedCaption { return aHasNamedCaption }
            return area(a.bboxJSON) > area(b.bboxJSON)
        }

        var chosen: [LightFigure] = []
        if deduplicateByPage {
            var seenPages = Set<String>()
            for item in sorted where seenPages.insert("\(item.docID)#\(item.page)").inserted {
                chosen.append(item)
                if chosen.count >= max(1, topK) { break }
            }
        } else {
            chosen = Array(sorted.prefix(max(1, topK)))
        }
        guard !chosen.isEmpty else { return [] }

        var full: [String: FigureResultItem] = [:]
        let ph = Array(repeating: "?", count: chosen.count).joined(separator: ",")
        let scores = Dictionary(uniqueKeysWithValues: chosen.map { ($0.id, $0.score) })
        try query("""
            SELECT f.id, f.document_id, d.title, d.file_path, c.name, m.name,
                   f.page_number, f.breadcrumb, f.figure_label, f.caption_text,
                   f.surrounding_context, f.cropped_image_path, f.full_page_image_path, f.bbox_json
            FROM figures f
            JOIN documents d ON f.document_id = d.id
            JOIN collections c ON d.collection_id = c.id
            LEFT JOIN modules m ON c.module_id = m.id
            WHERE f.id IN (\(ph))
        """, chosen.map { .text($0.id) }) { stmt in
            let fid = colText(stmt, 0)
            let bbox = (try? JSONDecoder().decode(NormalizedRect.self, from: Data(colText(stmt, 13).utf8)))
                ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            full[fid] = FigureResultItem(
                figureID: fid,
                documentID: colText(stmt, 1),
                documentTitle: colText(stmt, 2),
                documentPath: colText(stmt, 3),
                collectionName: colText(stmt, 4),
                moduleName: colText(stmt, 5),
                pageNumber: colInt(stmt, 6),
                breadcrumb: colText(stmt, 7),
                label: colText(stmt, 8),
                caption: colText(stmt, 9),
                surroundingContext: colText(stmt, 10),
                croppedImagePath: colText(stmt, 11),
                fullPageImagePath: colText(stmt, 12),
                bbox: bbox,
                score: scores[fid] ?? 0
            )
        }
        return chosen.compactMap { full[$0.id] }
    }

    // MARK: - Figure caption maintenance

    /// Figures without a real caption ("Abb. S.N-k"), with what is needed to re-derive and re-embed their caption.
    public struct UncaptionedFigure: Sendable {
        public let id: String
        public let documentTitle: String
        public let documentPath: String
        public let pageNumber: Int
        public let bbox: NormalizedRect
        public let label: String
        public let caption: String
        public let context: String
        /// The visual vector is the caption vector (image vectors were off when it was indexed).
        public let visualIsCaption: Bool
    }

    public func listUncaptionedFigures() throws -> [UncaptionedFigure] {
        var out: [UncaptionedFigure] = []
        try query("""
            SELECT f.id, d.title, d.file_path, f.page_number, f.bbox_json, f.figure_label, f.caption_text,
                   f.surrounding_context, f.visual_embedding = f.caption_embedding
            FROM figures f JOIN documents d ON d.id = f.document_id
            WHERE f.figure_label LIKE 'Abb. S.%'
            ORDER BY d.file_path, f.page_number
        """) { stmt in
            let bbox = (try? JSONDecoder().decode(NormalizedRect.self, from: Data(colText(stmt, 4).utf8)))
                ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            out.append(UncaptionedFigure(id: colText(stmt, 0), documentTitle: colText(stmt, 1), documentPath: colText(stmt, 2),
                                         pageNumber: colInt(stmt, 3), bbox: bbox, label: colText(stmt, 5),
                                         caption: colText(stmt, 6), context: colText(stmt, 7), visualIsCaption: colInt(stmt, 8) == 1))
        }
        return out
    }

    /// Replaces a figure's caption, its keyword-index entry and its caption vector (and the visual vector where that
    /// was only a copy of the caption vector).
    public func updateFigureCaption(id: String, caption: String, captionVector: [Float], visualIsCaption: Bool) throws {
        let blob = VectorMath.encodeFloat32Blob(captionVector)
        try transaction {
            try run("UPDATE figures SET caption_text = ?, caption_embedding = ? WHERE id = ?", [.text(caption), .blob(blob), .text(id)])
            if visualIsCaption {
                try run("UPDATE figures SET visual_embedding = ? WHERE id = ?", [.blob(blob), .text(id)])
            }
            try run("UPDATE figures_fts SET caption_text = ? WHERE figure_id = ?", [.text(caption), .text(id)])
        }
    }

    // MARK: - Context Expansion & Overview

    public func fetchAdjacentChunksText(documentID: String, chunkIndex: Int, radius: Int) throws -> (before: String, after: String) {
        try fetchAdjacentChunksText(documentID: documentID, chunkIndex: chunkIndex, before: radius, after: radius)
    }

    public func fetchAdjacentChunksText(documentID: String, chunkIndex: Int, before: Int, after: Int) throws -> (before: String, after: String) {
        let bCount = max(0, before)
        let aCount = max(0, after)
        guard bCount > 0 || aCount > 0 else { return ("", "") }
        var beforeParts: [String] = []
        var afterParts: [String] = []
        try query("""
            SELECT chunk_index, content FROM chunks
            WHERE document_id = ? AND chunk_index BETWEEN ? AND ?
            ORDER BY chunk_index ASC
        """, [.text(documentID), .int(chunkIndex - bCount), .int(chunkIndex + aCount)]) { stmt in
            let idx = colInt(stmt, 0)
            let text = colText(stmt, 1)
            if idx < chunkIndex { beforeParts.append(text) }
            else if idx > chunkIndex { afterParts.append(text) }
        }
        return (beforeParts.joined(separator: "\n\n"), afterParts.joined(separator: "\n\n"))
    }

    public func expandChunkContext(chunkID: String, before: Int = 2, after: Int = 2) throws -> SearchResultItem? {
        if chunkID.hasPrefix("fig:") || chunkID.hasPrefix("fig_") {
            let rawFigID = chunkID.hasPrefix("fig:") ? String(chunkID.dropFirst(4)) : chunkID
            if let figItem = try expandFigureContext(figureID: rawFigID, before: before, after: after) {
                return figItem
            }
        }

        var found: (docID: String, docTitle: String, docPath: String, colID: String, colName: String, modID: String, modName: String, page: Int, idx: Int, breadcrumb: String, content: String)?
        try query("""
            SELECT ch.document_id, d.title, d.file_path, c.id, c.name, m.id, m.name,
                   ch.page_number, ch.chunk_index, ch.breadcrumb, ch.content
            FROM chunks ch
            JOIN documents d ON ch.document_id = d.id
            JOIN collections c ON d.collection_id = c.id
            LEFT JOIN modules m ON c.module_id = m.id
            WHERE ch.id = ?
        """, [.text(chunkID)]) { stmt in
            found = (
                colText(stmt, 0), colText(stmt, 1), colText(stmt, 2),
                colText(stmt, 3), colText(stmt, 4), colText(stmt, 5), colText(stmt, 6),
                colInt(stmt, 7), colInt(stmt, 8), colText(stmt, 9), colText(stmt, 10)
            )
        }
        guard let f = found else { return nil }
        let (bText, aText) = try fetchAdjacentChunksText(documentID: f.docID, chunkIndex: f.idx, before: before, after: after)
        let pageImgPath = CortexPaths.pagesAssetsDir.appendingPathComponent(f.docID).appendingPathComponent("page_\(f.page).png").path
        let figs = try fetchFiguresOnPage(
            documentID: f.docID,
            documentTitle: f.docTitle,
            documentPath: f.docPath,
            collectionName: f.colName,
            moduleName: f.modName,
            pageNumber: f.page
        )
        return SearchResultItem(
            rank: 1,
            score: 1.0,
            vectorScore: 1.0,
            keywordScore: 1.0,
            chunkID: chunkID,
            documentID: f.docID,
            documentTitle: f.docTitle,
            documentPath: f.docPath,
            collectionID: f.colID,
            collectionName: f.colName,
            moduleID: f.modID,
            moduleName: f.modName,
            pageNumber: f.page,
            breadcrumb: f.breadcrumb,
            contextBefore: bText,
            matchedContent: f.content,
            contextAfter: aText,
            fullPageImagePath: pageImgPath,
            figuresOnPage: figs
        )
    }

    private func expandFigureContext(figureID: String, before: Int, after: Int) throws -> SearchResultItem? {
        var foundFig: (
            fig: FigureResultItem,
            colID: String,
            modID: String
        )?
        try query("""
            SELECT f.id, f.document_id, d.title, d.file_path, c.id, c.name, m.id, m.name,
                   f.page_number, f.breadcrumb, f.figure_label, f.caption_text,
                   f.surrounding_context, f.cropped_image_path, f.full_page_image_path, f.bbox_json
            FROM figures f
            JOIN documents d ON f.document_id = d.id
            JOIN collections c ON d.collection_id = c.id
            LEFT JOIN modules m ON c.module_id = m.id
            WHERE f.id = ?
        """, [.text(figureID)]) { stmt in
            let bboxStr = colText(stmt, 15)
            let bbox = (try? JSONDecoder().decode(NormalizedRect.self, from: Data(bboxStr.utf8)))
                ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            let item = FigureResultItem(
                figureID: colText(stmt, 0),
                documentID: colText(stmt, 1),
                documentTitle: colText(stmt, 2),
                documentPath: colText(stmt, 3),
                collectionName: colText(stmt, 5),
                moduleName: colText(stmt, 7),
                pageNumber: colInt(stmt, 8),
                breadcrumb: colText(stmt, 9),
                label: colText(stmt, 10),
                caption: colText(stmt, 11),
                surroundingContext: colText(stmt, 12),
                croppedImagePath: colText(stmt, 13),
                fullPageImagePath: colText(stmt, 14),
                bbox: bbox,
                score: 1.0
            )
            foundFig = (item, colText(stmt, 4), colText(stmt, 6))
        }
        guard let matched = foundFig else { return nil }
        let fig = matched.fig
        let allFigsOnPage = try fetchFiguresOnPage(
            documentID: fig.documentID,
            documentTitle: fig.documentTitle,
            documentPath: fig.documentPath,
            collectionName: fig.collectionName,
            moduleName: fig.moduleName,
            pageNumber: fig.pageNumber
        )

        // Find chunk indices on this page to gather contextBefore and contextAfter
        var pageChunkIndices: [Int] = []
        var pageChunkTexts: [String] = []
        try query("""
            SELECT chunk_index, content FROM chunks
            WHERE document_id = ? AND page_number = ?
            ORDER BY chunk_index ASC
        """, [.text(fig.documentID), .int(fig.pageNumber)]) { stmt in
            pageChunkIndices.append(colInt(stmt, 0))
            pageChunkTexts.append(colText(stmt, 1))
        }

        var bText = ""
        var aText = ""
        if let firstIdx = pageChunkIndices.first, let lastIdx = pageChunkIndices.last {
            let (beforePart, _) = try fetchAdjacentChunksText(documentID: fig.documentID, chunkIndex: firstIdx, before: before, after: 0)
            let (_, afterPart) = try fetchAdjacentChunksText(documentID: fig.documentID, chunkIndex: lastIdx, before: 0, after: after)
            bText = beforePart
            aText = afterPart
        }

        var result = SearchResultItem(
            figureHit: fig,
            rank: 1,
            score: 1.0,
            collectionID: matched.colID,
            moduleID: matched.modID,
            allFiguresOnPage: allFigsOnPage
        )
        result.contextBefore = bText
        if !pageChunkTexts.isEmpty {
            result.matchedContent = ([fig.label + ": " + fig.caption] + pageChunkTexts).joined(separator: "\n\n")
        }
        result.contextAfter = aText
        return result
    }

    public func fetchFiguresOnPage(
        documentID: String,
        documentTitle: String,
        documentPath: String,
        collectionName: String,
        moduleName: String,
        pageNumber: Int? = nil
    ) throws -> [FigureResultItem] {
        var sql = """
            SELECT id, page_number, breadcrumb, figure_label, caption_text,
                   surrounding_context, cropped_image_path, full_page_image_path, bbox_json
            FROM figures WHERE document_id = ?
        """
        var binds: [BindValue] = [.text(documentID)]
        if let pageNumber {
            sql += " AND page_number = ?"
            binds.append(.int(pageNumber))
        }
        sql += " ORDER BY page_number ASC, id ASC"

        var list: [FigureResultItem] = []
        try query(sql, binds) { stmt in
            let bboxStr = colText(stmt, 8)
            let bbox = (try? JSONDecoder().decode(NormalizedRect.self, from: Data(bboxStr.utf8)))
                ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
            list.append(FigureResultItem(
                figureID: colText(stmt, 0),
                documentID: documentID,
                documentTitle: documentTitle,
                documentPath: documentPath,
                collectionName: collectionName,
                moduleName: moduleName,
                pageNumber: colInt(stmt, 1),
                breadcrumb: colText(stmt, 2),
                label: colText(stmt, 3),
                caption: colText(stmt, 4),
                surroundingContext: colText(stmt, 5),
                croppedImagePath: colText(stmt, 6),
                fullPageImagePath: colText(stmt, 7),
                bbox: bbox,
                score: 1.0
            ))
        }
        return list
    }

    public func getDocumentOverview(titleOrID: String) throws -> DocumentOverviewPayload? {
        var match: (LibraryDocument, String, String)?
        let sql = """
            SELECT d.id, d.collection_id, d.folder_id, d.title, d.file_path, d.file_hash,
                   d.page_count, d.abstract_summary, d.toc_json, d.index_status, d.engine_used,
                   d.indexed_at, d.chunk_count, d.figure_count, c.name, m.name
            FROM documents d
            JOIN collections c ON d.collection_id = c.id
            LEFT JOIN modules m ON c.module_id = m.id
            WHERE d.id = ? OR REPLACE(LOWER(d.title), '_', ' ') LIKE LOWER(?) OR LOWER(d.file_path) LIKE LOWER(?)
            ORDER BY (d.id = ?) DESC, LENGTH(d.title) ASC
            LIMIT 1
        """
        let spaced = titleOrID.replacingOccurrences(of: "_", with: " ")
        try query(sql, [.text(titleOrID), .text("%\(spaced)%"), .text("%\(titleOrID)%"), .text(titleOrID)]) { stmt in
            let tocJSON = colText(stmt, 8)
            let toc = (try? JSONDecoder().decode([TOCItem].self, from: Data(tocJSON.utf8))) ?? []
            let doc = LibraryDocument(
                id: colText(stmt, 0),
                collectionID: colText(stmt, 1),
                folderID: colOptionalText(stmt, 2),
                title: colText(stmt, 3),
                filePath: colText(stmt, 4),
                fileHash: colText(stmt, 5),
                pageCount: colInt(stmt, 6),
                abstractSummary: colText(stmt, 7),
                toc: toc,
                indexStatus: colText(stmt, 9),
                engineUsed: colText(stmt, 10),
                indexedAt: colOptionalDouble(stmt, 11),
                chunkCount: colInt(stmt, 12),
                figureCount: colInt(stmt, 13)
            )
            match = (doc, colText(stmt, 14), colText(stmt, 15))
        }
        guard let (doc, colName, modName) = match else { return nil }
        let figs = try fetchFiguresOnPage(
            documentID: doc.id,
            documentTitle: doc.title,
            documentPath: doc.filePath,
            collectionName: colName,
            moduleName: modName,
            pageNumber: nil
        )
        return DocumentOverviewPayload(document: doc, collectionName: colName, moduleName: modName, figures: figs)
    }

    // MARK: - Document Reader Access

    public struct ChunkLocator: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var pageNumber: Int
        public var chunkIndex: Int
        public var breadcrumb: String
        public var content: String
    }

    /// All chunks of a document in reading order (used by the reader's section list).
    public func listChunks(documentID: String) throws -> [ChunkLocator] {
        var list: [ChunkLocator] = []
        try query("""
            SELECT id, page_number, chunk_index, breadcrumb, content FROM chunks
            WHERE document_id = ? ORDER BY chunk_index ASC
        """, [.text(documentID)]) { stmt in
            list.append(ChunkLocator(
                id: colText(stmt, 0),
                pageNumber: colInt(stmt, 1),
                chunkIndex: colInt(stmt, 2),
                breadcrumb: colText(stmt, 3),
                content: colText(stmt, 4)
            ))
        }
        return list
    }

    /// Indexed text of a page range, grouped by page (chunk overlap is not removed).
    public func readPages(documentID: String, from start: Int, to end: Int) throws -> [(page: Int, text: String)] {
        var byPage: [Int: [String]] = [:]
        try query("""
            SELECT page_number, content FROM chunks
            WHERE document_id = ? AND page_number BETWEEN ? AND ?
            ORDER BY chunk_index ASC
        """, [.text(documentID), .int(start), .int(end)]) { stmt in
            byPage[colInt(stmt, 0), default: []].append(colText(stmt, 1))
        }
        return byPage.keys.sorted().map { ($0, byPage[$0]!.joined(separator: "\n\n")) }
    }

    // MARK: - Agent Telemetry Logging

    public func logAgentEvent(_ event: AgentActivityEvent) throws {
        try run("""
            INSERT INTO agent_events (
                id, timestamp, source, operation, query, scope_summary,
                result_count, figure_count, latency_ms, engine_used
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(event.id),
            .double(event.timestamp),
            .text(event.source),
            .text(event.operation),
            .text(event.query),
            .text(event.scopeSummary),
            .int(event.resultCount),
            .int(event.figureCount),
            .double(event.latencyMs),
            .text(event.engineUsed)
        ])
        // Keep the activity log bounded (only the newest entries are ever shown).
        if Int.random(in: 0..<50) == 0 {
            try? run("DELETE FROM agent_events WHERE id NOT IN (SELECT id FROM agent_events ORDER BY timestamp DESC LIMIT 1000)")
        }
    }

    public func listAgentEvents(limit: Int = 50) throws -> [AgentActivityEvent] {
        var events: [AgentActivityEvent] = []
        try query("""
            SELECT id, timestamp, source, operation, query, scope_summary,
                   result_count, figure_count, latency_ms, engine_used
            FROM agent_events ORDER BY timestamp DESC LIMIT ?
        """, [.int(limit)]) { stmt in
            events.append(AgentActivityEvent(
                id: colText(stmt, 0),
                timestamp: colDouble(stmt, 1),
                source: colText(stmt, 2),
                operation: colText(stmt, 3),
                query: colText(stmt, 4),
                scopeSummary: colText(stmt, 5),
                resultCount: colInt(stmt, 6),
                figureCount: colInt(stmt, 7),
                latencyMs: colDouble(stmt, 8),
                engineUsed: colText(stmt, 9)
            ))
        }
        return events
    }

    private func makeFTSQuery(_ raw: String) -> String? {
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}
