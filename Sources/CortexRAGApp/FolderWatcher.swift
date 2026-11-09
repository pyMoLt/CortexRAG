import Foundation
import CoreServices
import CortexCore

/// Watches the imported lecture folders with FSEvents (event-driven, no polling) and reports which
/// folders changed. Bursts of file events (copying many PDFs) are coalesced by the stream latency.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private let onChange: @Sendable ([String]) -> Void

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    /// (Re)starts watching exactly these folders. Passing an empty list stops the watcher.
    func watch(_ folders: [String]) {
        let unique = Array(Set(folders.filter { FileManager.default.fileExists(atPath: $0) })).sorted()
        guard unique != paths || stream == nil else { return }
        stop()
        paths = unique
        guard !unique.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            let pdfRelated = changed.filter { DocumentFormats.isSupported(URL(fileURLWithPath: $0)) || !$0.contains(".") }
            guard count > 0, !pdfRelated.isEmpty else { return }
            // FSEvents reports resolved paths (/private/tmp for /tmp, targets of symlinked folders).
            let roots = Set(watcher.paths.filter { root in
                let real = FolderWatcher.realPath(root)
                return pdfRelated.contains { $0.hasPrefix(root + "/") || $0.hasPrefix(real + "/") || $0 == root || $0 == real }
            })
            if !roots.isEmpty { watcher.onChange(Array(roots)) }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf)
        // 10 s latency: copying a whole lecture folder produces one batch instead of dozens.
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, unique as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 10.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue(label: "CortexRAG.FolderWatcher", qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    /// Physical path (`realpath`); Foundation's symlink resolution maps /private/tmp back to /tmp.
    static func realPath(_ path: String) -> String {
        guard let p = realpath(path, nil) else { return path }
        defer { free(p) }
        return String(cString: p)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
