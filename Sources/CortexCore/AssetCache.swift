import Foundation

/// Figure crops and page images are a cache: every file can be regenerated from the PDF on demand
/// (`PDFVisionPipeline.ensureCroppedFigureExists`, page rendering in the UI). This keeps the cache bounded.
public enum AssetCache {
    /// Upper bound for crops + page images together.
    public static let defaultMaxBytes: Int64 = 300 * 1024 * 1024

    /// Deletes the least recently used files until the folders together hold at most `maxBytes`.
    /// "Used" is the modification date, which `touch(_:)` refreshes whenever a cached file is reused.
    @discardableResult
    public static func prune(maxBytes: Int64 = defaultMaxBytes,
                             directories: [URL] = [CortexPaths.figuresAssetsDir, CortexPaths.pagesAssetsDir]) -> (removed: Int, freedBytes: Int64) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        var files: [(url: URL, size: Int64, date: Date)] = []
        for dir in directories {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { continue }
            while let url = e.nextObject() as? URL {
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                files.append((url, Int64(v.fileSize ?? 0), v.contentModificationDate ?? .distantPast))
            }
        }
        var total = files.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxBytes else { return (0, 0) }
        var removed = 0
        var freed: Int64 = 0
        for f in files.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            if (try? FileManager.default.removeItem(at: f.url)) != nil {
                total -= f.size
                freed += f.size
                removed += 1
            }
        }
        // Empty per-document folders are left behind by the deletions.
        for dir in directories {
            for sub in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where ((try? FileManager.default.contentsOfDirectory(atPath: sub.path)) ?? ["x"]).isEmpty {
                try? FileManager.default.removeItem(at: sub)
            }
        }
        return (removed, freed)
    }

    /// Marks a cached file as recently used.
    public static func touch(_ path: String) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path)
    }
}
