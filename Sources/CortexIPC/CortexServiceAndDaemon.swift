import Foundation
import Darwin
import PDFKit
import CortexCore
import CortexEmbedders
import CortexVision

// MARK: - IPC Protocol Payloads

public enum IPCRequestAction: String, Codable, Sendable {
    case status
    case search
    case figures
    case pageFigures
    case expand
    case documentOverview
    case indexPDF
    case indexFolder
    case switchEngine
    case setScope
    case benchmark
    case readPages
}

public struct PageTextPayload: Codable, Sendable {
    public var documentID: String
    public var documentTitle: String
    public var documentPath: String
    public var pageCount: Int
    public var pages: [PageText]

    public struct PageText: Codable, Sendable {
        public var page: Int
        public var text: String
        public init(page: Int, text: String) {
            self.page = page
            self.text = text
        }
    }

    public init(documentID: String, documentTitle: String, documentPath: String, pageCount: Int, pages: [PageText]) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.documentPath = documentPath
        self.pageCount = pageCount
        self.pages = pages
    }
}

public struct IPCRequest: Codable, Sendable {
    public var action: IPCRequestAction
    public var source: String // "cli" or "mcp"
    public var query: String?
    public var scope: ScopeFilter?
    public var contextChunks: Int?
    public var includeFigures: Bool?
    public var content: SearchContentMode?
    public var topK: Int?
    public var chunkID: String?
    public var beforeChunks: Int?
    public var afterChunks: Int?
    public var documentQuery: String?
    public var pageNumber: Int?
    public var cropIfMissing: Bool?
    public var path: String?
    public var collectionID: String?
    public var collectionName: String?
    public var engine: EngineKind?
    public var force: Bool?

    public var chunkGranularity: String?
    public var maxCharsPerChunk: Int?
    public var minScore: Double?

    public init(
        action: IPCRequestAction,
        source: String = "cli",
        query: String? = nil,
        scope: ScopeFilter? = nil,
        contextChunks: Int? = nil,
        includeFigures: Bool? = nil,
        content: SearchContentMode? = nil,
        topK: Int? = nil,
        chunkID: String? = nil,
        beforeChunks: Int? = nil,
        afterChunks: Int? = nil,
        documentQuery: String? = nil,
        pageNumber: Int? = nil,
        cropIfMissing: Bool? = nil,
        path: String? = nil,
        collectionID: String? = nil,
        collectionName: String? = nil,
        engine: EngineKind? = nil,
        force: Bool? = nil,
        chunkGranularity: String? = nil,
        maxCharsPerChunk: Int? = nil,
        minScore: Double? = nil
    ) {
        self.force = force
        self.action = action
        self.source = source
        self.query = query
        self.scope = scope
        self.contextChunks = contextChunks
        self.includeFigures = includeFigures
        self.content = content
        self.topK = topK
        self.chunkID = chunkID
        self.beforeChunks = beforeChunks
        self.afterChunks = afterChunks
        self.documentQuery = documentQuery
        self.pageNumber = pageNumber
        self.cropIfMissing = cropIfMissing
        self.path = path
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.engine = engine
        self.chunkGranularity = chunkGranularity
        self.maxCharsPerChunk = maxCharsPerChunk
        self.minScore = minScore
    }
}

public struct DaemonStatusPayload: Codable, Sendable {
    public var daemonActive: Bool
    public var socketPath: String
    public var activeEngine: String
    public var activeEngineKind: EngineKind
    public var isTextTowerLoaded: Bool
    public var isVisionTowerLoaded: Bool
    public var memoryMB: Double
    public var activeUIScope: ScopeFilter
    public var enforceUIScopeForAgents: Bool
    public var agentGuidance: String
    public var hierarchy: [LibraryHierarchyModuleNode]
    public var modules: [LibraryModule]
    public var collections: [LibraryCollection]
    public var watchedFolders: [WatchedFolder]
    public var documents: [LibraryDocument]

    public init(
        daemonActive: Bool,
        socketPath: String,
        activeEngine: String,
        activeEngineKind: EngineKind,
        isTextTowerLoaded: Bool,
        isVisionTowerLoaded: Bool,
        memoryMB: Double,
        activeUIScope: ScopeFilter,
        enforceUIScopeForAgents: Bool,
        agentGuidance: String,
        hierarchy: [LibraryHierarchyModuleNode],
        modules: [LibraryModule],
        collections: [LibraryCollection],
        watchedFolders: [WatchedFolder],
        documents: [LibraryDocument]
    ) {
        self.daemonActive = daemonActive
        self.socketPath = socketPath
        self.activeEngine = activeEngine
        self.activeEngineKind = activeEngineKind
        self.isTextTowerLoaded = isTextTowerLoaded
        self.isVisionTowerLoaded = isVisionTowerLoaded
        self.memoryMB = memoryMB
        self.activeUIScope = activeUIScope
        self.enforceUIScopeForAgents = enforceUIScopeForAgents
        self.agentGuidance = agentGuidance
        self.hierarchy = hierarchy
        self.modules = modules
        self.collections = collections
        self.watchedFolders = watchedFolders
        self.documents = documents
    }
}

public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var status: DaemonStatusPayload?
    public var searchResponse: SearchResponsePayload?
    public var figureResponse: FigureSearchResponsePayload?
    public var expandedItem: SearchResultItem?
    public var documentOverview: DocumentOverviewPayload?
    public var indexedDocument: LibraryDocument?
    public var benchmarkReport: EngineBenchmarkReport?
    public var pageText: PageTextPayload?

    public init(
        ok: Bool,
        error: String? = nil,
        status: DaemonStatusPayload? = nil,
        searchResponse: SearchResponsePayload? = nil,
        figureResponse: FigureSearchResponsePayload? = nil,
        expandedItem: SearchResultItem? = nil,
        documentOverview: DocumentOverviewPayload? = nil,
        indexedDocument: LibraryDocument? = nil,
        benchmarkReport: EngineBenchmarkReport? = nil,
        pageText: PageTextPayload? = nil
    ) {
        self.ok = ok
        self.error = error
        self.status = status
        self.searchResponse = searchResponse
        self.figureResponse = figureResponse
        self.expandedItem = expandedItem
        self.documentOverview = documentOverview
        self.indexedDocument = indexedDocument
        self.benchmarkReport = benchmarkReport
        self.pageText = pageText
    }
}

// MARK: - Core Orchestration Service

