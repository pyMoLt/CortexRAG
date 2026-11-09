import XCTest
@testable import CortexCore

final class AssetCacheTests: XCTestCase {
    func testPruneRemovesOldestUntilUnderLimitAndEmptyFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cortex_cache_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let figs = root.appendingPathComponent("Figures"), pages = root.appendingPathComponent("Pages")
        let data = Data(repeating: 1, count: 1000)
        var paths: [URL] = []
        for (i, dir) in ["Figures/docA", "Figures/docB", "Pages/docA"].enumerated() {
            let d = root.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for j in 0..<2 {
                let f = d.appendingPathComponent("f\(j).png")
                try data.write(to: f)
                // Oldest first: docA crops, then docB crops, then page images.
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(-1000 + i * 100 + j))], ofItemAtPath: f.path)
                paths.append(f)
            }
        }
        AssetCache.touch(paths[0].path)   // recently used again → must survive
        let result = AssetCache.prune(maxBytes: 3000, directories: [figs, pages])
        XCTAssertEqual(result.removed, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths[0].path), "touched file stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths[1].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: figs.appendingPathComponent("docB").path), "empty folder removed")
        XCTAssertEqual(AssetCache.prune(maxBytes: 3000, directories: [figs, pages]).removed, 0, "already under the limit")
    }
}
