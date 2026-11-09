import XCTest
@testable import CortexCore
@testable import CortexRAGApp

final class ImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cortex_import_\(UUID().uuidString)")
        // Courses/Systems_WS25/{VL1.pdf, Woche 2/VL2.pdf, Woche 2/notes.png, Skripte/S.pdf}
        for rel in ["Courses/Systems_WS25/VL1.pdf", "Courses/Systems_WS25/Woche 2/VL2.pdf",
                    "Courses/Systems_WS25/Woche 2/notes.png", "Courses/Systems_WS25/Skripte/S.pdf", "Courses/Einzeln.pdf"] {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testPlanExpandsFoldersRecursivelyAndIgnoresOtherFiles() {
        let folder = root.appendingPathComponent("Courses/Systems_WS25")
        let plan = ImportPlan.make(from: [folder, root.appendingPathComponent("Courses/Einzeln.pdf"),
                                          root.appendingPathComponent("Courses/Systems_WS25/Woche 2/notes.png")])
        XCTAssertEqual(plan.folders.count, 1)
        XCTAssertEqual(plan.folders[0].pdfs.map(\.lastPathComponent).sorted(), ["S.pdf", "VL1.pdf", "VL2.pdf"])
        XCTAssertEqual(plan.folders[0].subfolderCount, 2)
        let parent = ImportPlan.make(from: [root.appendingPathComponent("Courses")])
        XCTAssertEqual(parent.folders[0].subfolderCount, 3, "Systems_WS25, Woche 2, Skripte")
        XCTAssertEqual(plan.looseFiles.map(\.lastPathComponent), ["Einzeln.pdf"])
        XCTAssertEqual(plan.ignoredCount, 1)
        XCTAssertEqual(plan.pdfCount, 4)
    }

    func testSuggestionMatchesExistingTopicByFolderName() {
        let plan = ImportPlan.make(from: [root.appendingPathComponent("Courses/Systems_WS25")])
        let inf = LibraryModule(id: "m", name: "Informatik")
        let topics = [LibraryCollection(id: "db", moduleID: "m", name: "Databases"),
                      LibraryCollection(id: "sys", moduleID: "m", name: "Systems")]
        let t = ImportSuggester.suggest(plan: plan, modules: [inf], collections: topics)
        XCTAssertEqual(t, ImportTarget(area: .existing("m"), topic: .existing("sys")))
    }

    func testSuggestionProposesNewTopicFromFolderName() {
        let plan = ImportPlan.make(from: [root.appendingPathComponent("Courses/Systems_WS25")])
        let t = ImportSuggester.suggest(plan: plan, modules: [], collections: [])
        XCTAssertEqual(t, ImportTarget(area: .none, topic: .new("Systems WS25")))
    }

    func testSuggestionUsesAreaWhenOnlyAreaMatches() {
        let plan = ImportPlan.make(from: [root.appendingPathComponent("Courses/Systems_WS25")])
        let t = ImportSuggester.suggest(plan: plan, modules: [LibraryModule(id: "u", name: "Courses")], collections: [])
        XCTAssertEqual(t, ImportTarget(area: .existing("u"), topic: .new("Systems WS25")))
    }

    func testFolderTreeMirrorsDiskStructure() {
        let base = "/Data/Systems"
        let folder = WatchedFolder(id: "f", collectionID: "t", name: "Systems", path: base)
        let docs = [
            LibraryDocument(id: "a", collectionID: "t", folderID: "f", title: "VL1", filePath: base + "/VL1.pdf", pageCount: 1),
            LibraryDocument(id: "b", collectionID: "t", folderID: "f", title: "VL2", filePath: base + "/Woche 2/VL2.pdf", pageCount: 1),
            LibraryDocument(id: "c", collectionID: "t", folderID: "f", title: "Deep", filePath: base + "/Woche 2/Extra/D.pdf", pageCount: 1),
        ]
        let tree = FolderTreeNode.build(root: folder, documents: docs)
        XCTAssertEqual(tree.documents.map(\.id), ["a"])
        XCTAssertEqual(tree.children.map(\.name), ["Woche 2"])
        XCTAssertEqual(tree.children[0].documents.map(\.id), ["b"])
        XCTAssertEqual(tree.children[0].children.map(\.path), [base + "/Woche 2/Extra"])
        XCTAssertEqual(tree.totalDocumentCount, 3)
        XCTAssertTrue(tree.matches("deep"))
        XCTAssertFalse(tree.matches("Quantum"))
    }

    func testShortDetailKeepsOnlyTheStep() {
        XCTAssertEqual(ImportQueue.shortDetail("Analysiere PDF 'X' Seite 5/40 (Vision & Layout)..."), "Seite 5/40")
        XCTAssertEqual(ImportQueue.shortDetail("Berechne Text-Embeddings (12 Abschnitte, 768D) mit llama"), "Text-Vektoren")
    }
}
