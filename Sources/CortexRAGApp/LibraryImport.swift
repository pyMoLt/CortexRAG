import Foundation
import Observation
import PDFKit
import CortexCore
import CortexIPC
import CortexVision

// MARK: - What was dropped or chosen

/// Dropped or chosen items, expanded to documents (PDF, Word, PowerPoint …). Files are only linked, never copied.
struct ImportPlan: Equatable {
    struct Folder: Equatable {
        let url: URL
        let pdfs: [URL]
        /// Number of subfolders that contain PDFs (shown in the import dialog).
        let subfolderCount: Int
    }

    var looseFiles: [URL] = []
    var folders: [Folder] = []
    /// Items that are neither supported documents nor folders.
    var ignoredCount = 0
    /// Number of duplicate files skipped during plan creation.
    var duplicateCount = 0

    var pdfCount: Int { looseFiles.count + folders.reduce(0) { $0 + $1.pdfs.count } }
    var isEmpty: Bool { pdfCount == 0 }

    static func make(from urls: [URL]) -> ImportPlan {
        var plan = ImportPlan()
        var seenPaths = Set<String>()
        var seenFolders = Set<String>()
        var seenHashes = Set<String>()

        for rawURL in urls {
            let url = rawURL.resolvingSymlinksInPath().standardizedFileURL
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { plan.ignoredCount += 1; continue }
            if isDir.boolValue {
                let folderPath = (url.path as NSString).standardizingPath
                guard seenFolders.insert(folderPath).inserted else {
                    plan.duplicateCount += 1
                    continue
                }
                let rawPDFs = collectPDFs(in: url)
                var uniquePDFs: [URL] = []
                for pdf in rawPDFs {
                    let std = (pdf.path as NSString).standardizingPath
                    guard seenPaths.insert(std).inserted else {
                        plan.duplicateCount += 1
                        continue
                    }
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: pdf.path)[.size] as? Int) ?? 0
                    if fileSize >= 64, let hash = try? PDFVisionPipeline.computeSHA256(of: pdf), !hash.isEmpty {
                        guard seenHashes.insert(hash).inserted else {
                            plan.duplicateCount += 1
                            continue
                        }
                    }
                    uniquePDFs.append(pdf)
                }
                // Every folder between the imported folder and a PDF counts (also folders that only hold folders).
                var dirs = Set<String>()
                for pdf in uniquePDFs {
                    var dir = pdf.deletingLastPathComponent()
                    while dir.path.count > url.path.count, dir.path.hasPrefix(url.path + "/") {
                        dirs.insert(dir.path)
                        dir = dir.deletingLastPathComponent()
                    }
                }
                let subfolders = dirs.count
                plan.folders.append(Folder(url: url, pdfs: uniquePDFs, subfolderCount: subfolders))
            } else if DocumentFormats.isSupported(url) {
                let std = (url.path as NSString).standardizingPath
                guard seenPaths.insert(std).inserted else {
                    plan.duplicateCount += 1
                    continue
                }
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if fileSize >= 64, let hash = try? PDFVisionPipeline.computeSHA256(of: url), !hash.isEmpty {
                    guard seenHashes.insert(hash).inserted else {
                        plan.duplicateCount += 1
                        continue
                    }
                }
                plan.looseFiles.append(url)
            } else {
                plan.ignoredCount += 1
            }
        }
        return plan
    }

    static func collectPDFs(in folder: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var candidates: [URL] = []
        while let item = e.nextObject() as? URL {
            // Office lock files ("~$Vorlesung.pptx") are not documents.
            if DocumentFormats.isSupported(item), !item.lastPathComponent.hasPrefix("~$") {
                candidates.append(item.resolvingSymlinksInPath().standardizedFileURL)
            }
        }
        // Deduplicate parent-folder vs. subfolder copies with the same filename & page count (preferring the deepest subfolder path).
        let byName = Dictionary(grouping: candidates) {
            $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased()
        }
        var kept: [URL] = []
        for (_, group) in byName {
            if group.count == 1 {
                kept.append(group[0])
                continue
            }
            // Sort deepest path first
            let sortedByDepth = group.sorted {
                $0.pathComponents.count > $1.pathComponents.count
            }
            var accepted: [(url: URL, dir: String, pages: Int)] = []
            for cand in sortedByDepth {
                let dir = (cand.deletingLastPathComponent().path as NSString).standardizingPath.precomposedStringWithCanonicalMapping
                let pages = PDFDocument(url: cand)?.pageCount ?? 0
                let isRedundantAncestorCopy = accepted.contains { deeper in
                    (deeper.dir == dir || deeper.dir.hasPrefix(dir + "/")) && (pages == 0 || deeper.pages == pages)
                }
                if !isRedundantAncestorCopy {
                    accepted.append((cand, dir, pages))
                }
            }
            kept.append(contentsOf: accepted.map(\.url))
        }
        return kept.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

// MARK: - Where it should go

/// Target area ("Bereich") and topic ("Thema") of an import.
struct ImportTarget: Equatable {
    enum Area: Equatable { case none, existing(String), new(String) }
    enum Topic: Equatable { case existing(String), new(String) }
    var area: Area
    var topic: Topic
}

enum ImportSuggester {
    /// Folding for name comparison: case, diacritics and separators do not matter ("Distributed_WS25" ~ "distributed ws25").
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Readable topic name from a folder name: "VL_Systems-WS25" → "VL Systems WS25".
    static func displayName(forFolder name: String) -> String {
        let repaired = CortexTextSanitizer.repairEncoding(name)
        return repaired.replacingOccurrences(of: "_", with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Matches path components of the imported items against existing topics, then areas; the deepest
    /// matching folder wins. Without a match a new topic named after the folder is proposed.
    static func suggest(plan: ImportPlan, modules: [LibraryModule], collections: [LibraryCollection]) -> ImportTarget {
        let roots = plan.folders.map(\.url) + plan.looseFiles.map { $0.deletingLastPathComponent() }
        let componentLists = roots.map { url in url.pathComponents.filter { $0 != "/" }.map(normalize) }

        func depthOfMatch(_ name: String) -> Int? {
            let n = normalize(name)
            guard n.count >= 3 else { return nil }
            var best: Int?
            for comps in componentLists {
                for (i, c) in comps.enumerated() where c == n || (n.count >= 5 && c.contains(n)) {
                    best = max(best ?? -1, i)
                }
            }
            return best
        }

        if let topic = collections.compactMap({ c in depthOfMatch(c.name).map { (c, $0) } }).max(by: { $0.1 < $1.1 })?.0 {
            let area: ImportTarget.Area = modules.contains(where: { $0.id == topic.moduleID }) ? .existing(topic.moduleID) : .none
            return ImportTarget(area: area, topic: .existing(topic.id))
        }
        let area: ImportTarget.Area = modules.compactMap { m in depthOfMatch(m.name).map { (m, $0) } }
            .max(by: { $0.1 < $1.1 }).map { .existing($0.0.id) } ?? .none
        let baseName: String = {
            if plan.folders.count == 1, plan.looseFiles.isEmpty { return plan.folders[0].url.lastPathComponent }
            if let first = roots.first { return first.lastPathComponent }
            return "Neues Thema"
        }()
        return ImportTarget(area: area, topic: .new(displayName(forFolder: baseName)))
    }
}

// MARK: - Queue

/// Sequential indexing queue with per-file state, pause, resume, cancel and retry. One document at a time keeps memory flat.
@MainActor
@Observable
final class ImportQueue {
    enum State: Equatable {
        case waiting, running, done, unchanged, cancelled
        case failed(String)

        var isFinished: Bool { self != .waiting && self != .running }
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let topicID: String
        let folderID: String?
        let force: Bool
        var state: State = .waiting
        var detail = ""

        var title: String { CortexTextSanitizer.displayTitle(url.deletingPathExtension().lastPathComponent) }
    }

    private(set) var jobs: [Job] = []
    private(set) var isRunning = false
    private(set) var isPaused = false

    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let service: CortexService
    @ObservationIgnored var engine: () -> EngineKind = { .llamaMetal }
    /// Called after every finished document (library refresh).
    @ObservationIgnored var onDocumentFinished: () -> Void = {}
    /// Called when the queue runs empty: (indexed, failed).
    @ObservationIgnored var onQueueFinished: (Int, Int) -> Void = { _, _ in }

    init(service: CortexService) {
        self.service = service
    }

    var waitingCount: Int { jobs.filter { $0.state == .waiting }.count }
    var failedJobs: [Job] { jobs.filter { if case .failed = $0.state { return true } else { return false } } }
    var finishedCount: Int { jobs.filter(\.state.isFinished).count }
    var current: Job? { jobs.first { $0.state == .running } }
    var hasVisibleJobs: Bool { !jobs.isEmpty }
    var isEffectivelyPaused: Bool {
        isPaused || (current?.detail.hasPrefix("Pausiert") == true)
    }

    /// Adds files; a path or content hash that is already waiting or running is not queued twice.
    func enqueue(_ items: [(url: URL, topicID: String, folderID: String?)], force: Bool = false) {
        var activePaths = Set(jobs.filter { !$0.state.isFinished }.map { ($0.url.path as NSString).standardizingPath })
        var activeHashes = Set<String>()
        for job in jobs where !job.state.isFinished {
            if let h = try? PDFVisionPipeline.computeSHA256(of: job.url), !h.isEmpty { activeHashes.insert(h) }
        }

        var newJobs: [Job] = []
        for item in items {
            let stdURL = item.url.resolvingSymlinksInPath().standardizedFileURL
            let stdPath = (stdURL.path as NSString).standardizingPath
            guard activePaths.insert(stdPath).inserted else { continue }
            if !force, let h = try? PDFVisionPipeline.computeSHA256(of: stdURL), !h.isEmpty {
                guard activeHashes.insert(h).inserted else { continue }
            }
            newJobs.append(Job(url: stdURL, topicID: item.topicID, folderID: item.folderID, force: force))
        }
        guard !newJobs.isEmpty else { return }
        // Finished entries of earlier runs are dropped when a new run starts.
        if !isRunning { jobs.removeAll { $0.state.isFinished } }
        jobs += newJobs
        startIfNeeded()
    }

    func pause() {
        guard isRunning else { return }
        isPaused = true
        PowerManager.shared.setManuallyPaused(true)
        if let cur = current {
            update(cur.id) { $0.detail = "Pausiert – Manuell" }
        }
    }

    func resume() {
        isPaused = false
        PowerManager.shared.setManuallyPaused(false)
        // If paused because of battery, also allow continuing on battery with the configured battery speed.
        if PowerManager.shared.isOnBattery(), AppViewModel.shared?.settings.indexOnlyOnACPower == true {
            AppViewModel.shared?.settings.indexOnlyOnACPower = false
        }
        if let cur = current, cur.detail.hasPrefix("Pausiert") {
            update(cur.id) { $0.detail = "Fortgesetzt …" }
        }
    }

    func togglePause() {
        if isEffectivelyPaused {
            resume()
        } else {
            pause()
        }
    }

    func resumeOnBattery(mode: IndexingThrottleMode) {
        AppViewModel.shared?.settings.batteryThrottlingMode = mode
        AppViewModel.shared?.settings.indexOnlyOnACPower = false
        resume()
    }

    func cancelAll() {
        isPaused = false
        PowerManager.shared.requestCancelAllIndexing()
        for i in jobs.indices where jobs[i].state == .waiting || jobs[i].state == .running {
            jobs[i].state = .cancelled
            jobs[i].detail = ""
        }
        runner?.cancel()
    }

    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].state == .running {
            let path = jobs[i].url.path
            jobs[i].state = .cancelled
            jobs[i].detail = ""
            PowerManager.shared.requestCancelDocument(path: path)
        } else if jobs[i].state == .waiting {
            jobs[i].state = .cancelled
            jobs[i].detail = ""
        }
    }

    func retryFailed() {
        let retry = failedJobs
        jobs.removeAll { if case .failed = $0.state { return true } else { return false } }
        enqueue(retry.map { ($0.url, $0.topicID, $0.folderID) }, force: true)
    }

    func clearFinished() {
        jobs.removeAll { $0.state.isFinished }
    }

    private func update(_ id: UUID, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func startIfNeeded() {
        guard runner == nil else { return }
        isRunning = true
        runner = Task { [weak self] in
            var indexed = 0, failed = 0
            while let self, !Task.isCancelled, let job = self.jobs.first(where: { $0.state == .waiting }) {
                self.update(job.id) {
                    $0.state = .running
                    $0.detail = self.isPaused ? "Pausiert – Manuell" : ""
                }
                let stdPath = (job.url.path as NSString).standardizingPath
                // An unchanged or duplicate file keeps its index timestamp (it is only skipped or re-filed).
                let before = (try? self.service.db.listDocuments())?.first(where: { ($0.filePath as NSString).standardizingPath == stdPath })?.indexedAt
                let hasMoreWaiting = self.jobs.contains { $0.id != job.id && $0.state == .waiting }
                let nextJob = self.jobs.first { $0.id != job.id && $0.state == .waiting }
                var skippedDuplicate = false
                do {
                    let doc = try await self.service.indexPDF(
                        at: job.url, collectionID: job.topicID, folderID: job.folderID,
                        engineKind: self.engine(), force: job.force, keepVisionLoaded: hasMoreWaiting,
                        prefetchNext: nextJob.map { ($0.url, $0.topicID, $0.folderID) }
                    ) { [weak self] msg in
                        if msg.hasPrefix("Duplikat") || msg.hasPrefix("Unverändert") {
                            Task { @MainActor [weak self] in
                                self?.update(job.id) { $0.detail = ImportQueue.shortDetail(msg) }
                            }
                        } else {
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                if self.isPaused && !msg.hasPrefix("Pausiert") { return }
                                self.update(job.id) { $0.detail = ImportQueue.shortDetail(msg) }
                            }
                        }
                    }
                    let unchanged = (before != nil && doc.indexedAt == before)
                        || ((doc.filePath as NSString).standardizingPath != stdPath)
                    skippedDuplicate = unchanged
                    self.update(job.id) {
                        if $0.state == .running {
                            $0.state = skippedDuplicate ? .unchanged : .done
                            $0.detail = ""
                        }
                    }
                    if !skippedDuplicate { indexed += 1 }
                } catch {
                    if error is CancellationError || Task.isCancelled {
                        self.update(job.id) { $0.state = .cancelled; $0.detail = "" }
                    } else {
                        failed += 1
                        self.update(job.id) { $0.state = .failed("\(error)"); $0.detail = "" }
                    }
                }
                self.onDocumentFinished()
            }
            guard let self else { return }
            if Task.isCancelled {
                for i in self.jobs.indices where self.jobs[i].state == .waiting || self.jobs[i].state == .running {
                    self.jobs[i].state = .cancelled
                    self.jobs[i].detail = ""
                }
            }
            if !self.jobs.contains(where: { $0.state == .waiting }) {
                await self.service.discardPrefetches()
                await self.service.unloadVisionTowerIfLoaded()
            }
            self.isPaused = false
            PowerManager.shared.setManuallyPaused(false)
            self.runner = nil
            self.isRunning = false
            self.onQueueFinished(indexed, failed)
            // Items queued while the last document was finishing.
            if self.jobs.contains(where: { $0.state == .waiting }) { self.startIfNeeded() }
        }
    }

    /// Pipeline messages are long ("Analysiere PDF 'X' Seite 5/40 (Vision & Layout)..."); the row only needs the step.
    nonisolated static func shortDetail(_ msg: String) -> String {
        if let r = msg.range(of: #"Seite \d+/\d+"#, options: .regularExpression) { return String(msg[r]) }
        if msg.contains("Text-Embeddings") { return "Text-Vektoren" }
        if msg.contains("Ganzseiten-Bild") || msg.contains("Ausschnitt-Bild") || msg.contains("Vision-Embedding") || msg.contains("Bild- & Caption") { return "Bild-Vektoren" }
        if msg.contains("Caption-Embeddings") { return "Abbildungen" }
        if msg.hasPrefix("Duplikat") { return "Duplikat übersprungen" }
        if msg.hasPrefix("Unverändert") { return "Unverändert" }
        if msg.hasPrefix("Starte") { return "Startet" }
        if msg.hasPrefix("Pausiert") {
            if msg.contains("Manuell") { return "Pausiert – Manuell" }
            if msg.contains("Akku") { return "Pausiert – Akku" }
            return "Pausiert – Stromsparmodus"
        }
        return String(msg.prefix(40))
    }
}

// MARK: - Folder tree (sidebar)

/// Subfolder tree of an imported folder, derived from the document paths (no extra database table).
struct FolderTreeNode: Identifiable, Equatable {
    var id: String { path }
    let path: String
    let name: String
    var children: [FolderTreeNode]
    var documents: [LibraryDocument]

    var totalDocumentCount: Int { documents.count + children.reduce(0) { $0 + $1.totalDocumentCount } }
    var allDocuments: [LibraryDocument] { documents + children.flatMap(\.allDocuments) }

    static func build(root: WatchedFolder, documents: [LibraryDocument]) -> FolderTreeNode {
        let rootPath = (root.path as NSString).standardizingPath
        var node = FolderTreeNode(path: rootPath, name: ImportSuggester.displayName(forFolder: root.name), children: [], documents: [])
        for doc in documents {
            let dir = ((doc.filePath as NSString).deletingLastPathComponent as NSString).standardizingPath
            guard dir == rootPath || dir.hasPrefix(rootPath + "/") else {
                node.documents.append(doc)
                continue
            }
            let rel = dir == rootPath ? [] : String(dir.dropFirst(rootPath.count + 1)).components(separatedBy: "/")
            node.insert(doc, at: rel[...], base: rootPath)
        }
        node.sortRecursively()
        return node
    }

    private mutating func insert(_ doc: LibraryDocument, at rel: ArraySlice<String>, base: String) {
        guard let head = rel.first else { documents.append(doc); return }
        let childPath = base + "/" + head
        if let i = children.firstIndex(where: { $0.path == childPath }) {
            children[i].insert(doc, at: rel.dropFirst(), base: childPath)
        } else {
            var child = FolderTreeNode(path: childPath, name: ImportSuggester.displayName(forFolder: head), children: [], documents: [])
            child.insert(doc, at: rel.dropFirst(), base: childPath)
            children.append(child)
        }
    }

    private mutating func sortRecursively() {
        children.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        documents.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for i in children.indices { children[i].sortRecursively() }
    }

    /// True if the node or anything below it matches the sidebar filter.
    func matches(_ filter: String) -> Bool {
        name.localizedCaseInsensitiveContains(filter)
            || documents.contains { CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(filter) }
            || children.contains { $0.matches(filter) }
    }
}