public actor CortexService {
    nonisolated public let db: CortexDatabase
    private let llamaBackend: LlamaCppMetalBackend
    private let mlxBackend: MLXSwiftBackend
    public private(set) var activeEngineKind: EngineKind
    public private(set) var activeUIScope: ScopeFilter = ScopeFilter()
    public private(set) var enforceUIScopeForAgents: Bool = true
    private var lastActivityDate: Date = Date()
    private var neuralReranker: LlamaReranker?
    private var neuralRerankerKind: NeuralRerankerModel = .none
    /// Turbo mode overlaps documents: while the GPU embeds document N, the next document is already analysed
    /// (rendering + Vision OCR, which run on CPU and Neural Engine). Keyed by standardized path.
    private var prefetched: [String: (id: String, task: Task<ExtractedDocumentPackage, Error>)] = [:]

    public init(
        database: CortexDatabase? = nil,
        defaultEngine: EngineKind = .llamaMetal
    ) throws {
        self.db = try database ?? CortexDatabase()
        self.llamaBackend = LlamaCppMetalBackend()
        self.mlxBackend = MLXSwiftBackend()
        self.activeEngineKind = defaultEngine
    }

    public func updateUIScope(_ scope: ScopeFilter, enforceForAgents: Bool? = nil) {
        self.activeUIScope = scope
        if let enforceForAgents {
            self.enforceUIScopeForAgents = enforceForAgents
        }
    }

    /// Resolves which part of the library a CLI/MCP request searches:
    /// explicit filters win; `use_ui_selection=true` uses the app's checkbox selection (optionally with a page range);
    /// without filters the app selection is used when "sync with CLI & MCP" is enabled; otherwise everything.
    public func resolveEffectiveScope(_ requested: ScopeFilter?) -> ScopeFilter {
        if let req = requested {
            if req.useUISelection == true {
                var ui = activeUIScope
                ui.pageStart = req.pageStart ?? ui.pageStart
                ui.pageEnd = req.pageEnd ?? ui.pageEnd
                ui.useUISelection = true
                return ui
            }
            if !req.isEmpty {
                return req
            }
            if req.useUISelection == false {
                return ScopeFilter()
            }
        }
        if enforceUIScopeForAgents && !activeUIScope.isEmpty {
            return activeUIScope
        }
        return ScopeFilter()
    }

    public func setEngine(_ kind: EngineKind) async throws {
        _ = try await ensureExclusiveEngine(kind)
    }

    @discardableResult
    private func ensureExclusiveEngine(_ kind: EngineKind) async throws -> any EmbeddingBackend {
        if activeEngineKind != kind {
            await llamaBackend.unloadAll()
            await mlxBackend.unloadAll()
            activeEngineKind = kind
        } else {
            switch kind {
            case .llamaMetal:
                let mlxText = await mlxBackend.isTextLoaded
                let mlxVision = await mlxBackend.isVisionLoaded
                if mlxText || mlxVision {
                    await mlxBackend.unloadAll()
                }
            case .mlxSwift:
                let llamaText = await llamaBackend.isTextLoaded
                let llamaVision = await llamaBackend.isVisionLoaded
                if llamaText || llamaVision {
                    await llamaBackend.unloadAll()
                }
            }
        }
        let target = currentBackend
        try await target.loadTextTowerOnly()
        return target
    }

    public var currentBackend: any EmbeddingBackend {
        switch activeEngineKind {
        case .llamaMetal: return llamaBackend
        case .mlxSwift: return mlxBackend
        }
    }

    public func warmUpTextDaemon() async throws {
        lastActivityDate = Date()
        _ = try await ensureExclusiveEngine(activeEngineKind)
    }

    /// Automatically unloads models when idle if aggressive idle memory mode is configured, achieving 0 Watt GPU idle power
    public func checkAndPerformIdleCleanup() async {
        let settings = CortexSettingsManager.shared.settings
        guard settings.idleMemoryMode == .aggressiveUnloadOnIdle else { return }
        let idleSec = Date().timeIntervalSince(lastActivityDate)
        if idleSec >= Double(settings.idleTimeoutMinutes * 60) {
            let llamaText = await llamaBackend.isTextLoaded
            let llamaVis = await llamaBackend.isVisionLoaded
            let mlxText = await mlxBackend.isTextLoaded
            let mlxVis = await mlxBackend.isVisionLoaded
            if llamaText || llamaVis || mlxText || mlxVis {
                await llamaBackend.unloadAll()
                await mlxBackend.unloadAll()
            }
            await unloadNeuralReranker()
        }
    }

    /// Unloads all models from Unified Memory / GPU, resets runtime state, and checkpoints SQLite WAL.
    public func shutdown() async {
        await unloadNeuralReranker()
        await llamaBackend.unloadAll()
        await mlxBackend.unloadAll()
        activeUIScope = ScopeFilter()
        db.checkpointWAL()
    }

    /// Unloads the Vision/mmproj tower after a batch import finishes while keeping the fast text tower ready.
    public func unloadVisionTowerIfLoaded() async {
        await llamaBackend.unloadVisionTower()
        await mlxBackend.unloadVisionTower()
    }

    // MARK: - Indexing Pipeline (PDF + Vision Figure Cropping + Dual Embeddings)

    public func indexPDF(
        at fileURL: URL,
        collectionID: String,
        folderID: String? = nil,
        engineKind: EngineKind? = nil,
        force: Bool = false,
        keepVisionLoaded: Bool = false,
        prefetchNext: (url: URL, collectionID: String, folderID: String?)? = nil,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> LibraryDocument {
        let stdPath = (fileURL.path as NSString).standardizingPath
        // Analysis prepared while the previous document was being embedded (Turbo). Discarded if this call returns
        // early (unchanged, duplicate, moved) or fails before using it.
        let pre = prefetched.removeValue(forKey: stdPath)
        var usedPrefetch = false
        defer { if let pre, !usedPrefetch { Self.discard(pre, ownedByIndexedDocument: isIndexedDocument(pre.id)) } }
        let cancelGen = PowerManager.shared.currentCancelGeneration
        PowerManager.shared.clearCancelledDocument(path: stdPath)
        try await PowerManager.shared.waitUntilIndexingAllowedAsync(generation: cancelGen, path: stdPath, progress: progress)

        let fileHash = (try? PDFVisionPipeline.computeSHA256(of: fileURL)) ?? ""
        let docs = try db.listDocuments()
        var existingID = UUID().uuidString
        var wasAlreadyIndexed = false

        // 1. Check same path
        if let pre { existingID = pre.id }
        if let found = docs.first(where: { ($0.filePath as NSString).standardizingPath == stdPath }) {
            existingID = found.id
            wasAlreadyIndexed = (found.indexStatus == "indexed")
            if !force, found.indexStatus == "indexed", !found.fileHash.isEmpty, !fileHash.isEmpty, fileHash == found.fileHash {
                if found.collectionID != collectionID || found.folderID != folderID {
                    try db.moveDocument(id: found.id, collectionID: collectionID, folderID: folderID)
                    progress?("Verschoben: \(CortexTextSanitizer.displayTitle(found.title))")
                    return try db.listDocuments().first(where: { $0.id == found.id }) ?? found
                }
                progress?("Unverändert, übersprungen: \(CortexTextSanitizer.displayTitle(found.title))")
                return found
            }
        } else if !force {
            // 2. Check duplicate content by SHA-256 hash across the library
            if !fileHash.isEmpty,
               let dup = docs.first(where: { $0.indexStatus == "indexed" && $0.fileHash == fileHash }) {
                let dupStd = (dup.filePath as NSString).standardizingPath
                let dupExists = FileManager.default.fileExists(atPath: dup.filePath)
                let newDepth = stdPath.components(separatedBy: "/").count
                let oldDepth = dupStd.components(separatedBy: "/").count
                if !dupExists || (dup.collectionID == collectionID && newDepth > oldDepth) {
                    try db.updateDocumentFileLocation(
                        id: dup.id, filePath: fileURL.path, fileHash: fileHash,
                        collectionID: collectionID, folderID: folderID
                    )
                    progress?("Duplikat aktualisiert: \(CortexTextSanitizer.displayTitle(dup.title))")
                    return try db.listDocuments().first(where: { $0.id == dup.id }) ?? dup
                }
                progress?("Duplikat übersprungen: \(CortexTextSanitizer.displayTitle(dup.title))")
                return dup
            }

            // 3. Check duplicate article within the same topic (same normalized title + same PDF page count)
            let candidateNormTitle = CortexTextSanitizer.displayTitle(fileURL.deletingPathExtension().lastPathComponent)
                .precomposedStringWithCanonicalMapping
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let readablePath = DocumentFormats.readablePDFPath(for: fileURL.path)
            let candidatePages = PDFDocument(url: URL(fileURLWithPath: readablePath))?.pageCount ?? 0
            if candidatePages > 0,
               let dup = docs.first(where: {
                   $0.collectionID == collectionID
                       && $0.indexStatus == "indexed"
                       && $0.pageCount == candidatePages
                       && CortexTextSanitizer.displayTitle($0.title)
                           .precomposedStringWithCanonicalMapping
                           .trimmingCharacters(in: .whitespacesAndNewlines)
                           .lowercased() == candidateNormTitle
               }) {
                let dupStd = (dup.filePath as NSString).standardizingPath
                let newDepth = stdPath.components(separatedBy: "/").count
                let oldDepth = dupStd.components(separatedBy: "/").count
                if !FileManager.default.fileExists(atPath: dup.filePath) || newDepth > oldDepth {
                    try db.updateDocumentFileLocation(
                        id: dup.id, filePath: fileURL.path, fileHash: fileHash,
                        collectionID: collectionID, folderID: folderID
                    )
                    progress?("Duplikat aktualisiert: \(CortexTextSanitizer.displayTitle(dup.title))")
                    return try db.listDocuments().first(where: { $0.id == dup.id }) ?? dup
                }
                progress?("Duplikat übersprungen: \(CortexTextSanitizer.displayTitle(dup.title))")
                return dup
            }
        }

        let docPagesDir = CortexPaths.pagesAssetsDir.appendingPathComponent(existingID, isDirectory: true)
        let docFiguresDir = CortexPaths.figuresAssetsDir.appendingPathComponent(existingID, isDirectory: true)

        do {
            let chosenEngine = try await ensureExclusiveEngine(engineKind ?? activeEngineKind)
            let eName = await chosenEngine.engineKind.rawValue

            progress?("Starte PDF- & Apple-Vision-Analyse für \(fileURL.lastPathComponent)...")
            // Word, PowerPoint & co. are analysed through their cached PDF rendition; the document keeps the original path.
            var pkg: ExtractedDocumentPackage
            if let pre, pre.id == existingID, let ready = try? await pre.task.value {
                usedPrefetch = true
                pkg = ready
                pkg.document.collectionID = collectionID
                pkg.document.folderID = folderID
                progress?("Vorab analysiert: \(fileURL.lastPathComponent)")
                if ProcessInfo.processInfo.environment["CORTEXRAG_DEBUG_DIR"] != nil {
                    fputs("prefetch-used: \(fileURL.lastPathComponent)\n", stderr)
                }
            } else {
                pkg = try await Self.analyse(fileURL: fileURL, documentID: existingID, collectionID: collectionID,
                                             folderID: folderID, progress: progress)
            }
            // Turbo: the GPU is busy with this document's vectors from here on; analyse the next one meanwhile.
            if let next = prefetchNext, PowerManager.shared.activeThrottlingMode() == .turbo {
                startPrefetch(next.url, collectionID: next.collectionID, folderID: next.folderID)
            }
            pkg.document.engineUsed = eName

            let settings = CortexSettingsManager.shared.settings
            let dim = settings.embeddingDimension

            // 1. Embed Text Chunks in batches so Pause / Cancel / Throttling react immediately
            progress?("Berechne Text-Embeddings (\(pkg.chunks.count) Abschnitte, \(dim.rawValue)D) mit \(await chosenEngine.engineName)...")
            try await chosenEngine.loadTextTowerOnly()
            if !pkg.chunks.isEmpty {
                let batchSize = 16
                var start = 0
                while start < pkg.chunks.count {
                    try await PowerManager.shared.waitUntilIndexingAllowedAsync(generation: cancelGen, path: stdPath, progress: progress)
                    let end = min(pkg.chunks.count, start + batchSize)
                    let sliceInputs = pkg.chunks[start..<end].map {
                        (title: Optional(pkg.document.title), body: "\($0.breadcrumb)\n\($0.content)")
                    }
                    let workStart = Date()
                    let vectors = try await chosenEngine.embedDocuments(sliceInputs, dimension: dim)
                    for i in 0..<min(end - start, vectors.count) {
                        pkg.chunks[start + i].embedding = vectors[i]
                    }
                    start = end
                    if start < pkg.chunks.count {
                        await PowerManager.shared.applyDutyCycle(afterWork: Date().timeIntervalSince(workStart))
                    }
                }
            }

            // 2. Embed cropped figures according to settings.imageVectorMode:
            //    - .adaptive (default): embed full slide/page image for lecture slides/sparse pages (< 900 chars),
            //      and contextual figure crop (bbox + immediate surroundings/caption) for inline figures in scripts/textbooks.
            //    - .fullPage: embed full slide/page image once per page with figures.
            //    - .cropsOnly: embed each cropped figure with its immediate surroundings individually.
            //    - .disabled: caption vector only (Vision tower stays unloaded).
            var finalFigures: [DocumentFigure] = []
            if !pkg.figureCandidates.isEmpty {
                try await PowerManager.shared.waitUntilIndexingAllowedAsync(generation: cancelGen, path: stdPath, progress: progress)
                let captionInputs = pkg.figureCandidates.map {
                    (title: Optional(pkg.document.title), body: "\($0.figureLabel): \($0.captionText). \($0.surroundingContext)")
                }
                let captionVectors = try await chosenEngine.embedDocuments(captionInputs, dimension: dim)
                let vectorMode = settings.imageVectorsEnabled ? settings.imageVectorMode : .disabled

                switch vectorMode {
                case .disabled:
                    progress?("Berechne Caption-Embeddings (Text-Only-Modus, \(dim.rawValue)D) für \(pkg.figureCandidates.count) Abbildungen...")
                    for (i, cand) in pkg.figureCandidates.enumerated() {
                        let capVec = i < captionVectors.count ? captionVectors[i] : []
                        finalFigures.append(DocumentFigure(
                            id: cand.id,
                            documentID: cand.documentID,
                            pageNumber: cand.pageNumber,
                            breadcrumb: cand.breadcrumb,
                            figureLabel: cand.figureLabel,
                            captionText: cand.captionText,
                            surroundingContext: cand.surroundingContext,
                            croppedImagePath: cand.croppedImagePath,
                            fullPageImagePath: cand.fullPageImagePath,
                            bbox: cand.bbox,
                            visualEmbedding: capVec,
                            captionEmbedding: capVec
                        ))
                    }

                case .adaptive, .fullPage:
                    let modeLabel = vectorMode == .adaptive ? "Adaptiv (Folie komplett · Skript-Bild mit Umfeld)" : "Ganzseiten-Modus"
                    progress?("Berechne Bild- & Caption-Embeddings (\(modeLabel)) für \(pkg.figureCandidates.count) Abbildungen...")
                    try await chosenEngine.loadVisionTower()
                    var pageVisualVectors: [Int: [Float]] = [:]

                    for (i, cand) in pkg.figureCandidates.enumerated() {
                        try await PowerManager.shared.waitUntilIndexingAllowedAsync(generation: cancelGen, path: stdPath, progress: progress)
                        let capVec = i < captionVectors.count ? captionVectors[i] : []
                        let useFullPage = (vectorMode == .fullPage) || cand.isSlideOrSparsePage
                        let visVec: [Float]
                        if useFullPage {
                            if let cached = pageVisualVectors[cand.pageNumber] {
                                visVec = cached
                            } else {
                                progress?("Vision-Embedding (Folie/Seite S. \(cand.pageNumber)) für Abbildung \(i + 1)/\(pkg.figureCandidates.count)...")
                                let workStart = Date()
                                if let pageImg = cand.loadFullPageImage() ?? cand.loadImage(),
                                   let v = try? await chosenEngine.embedCGImage(pageImg, softTokens: 280, dimension: dim) {
                                    pageVisualVectors[cand.pageNumber] = v
                                    visVec = v
                                } else {
                                    visVec = capVec
                                }
                                await PowerManager.shared.applyDutyCycle(afterWork: Date().timeIntervalSince(workStart))
                            }
                        } else {
                            progress?("Vision-Embedding (Inline-Bild + Umfeld S. \(cand.pageNumber)) für Abbildung \(i + 1)/\(pkg.figureCandidates.count) (\(cand.figureLabel))...")
                            let workStart = Date()
                            if let cropImg = cand.loadContextualCropImage(),
                               let v = try? await chosenEngine.embedCGImage(cropImg, softTokens: 280, dimension: dim) {
                                visVec = v
                            } else {
                                visVec = capVec
                            }
                            await PowerManager.shared.applyDutyCycle(afterWork: Date().timeIntervalSince(workStart))
                        }

                        finalFigures.append(DocumentFigure(
                            id: cand.id,
                            documentID: cand.documentID,
                            pageNumber: cand.pageNumber,
                            breadcrumb: cand.breadcrumb,
                            figureLabel: cand.figureLabel,
                            captionText: cand.captionText,
                            surroundingContext: cand.surroundingContext,
                            croppedImagePath: cand.croppedImagePath,
                            fullPageImagePath: cand.fullPageImagePath,
                            bbox: cand.bbox,
                            visualEmbedding: visVec,
                            captionEmbedding: capVec.isEmpty ? visVec : capVec
                        ))
                    }

                    if !keepVisionLoaded {
                        await chosenEngine.unloadVisionTower()
                    }

                case .cropsOnly:
                    progress?("Berechne Ausschnitt-Bild- & Caption-Embeddings für \(pkg.figureCandidates.count) freigestellte Abbildungen...")
                    try await chosenEngine.loadVisionTower()

                    for (i, cand) in pkg.figureCandidates.enumerated() {
                        try await PowerManager.shared.waitUntilIndexingAllowedAsync(generation: cancelGen, path: stdPath, progress: progress)
                        progress?("Vision-Embedding für Abbildung \(i + 1)/\(pkg.figureCandidates.count) (\(cand.figureLabel))...")
                        var visVec = i < captionVectors.count ? captionVectors[i] : []
                        let workStart = Date()
                        if let img = cand.loadContextualCropImage(),
                           let v = try? await chosenEngine.embedCGImage(img, softTokens: 280, dimension: dim) {
                            visVec = v
                        }
                        await PowerManager.shared.applyDutyCycle(afterWork: Date().timeIntervalSince(workStart))
                        let capVec = i < captionVectors.count ? captionVectors[i] : visVec

                        finalFigures.append(DocumentFigure(
                            id: cand.id,
                            documentID: cand.documentID,
                            pageNumber: cand.pageNumber,
                            breadcrumb: cand.breadcrumb,
                            figureLabel: cand.figureLabel,
                            captionText: cand.captionText,
                            surroundingContext: cand.surroundingContext,
                            croppedImagePath: cand.croppedImagePath,
                            fullPageImagePath: cand.fullPageImagePath,
                            bbox: cand.bbox,
                            visualEmbedding: visVec,
                            captionEmbedding: capVec
                        ))
                    }

                    if !keepVisionLoaded {
                        await chosenEngine.unloadVisionTower()
                    }
                }
            }

            if PowerManager.shared.isCancelled(generation: cancelGen, path: stdPath) {
                throw CancellationError()
            }

            // Remove temporary full-page and figure PNGs after embedding so Assets uses 0 MB on disk until figures are requested on the fly.
            if ProcessInfo.processInfo.environment["CORTEX_KEEP_PAGE_PNGS"] != "1" {
                try? FileManager.default.removeItem(at: docPagesDir)
                try? FileManager.default.removeItem(at: docFiguresDir)
            }

            progress?("Speichere Vektoren & FTS5-Index in SQLite...")
            try db.saveDocumentIndex(document: pkg.document, chunks: pkg.chunks, figures: finalFigures)
            progress?("Fertig: \(pkg.document.title) (\(pkg.chunks.count) Chunks, \(finalFigures.count) Abbildungen).")

            let stored = try db.listDocuments().first(where: { ($0.filePath as NSString).standardizingPath == stdPath }) ?? pkg.document
            return stored
        } catch {
            try? FileManager.default.removeItem(at: docPagesDir)
            if !wasAlreadyIndexed {
                try? FileManager.default.removeItem(at: docFiguresDir)
            }
            PowerManager.shared.clearCancelledDocument(path: stdPath)
            if error is CancellationError || PowerManager.shared.isCancelled(generation: cancelGen, path: stdPath) {
                throw CancellationError()
            }
            throw error
        }
    }

    /// Conversion, rendering and OCR run off the service actor: they take seconds to minutes (or wait while indexing is
    /// paused on battery) and must not block searches. Cancellation of the calling task still reaches the pipeline.
    /// Re-derives the captions of uncaptioned figures from the PDF text layer and refreshes their search data
    /// (caption, keyword index, caption vector) – the effect of the improved caption extraction without re-indexing.
    /// Figures on pages without a usable text layer keep their caption. Returns (checked, updated).
    public func refreshFigureCaptions(progress: (@Sendable (String) -> Void)? = nil) async throws -> (checked: Int, updated: Int) {
        let figures = try db.listUncaptionedFigures()
        progress?("Lese Bildunterschriften aus \(Set(figures.map(\.documentPath)).count) Dokumenten …")
        let changes = await Self.captionsFromPDFText(figures)
        guard !changes.isEmpty else { return (figures.count, 0) }

        let settings = CortexSettingsManager.shared.settings
        let engine = try await ensureExclusiveEngine(activeEngineKind)
        try await engine.loadTextTowerOnly()
        var updated = 0
        for start in stride(from: 0, to: changes.count, by: 32) {
            let batch = Array(changes[start..<min(changes.count, start + 32)])
            let vectors = try await engine.embedDocuments(
                batch.map { (title: Optional($0.figure.documentTitle), body: "\($0.figure.label): \($0.caption). \($0.figure.context)") },
                dimension: settings.embeddingDimension
            )
            for (change, vector) in zip(batch, vectors) {
                try db.updateFigureCaption(id: change.figure.id, caption: change.caption, captionVector: vector,
                                           visualIsCaption: change.figure.visualIsCaption)
                updated += 1
            }
            progress?("Bildunterschriften aktualisiert: \(updated)/\(changes.count)")
            await PowerManager.shared.applyDutyCycle(afterWork: 0.05)
        }
        lastActivityDate = Date()
        return (figures.count, updated)
    }

    /// PDF reading runs off the actor (searches stay responsive); one document is opened at a time.
    nonisolated private static func captionsFromPDFText(_ figures: [CortexDatabase.UncaptionedFigure]) async
        -> [(figure: CortexDatabase.UncaptionedFigure, caption: String)] {
        var out: [(CortexDatabase.UncaptionedFigure, String)] = []
        for (path, group) in Dictionary(grouping: figures, by: \.documentPath) {
            autoreleasepool {
                guard let pdf = PDFDocument(url: URL(fileURLWithPath: DocumentFormats.readablePDFPath(for: path))) else { return }
                for fig in group {
                    guard let page = pdf.page(at: fig.pageNumber - 1),
                          let caption = PDFVisionPipeline.pdfCaption(for: fig.bbox, on: page, pageNumber: fig.pageNumber),
                          caption != fig.caption else { continue }
                    out.append((fig, caption))
                }
            }
        }
        return out
    }

    /// Starts the analysis of `url` in the background unless it would be skipped anyway (unchanged file).
    private func startPrefetch(_ url: URL, collectionID: String, folderID: String?) {
        let std = (url.path as NSString).standardizingPath
        guard prefetched[std] == nil else { return }
        let docs = (try? db.listDocuments()) ?? []
        let hash = (try? PDFVisionPipeline.computeSHA256(of: url)) ?? ""
        // Unchanged or duplicate content: indexPDF returns without analysing, prefetching would be wasted work.
        if !hash.isEmpty, docs.contains(where: { $0.indexStatus == "indexed" && $0.fileHash == hash }) { return }
        let id = docs.first(where: { ($0.filePath as NSString).standardizingPath == std })?.id ?? UUID().uuidString
        let task = Task.detached(priority: .utility) {
            try await Self.analyse(fileURL: url, documentID: id, collectionID: collectionID, folderID: folderID, progress: nil)
        }
        prefetched[std] = (id, task)
    }

    /// Drops prepared analyses (queue cancelled or finished); their page images and crops are removed.
    public func discardPrefetches() {
        for (_, pre) in prefetched { Self.discard(pre, ownedByIndexedDocument: isIndexedDocument(pre.id)) }
        prefetched.removeAll()
    }

    private func isIndexedDocument(_ id: String) -> Bool {
        ((try? db.listDocuments()) ?? []).contains { $0.id == id }
    }

    /// Cancels a prepared analysis. Its page images and crops are removed unless an indexed document owns that ID
    /// (a re-index keeps the document's ID and asset folders).
    nonisolated private static func discard(_ pre: (id: String, task: Task<ExtractedDocumentPackage, Error>),
                                            ownedByIndexedDocument: Bool) {
        pre.task.cancel()
        guard !ownedByIndexedDocument else { return }
        Task.detached(priority: .utility) {
            _ = try? await pre.task.value
            try? FileManager.default.removeItem(at: CortexPaths.pagesAssetsDir.appendingPathComponent(pre.id, isDirectory: true))
            try? FileManager.default.removeItem(at: CortexPaths.figuresAssetsDir.appendingPathComponent(pre.id, isDirectory: true))
        }
    }

    nonisolated private static func analyse(fileURL: URL, documentID: String, collectionID: String, folderID: String?,
                                            progress: (@Sendable (String) -> Void)?) async throws -> ExtractedDocumentPackage {
        let readable = try DocumentConverter.pdfURL(for: fileURL)
        return try PDFVisionPipeline.processPDF(at: readable, sourceURL: fileURL, documentID: documentID,
                                                collectionID: collectionID, folderID: folderID, progress: progress)
    }

    public func indexFolder(
        at folderURL: URL,
        collectionID: String,
        engineKind: EngineKind? = nil,
        force: Bool = false,
        progress: (@Sendable (String) -> Void)? = nil
    ) async throws -> [LibraryDocument] {
        var folderRecord = WatchedFolder(
            collectionID: collectionID,
            name: folderURL.lastPathComponent,
            path: folderURL.path,
            lastIndexedAt: Date().timeIntervalSince1970
        )
        if let existing = try db.listWatchedFolders(collectionID: collectionID).first(where: { $0.path == folderURL.path }) {
            folderRecord.id = existing.id
        }
        try db.saveWatchedFolder(folderRecord)

        let pdfURLs = Self.collectPDFURLs(in: folderURL)

        var indexedDocs: [LibraryDocument] = []
        do {
            for (idx, pdfURL) in pdfURLs.enumerated() {
                progress?("[\(idx + 1)/\(pdfURLs.count)] Indiziere \(pdfURL.lastPathComponent)...")
                let doc = try await indexPDF(
                    at: pdfURL,
                    collectionID: collectionID,
                    folderID: folderRecord.id,
                    engineKind: engineKind,
                    force: force,
                    keepVisionLoaded: true,
                    progress: progress
                )
                indexedDocs.append(doc)
            }
            await unloadVisionTowerIfLoaded()
            return indexedDocs
        } catch {
            await unloadVisionTowerIfLoaded()
            throw error
        }
    }

    nonisolated private static func collectPDFURLs(in folderURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var urls: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            if DocumentFormats.isSupported(item), !item.lastPathComponent.hasPrefix("~$") {
                urls.append(item)
            }
        }
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Search & Retrieval Operations

    public func search(
        query: String,
        scope: ScopeFilter? = nil,
        contextChunks: Int = 1,
        includeFigures: Bool = true,
        topK: Int = 8,
        source: String = "ui",
        engineOverride: EngineKind? = nil,
        content: SearchContentMode = .text,
        chunkGranularity: String? = nil,
        maxCharsPerChunk: Int? = nil,
        minScore: Double? = nil
    ) async throws -> SearchResponsePayload {
        let start = DispatchTime.now()
        let settings = CortexSettingsManager.shared.settings
        let effectiveScope = resolveEffectiveScope(scope)
        let eng = try await ensureExclusiveEngine(engineOverride ?? activeEngineKind)
        let qVec = try await eng.embedQuery(query, dimension: settings.embeddingDimension)
        var results: [SearchResultItem]
        if settings.neuralReranker != .none, settings.neuralReranker.isDownloaded {
            // Cross-encoder: fetch the candidate pool without the lexical rule, score each (question, passage) pair.
            let pool = try db.hybridSearch(
                queryText: query, queryVector: qVec, scope: effectiveScope, contextChunks: contextChunks,
                includeFigures: includeFigures, topK: max(topK, settings.rerankCandidatePoolSize), lexicalRerank: false
            )
            results = try await neuralRerank(query: query, pool: pool, topK: topK, model: settings.neuralReranker)
        } else {
            results = try db.hybridSearch(
                queryText: query,
                queryVector: qVec,
                scope: effectiveScope,
                contextChunks: contextChunks,
                includeFigures: includeFigures,
                topK: topK
            )
        }
        // Text and images share one vector space: figures join the list by rank (see SearchFusion).
        if content != .text && includeFigures {
            let figs = try db.searchFigures(queryText: query, queryVector: qVec, scope: effectiveScope, topK: max(topK, 12))
            var allFiguresByPage: [String: [FigureResultItem]] = [:]
            for f in figs {
                let key = "\(f.documentID)#\(f.pageNumber)"
                if allFiguresByPage[key] == nil {
                    let pageFigs = (try? db.fetchFiguresOnPage(
                        documentID: f.documentID,
                        documentTitle: f.documentTitle,
                        documentPath: f.documentPath,
                        collectionName: f.collectionName,
                        moduleName: f.moduleName,
                        pageNumber: f.pageNumber
                    )) ?? [f]
                    allFiguresByPage[key] = pageFigs.isEmpty ? [f] : pageFigs
                }
            }
            results = SearchFusion.fuse(
                text: content == .figures ? [] : results,
                figures: figs,
                mode: content,
                topK: topK,
                minFigureScore: settings.minFigureScore,
                allFiguresByPage: allFiguresByPage
            )
        }
        if includeFigures {
            for i in results.indices {
                if var fig = results[i].figure {
                    fig.croppedImagePath = PDFVisionPipeline.ensureCroppedFigureExists(fig)
                    results[i].figure = fig
                }
                for j in results[i].figuresOnPage.indices {
                    results[i].figuresOnPage[j].croppedImagePath = PDFVisionPipeline.ensureCroppedFigureExists(results[i].figuresOnPage[j])
                }
            }
        } else {
            for i in results.indices {
                results[i].figuresOnPage = []
            }
        }
        if let minScore {
            results = results.filter { $0.score >= minScore }
        }
        if let maxChars = maxCharsPerChunk, maxChars > 50 {
            for i in results.indices {
                if results[i].matchedContent.count > maxChars {
                    let text = results[i].matchedContent
                    let idx = text.index(text.startIndex, offsetBy: min(maxChars, text.count))
                    let prefix = String(text[..<idx])
                    if let lastSpace = prefix.lastIndex(of: " ") {
                        results[i].matchedContent = String(prefix[..<lastSpace]) + " …"
                    } else {
                        results[i].matchedContent = prefix + " …"
                    }
                }
            }
        }
        if let granularity = chunkGranularity?.lowercased() {
            switch granularity {
            case "compact":
                for i in results.indices {
                    results[i].contextBefore = ""
                    results[i].contextAfter = ""
                    if results[i].matchedContent.count > 380 {
                        let text = results[i].matchedContent
                        let idx = text.index(text.startIndex, offsetBy: 380)
                        let prefix = String(text[..<idx])
                        if let lastDot = prefix.lastIndex(of: ".") {
                            results[i].matchedContent = String(prefix[...lastDot])
                        } else if let lastSpace = prefix.lastIndex(of: " ") {
                            results[i].matchedContent = String(prefix[..<lastSpace]) + " …"
                        }
                    }
                }
            case "expanded":
                break
            default:
                break
            }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let roundedMs = (ms * 100).rounded() / 100
        let engineLabel = await eng.engineName
        let figTotal = results.reduce(0) { $0 + $1.figuresOnPage.count }

        try? db.logAgentEvent(AgentActivityEvent(
            source: source,
            operation: "search",
            query: query,
            scopeSummary: effectiveScope.summaryDescription,
            resultCount: results.count,
            figureCount: figTotal,
            latencyMs: roundedMs,
            engineUsed: engineLabel
        ))

        return SearchResponsePayload(
            query: query,
            scope: effectiveScope,
            latencyMs: roundedMs,
            engine: engineLabel,
            results: results
        )
    }

    private func neuralRerank(query: String, pool: [SearchResultItem], topK: Int, model: NeuralRerankerModel) async throws -> [SearchResultItem] {
        guard pool.count > 1 else { return pool }
        if neuralRerankerKind != model || neuralReranker == nil {
            await neuralReranker?.unload()
            neuralReranker = LlamaReranker(modelURL: model.fileURL)
            neuralRerankerKind = model
        }
        guard let reranker = neuralReranker else { return Array(pool.prefix(topK)) }
        let scores = try await reranker.score(query: query, documents: pool.map { $0.breadcrumb + "\n" + $0.matchedContent })
        return zip(pool, scores)
            .sorted { $0.1 > $1.1 }
            .prefix(max(1, topK))
            .enumerated()
            .map { idx, pair in
                var item = pair.0
                item.rank = idx + 1
                // Logit → 0…1 so that the relevance meter stays meaningful.
                item.score = (Double(1 / (1 + exp(-pair.1))) * 1000).rounded() / 1000
                return item
            }
    }

    public func unloadNeuralReranker() async {
        await neuralReranker?.unload()
        neuralReranker = nil
        neuralRerankerKind = .none
    }

    public func searchFigures(
        query: String,
        scope: ScopeFilter? = nil,
        topK: Int = 8,
        source: String = "ui",
        engineOverride: EngineKind? = nil
    ) async throws -> FigureSearchResponsePayload {
        let start = DispatchTime.now()
        let settings = CortexSettingsManager.shared.settings
        let effectiveScope = resolveEffectiveScope(scope)
        let eng = try await ensureExclusiveEngine(engineOverride ?? activeEngineKind)
        let qVec = try await eng.embedQuery(query, dimension: settings.embeddingDimension)
        var figs = try db.searchFigures(queryText: query, queryVector: qVec, scope: effectiveScope, topK: topK)
        for i in figs.indices {
            figs[i].croppedImagePath = PDFVisionPipeline.ensureCroppedFigureExists(figs[i])
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let roundedMs = (ms * 100).rounded() / 100
        let engineLabel = await eng.engineName

        try? db.logAgentEvent(AgentActivityEvent(
            source: source,
            operation: "figures",
            query: query,
            scopeSummary: effectiveScope.summaryDescription,
            resultCount: figs.count,
            figureCount: figs.count,
            latencyMs: roundedMs,
            engineUsed: engineLabel
        ))

        return FigureSearchResponsePayload(
            query: query,
            scope: effectiveScope,
            latencyMs: roundedMs,
            engine: engineLabel,
            figures: figs
        )
    }

    /// Returns all ready-cropped figures for a specific document page. If no cropped figures are stored yet
    /// (or their PNG files are missing on disk) and `cropIfMissing == true`, runs `PDFVisionPipeline.extractFiguresForPageOnDemand`
    /// so MCP agents can always pull ready-cropped images from any high-scoring page.
    public func getPageFigures(
        documentQuery: String,
        pageNumber: Int,
        cropIfMissing: Bool = true,
        source: String = "mcp"
    ) throws -> FigureSearchResponsePayload {
        let start = DispatchTime.now()
        guard let overview = try db.getDocumentOverview(titleOrID: documentQuery) else {
            throw CortexDatabase.DBError("Dokument '\(documentQuery)' wurde nicht gefunden.")
        }
        let doc = overview.document
        let targetPage = max(1, min(doc.pageCount, pageNumber))
        var figs = try db.fetchFiguresOnPage(
            documentID: doc.id,
            documentTitle: doc.title,
            documentPath: doc.filePath,
            collectionName: overview.collectionName,
            moduleName: overview.moduleName,
            pageNumber: targetPage
        )

        if !figs.isEmpty && cropIfMissing {
            for i in figs.indices {
                figs[i].croppedImagePath = PDFVisionPipeline.ensureCroppedFigureExists(figs[i])
            }
        }
        let filesPresent = !figs.isEmpty && figs.allSatisfy { FileManager.default.fileExists(atPath: $0.croppedImagePath) }
        if !filesPresent && cropIfMissing {
            let candidates = PDFVisionPipeline.extractFiguresForPageOnDemand(document: doc, pageNumber: targetPage)
            if !candidates.isEmpty {
                figs = candidates.map { cand in
                    FigureResultItem(
                        figureID: cand.id,
                        documentID: doc.id,
                        documentTitle: doc.title,
                        documentPath: doc.filePath,
                        collectionName: overview.collectionName,
                        moduleName: overview.moduleName,
                        pageNumber: cand.pageNumber,
                        breadcrumb: cand.breadcrumb,
                        label: cand.figureLabel,
                        caption: cand.captionText,
                        surroundingContext: cand.surroundingContext,
                        croppedImagePath: cand.croppedImagePath,
                        fullPageImagePath: cand.fullPageImagePath,
                        bbox: cand.bbox,
                        score: 1.0
                    )
                }
            }
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        let roundedMs = (ms * 100).rounded() / 100
        let scope = ScopeFilter(documentIDs: [doc.id], pageStart: targetPage, pageEnd: targetPage)

        try? db.logAgentEvent(AgentActivityEvent(
            source: source,
            operation: "page_figures",
            query: "\(doc.title) S. \(targetPage)",
            scopeSummary: overview.collectionName,
            resultCount: figs.count,
            figureCount: figs.count,
            latencyMs: roundedMs,
            engineUsed: "Vision Page Cropper"
        ))

        return FigureSearchResponsePayload(
            query: "\(doc.title) – Seite \(targetPage)",
            scope: scope,
            latencyMs: roundedMs,
            engine: "Vision Page Cropper",
            figures: figs
        )
    }

    public func statusPayload(daemonActive: Bool) async throws -> DaemonStatusPayload {
        let eng = currentBackend
        let mem = Double(await eng.currentMemoryBytes()) / (1024.0 * 1024.0)
        let tree = try db.buildLibraryHierarchy(activeUIScope: activeUIScope)
        let guidance: String
        if !activeUIScope.isEmpty && enforceUIScopeForAgents {
            guidance = "Hinweis für KI-Agenten: Der Nutzer hat in der Desktop-App bereits einen aktiven Scope ausgewählt (\(activeUIScope.summaryDescription)). Wenn du in cortex_search_knowledge oder cortex_search_figures keine eigenen Filter übergibst (oder use_ui_selection=true setzt), suchst du automatisch in dieser Auswahl. Alternativ kannst du gezielt nach module (Fachrichtung/Projekt), collection (Sammlung), folder (Vorlesungsordner) oder document (Titel oder ID aus hierarchy) filtern."
        } else {
            guidance = "Hinweis für KI-Agenten: Wähle anhand von 'hierarchy' (Module/Fachrichtungen -> Collections/Sammlungen -> Folders/Ordner -> Documents/PDFs) den passenden Suchbereich aus und übergib module, collection, folder oder document (Name oder ID) an cortex_search_knowledge bzw. cortex_search_figures."
        }
        return DaemonStatusPayload(
            daemonActive: daemonActive,
            socketPath: CortexPaths.socketPath,
            activeEngine: await eng.engineName,
            activeEngineKind: activeEngineKind,
            isTextTowerLoaded: await eng.isTextLoaded,
            isVisionTowerLoaded: await eng.isVisionLoaded,
            memoryMB: (mem * 10).rounded() / 10,
            activeUIScope: activeUIScope,
            enforceUIScopeForAgents: enforceUIScopeForAgents,
            agentGuidance: guidance,
            hierarchy: tree,
            modules: try db.listModules(),
            collections: try db.listCollections(),
            watchedFolders: try db.listWatchedFolders(),
            documents: try db.listDocuments()
        )
    }

    public func handleIPCRequest(_ req: IPCRequest, daemonActive: Bool = true) async -> IPCResponse {
        lastActivityDate = Date()
        do {
            switch req.action {
            case .status:
                let st = try await statusPayload(daemonActive: daemonActive)
                return IPCResponse(ok: true, status: st)

            case .switchEngine:
                guard let target = req.engine else {
                    return IPCResponse(ok: false, error: "Missing 'engine' parameter ('llama' or 'mlx')")
                }
                try await setEngine(target)
                let st = try await statusPayload(daemonActive: daemonActive)
                return IPCResponse(ok: true, status: st)

            case .setScope:
                if let newScope = req.scope {
                    updateUIScope(newScope)
                }
                let st = try await statusPayload(daemonActive: daemonActive)
                return IPCResponse(ok: true, status: st)

            case .search:
                guard let q = req.query, !q.isEmpty else {
                    return IPCResponse(ok: false, error: "Missing 'query' parameter")
                }
                let res = try await search(
                    query: q,
                    scope: req.scope,
                    contextChunks: req.contextChunks ?? 1,
                    includeFigures: req.includeFigures ?? true,
                    topK: req.topK ?? 6,
                    source: req.source,
                    engineOverride: req.engine,
                    content: req.content ?? .text,
                    chunkGranularity: req.chunkGranularity,
                    maxCharsPerChunk: req.maxCharsPerChunk,
                    minScore: req.minScore
                )
                return IPCResponse(ok: true, searchResponse: res)

            case .figures:
                guard let q = req.query, !q.isEmpty else {
                    return IPCResponse(ok: false, error: "Missing 'query' parameter")
                }
                let res = try await searchFigures(
                    query: q,
                    scope: req.scope,
                    topK: req.topK ?? 6,
                    source: req.source,
                    engineOverride: req.engine
                )
                return IPCResponse(ok: true, figureResponse: res)

            case .pageFigures:
                guard let dq = req.documentQuery, !dq.isEmpty else {
                    return IPCResponse(ok: false, error: "Missing 'documentQuery' parameter")
                }
                let page = req.pageNumber ?? req.scope?.pageStart ?? 1
                let res = try getPageFigures(
                    documentQuery: dq,
                    pageNumber: page,
                    cropIfMissing: req.cropIfMissing ?? true,
                    source: req.source
                )
                return IPCResponse(ok: true, figureResponse: res)

            case .expand:
                guard let cid = req.chunkID, !cid.isEmpty else {
                    return IPCResponse(ok: false, error: "Missing 'chunkID' parameter")
                }
                let start = DispatchTime.now()
                guard let expanded = try db.expandChunkContext(
                    chunkID: cid,
                    before: req.beforeChunks ?? 2,
                    after: req.afterChunks ?? 2
                ) else {
                    return IPCResponse(ok: false, error: "Chunk '\(cid)' not found")
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
                try? db.logAgentEvent(AgentActivityEvent(
                    source: req.source,
                    operation: "expand",
                    query: cid,
                    scopeSummary: expanded.documentTitle,
                    resultCount: 1,
                    figureCount: expanded.figuresOnPage.count,
                    latencyMs: (ms * 100).rounded() / 100,
                    engineUsed: "SQLite Direct"
                ))
                return IPCResponse(ok: true, expandedItem: expanded)

            case .documentOverview:
                guard let dq = req.documentQuery, !dq.isEmpty else {
                    return IPCResponse(ok: false, error: "Missing 'documentQuery' parameter")
                }
                guard let overview = try db.getDocumentOverview(titleOrID: dq) else {
                    return IPCResponse(ok: false, error: "Document matching '\(dq)' not found")
                }
                try? db.logAgentEvent(AgentActivityEvent(
                    source: req.source,
                    operation: "toc_overview",
                    query: dq,
                    scopeSummary: overview.collectionName,
                    resultCount: overview.document.toc.count,
                    figureCount: overview.figures.count,
                    latencyMs: 1.2,
                    engineUsed: "SQLite Direct"
                ))
                return IPCResponse(ok: true, documentOverview: overview)

            case .indexPDF:
                guard let path = req.path else {
                    return IPCResponse(ok: false, error: "Missing 'path' parameter")
                }
                let colID = try resolveCollectionID(id: req.collectionID, name: req.collectionName)
                let doc = try await indexPDF(
                    at: URL(fileURLWithPath: path),
                    collectionID: colID,
                    engineKind: req.engine,
                    force: req.force ?? false
                )
                return IPCResponse(ok: true, indexedDocument: doc)

            case .indexFolder:
                guard let path = req.path else {
                    return IPCResponse(ok: false, error: "Missing 'path' parameter")
                }
                let colID = try resolveCollectionID(id: req.collectionID, name: req.collectionName)
                let docs = try await indexFolder(
                    at: URL(fileURLWithPath: path),
                    collectionID: colID,
                    engineKind: req.engine,
                    force: req.force ?? false
                )
                return IPCResponse(ok: true, indexedDocument: docs.first)

            case .benchmark:
                let report = await runBenchmarkCleanly()
                return IPCResponse(ok: true, benchmarkReport: report)

            case .readPages:
                guard let dq = req.documentQuery, !dq.isEmpty else {
                    return IPCResponse(ok: false, error: "Missing 'documentQuery' parameter")
                }
                guard let overview = try db.getDocumentOverview(titleOrID: dq) else {
                    return IPCResponse(ok: false, error: "Document matching '\(dq)' not found")
                }
                let doc = overview.document
                let start = max(1, req.scope?.pageStart ?? 1)
                // Cap the range so an agent cannot accidentally pull a whole textbook into its context.
                let end = min(doc.pageCount, req.scope?.pageEnd ?? start, start + 19)
                let pages = try db.readPages(documentID: doc.id, from: start, to: max(start, end))
                try? db.logAgentEvent(AgentActivityEvent(
                    source: req.source,
                    operation: "read_pages",
                    query: "\(doc.title) S. \(start)-\(max(start, end))",
                    scopeSummary: overview.collectionName,
                    resultCount: pages.count,
                    figureCount: 0,
                    latencyMs: 0,
                    engineUsed: "SQLite Direct"
                ))
                return IPCResponse(ok: true, pageText: PageTextPayload(
                    documentID: doc.id,
                    documentTitle: doc.title,
                    documentPath: doc.filePath,
                    pageCount: doc.pageCount,
                    pages: pages.map { PageTextPayload.PageText(page: $0.page, text: $0.text) }
                ))
            }
        } catch {
            return IPCResponse(ok: false, error: "\(error)")
        }
    }

    public func runBenchmarkCleanly(progress: (@Sendable (String) -> Void)? = nil) async -> EngineBenchmarkReport {
        let previousEngine = activeEngineKind
        await llamaBackend.unloadAll()
        await mlxBackend.unloadAll()
        let report = await EngineBenchmarkRunner.runFullComparison(progress: progress)
        try? await setEngine(previousEngine)
        return report
    }

    private func resolveCollectionID(id: String?, name: String?) throws -> String {
        let cols = try db.listCollections()
        if let id, let match = cols.first(where: { $0.id == id }) {
            return match.id
        }
        if let name, let match = cols.first(where: { $0.name.localizedCaseInsensitiveContains(name) }) {
            return match.id
        }
        if id != nil || name != nil {
            let wanted = id ?? name ?? ""
            throw CortexDatabase.DBError("Sammlung '\(wanted)' nicht gefunden. Verfügbar: \(cols.map { "\($0.name) (\($0.id))" }.joined(separator: ", "))")
        }
        if let first = cols.first {
            return first.id
        }
        let defaultCol = LibraryCollection(id: "col_default", moduleID: "", name: "Allgemein")
        try db.saveCollection(defaultCol)
        return defaultCol.id
    }
}

// MARK: - UNIX Domain Socket Daemon Server (Runs inside CortexRAG.app)

public final class CortexSocketDaemon: @unchecked Sendable {
    private let service: CortexService
    public let socketPath: String
    private var serverFD: Int32 = -1
    private var acceptThread: Thread?
    private let stateLock = NSLock()
    public private(set) var isRunning: Bool = false
    public var onActivityLogged: (@Sendable () -> Void)?

    public init(service: CortexService, socketPath: String = CortexPaths.socketPath) {
        self.service = service
        self.socketPath = socketPath
        signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        stop()
    }

    public func start() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !isRunning else { return }

        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Self.disableSigPipe(on: fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    strncpy(dst, cstr, maxLen - 1)
                }
            }
        }

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        guard listen(fd, 16) == 0 else {
            let err = errno
            close(fd)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err))
        }

        serverFD = fd
        isRunning = true

        let thread = Thread { [weak self] in
            self?.acceptLoop(fd: fd)
        }
        thread.name = "CortexRAG.SocketDaemon"
        thread.start()
        acceptThread = thread
    }

    public func stop() {
        stateLock.lock()
        let wasRunning = isRunning
        let fd = serverFD
        isRunning = false
        serverFD = -1
        stateLock.unlock()

        if wasRunning && fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            close(fd)
            unlink(socketPath)
        } else if FileManager.default.fileExists(atPath: socketPath) {
            unlink(socketPath)
        }
    }

    private func acceptLoop(fd: Int32) {
        while true {
            stateLock.lock()
            let active = isRunning
            stateLock.unlock()
            if !active { break }

            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(fd, sockPtr, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            Self.disableSigPipe(on: clientFD)

            let svc = self.service
            let callback = self.onActivityLogged
            Task.detached {
                defer { close(clientFD) }
                guard let reqData = Self.readLineData(from: clientFD) else { return }
                let response: IPCResponse
                if let request = try? JSONDecoder().decode(IPCRequest.self, from: reqData) {
                    response = await svc.handleIPCRequest(request, daemonActive: true)
                    callback?()
                } else {
                    response = IPCResponse(ok: false, error: "Invalid IPC JSON request")
                }
                if let respData = try? JSONEncoder().encode(response) {
                    var payload = respData
                    payload.append(0x0A)
                    Self.writeAll(payload, to: clientFD)
                }
            }
        }
    }

    fileprivate static func disableSigPipe(on fd: Int32) {
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    fileprivate static func readLineData(from fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if let nlIndex = chunk[0..<n].firstIndex(of: 0x0A) {
                    buffer.append(contentsOf: chunk[0..<nlIndex])
                    break
                } else {
                    buffer.append(contentsOf: chunk[0..<n])
                }
            } else {
                break
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    fileprivate static func writeAll(_ data: Data, to fd: Int32) {
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = write(fd, base.advanced(by: sent), data.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}

// MARK: - UNIX Domain Socket Client (Used by CLI & MCP)

public enum CortexSocketClient {
    public struct ClientError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// Probes the UNIX domain socket and automatically unlinks stale socket files if the app is no longer running.
    public static func isDaemonRunning(socketPath: String = CortexPaths.socketPath) -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        CortexSocketDaemon.disableSigPipe(on: fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    strncpy(dst, cstr, maxLen - 1)
                }
            }
        }

        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if res == 0 {
            return true
        }
        if errno == ECONNREFUSED || errno == ENOENT {
            unlink(socketPath)
        }
        return false
    }

    public static func send(_ request: IPCRequest, socketPath: String = CortexPaths.socketPath) throws -> IPCResponse {
        signal(SIGPIPE, SIG_IGN)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ClientError("Socket creation failed (errno \(errno))")
        }
        defer { close(fd) }
        CortexSocketDaemon.disableSigPipe(on: fd)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { cstr in
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                    strncpy(dst, cstr, maxLen - 1)
                }
            }
        }

        let connectRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectRes == 0 else {
            if errno == ECONNREFUSED {
                unlink(socketPath)
            }
            throw ClientError("CortexRAG Desktop-Daemon ist nicht aktiv (\(socketPath)). Bitte starte CortexRAG.app und aktiviere den Daemon (oder nutze --standalone).")
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        CortexSocketDaemon.writeAll(payload, to: fd)

        guard let responseData = CortexSocketDaemon.readLineData(from: fd) else {
            throw ClientError("Empty response from CortexRAG daemon")
        }
        return try JSONDecoder().decode(IPCResponse.self, from: responseData)
    }
}
