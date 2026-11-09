import Foundation
import Accelerate

public enum EngineKind: String, Codable, CaseIterable, Sendable {
    case llamaMetal = "llama"
    case mlxSwift = "mlx"

    public var displayName: String {
        switch self {
        case .llamaMetal: return "llama.cpp (Metal Q8_0)"
        case .mlxSwift: return "MLX Swift (Q8 + BF16)"
        }
    }
}

public enum MatryoshkaDimension: Int, Codable, CaseIterable, Sendable {
    case d768 = 768
    case d512 = 512
    case d256 = 256
    case d128 = 128

    public var displayName: String {
        switch self {
        case .d768: return "768 Dimensionen (Voll / Maximale Genauigkeit)"
        case .d512: return "512 Dimensionen (MRL Schnell / 98% Qualität)"
        case .d256: return "256 Dimensionen (MRL Kompakt / 96% Qualität)"
        case .d128: return "128 Dimensionen (MRL Ultra-Schnell / Kompakt)"
        }
    }

    public var shortLabel: String {
        "\(rawValue)D"
    }
}

public enum CortexPaths {
    /// Resolved once per process: switching the storage folder takes effect after a restart,
    /// so the open database and the asset paths can never point to different locations.
    public static let appSupport: URL = {
        let customDir = CortexSettingsManager.shared.settings.customStorageDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customDir.isEmpty {
            return URL(fileURLWithPath: customDir, isDirectory: true)
        }
        if let custom = ProcessInfo.processInfo.environment["CORTEXRAG_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CortexRAG", isDirectory: true)
    }()

    public static var databaseURL: URL {
        appSupport.appendingPathComponent("Database/cortexrag.sqlite")
    }

    public static var pagesAssetsDir: URL {
        appSupport.appendingPathComponent("Assets/Pages", isDirectory: true)
    }

    public static var figuresAssetsDir: URL {
        appSupport.appendingPathComponent("Assets/Figures", isDirectory: true)
    }

    public static var llamaModelsDir: URL {
        appSupport.appendingPathComponent("Models/llama", isDirectory: true)
    }

    public static var mlxModelsDir: URL {
        appSupport.appendingPathComponent("Models/mlx", isDirectory: true)
    }

    public static var rerankerModelsDir: URL {
        appSupport.appendingPathComponent("Models/rerankers", isDirectory: true)
    }

    public static var socketPath: String {
        if let custom = ProcessInfo.processInfo.environment["CORTEXRAG_SOCKET"], !custom.isEmpty {
            return custom
        }
        return "/tmp/cortexrag.sock"
    }

    public static func ensureDirectories() throws {
        let fm = FileManager.default
        for url in [
            appSupport,
            databaseURL.deletingLastPathComponent(),
            pagesAssetsDir,
            figuresAssetsDir,
            llamaModelsDir,
            mlxModelsDir,
            rerankerModelsDir
        ] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

public struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TOCItem: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String { "\(pageNumber)-\(title)" }
    public var title: String
    public var pageNumber: Int
    public var level: Int

    public init(title: String, pageNumber: Int, level: Int) {
        self.title = title
        self.pageNumber = pageNumber
        self.level = level
    }
}

public struct LibraryModule: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var iconName: String
    public var createdAt: Double

    public init(id: String = UUID().uuidString, name: String, iconName: String = "books.vertical.fill", createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.createdAt = createdAt
    }
}

/// A topic ("Thema", e.g. Distributed Systems). `moduleID` is the optional area ("Bereich", e.g. Computer Science); empty = none.
public struct LibraryCollection: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var moduleID: String
    public var name: String
    public var description: String
    public var createdAt: Double

    public init(
        id: String = UUID().uuidString,
        moduleID: String,
        name: String,
        description: String = "",
        createdAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.moduleID = moduleID
        self.name = name
        self.description = description
        self.createdAt = createdAt
    }
}

public struct WatchedFolder: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var collectionID: String
    public var name: String
    public var path: String
    public var lastIndexedAt: Double?

    public init(
        id: String = UUID().uuidString,
        collectionID: String,
        name: String,
        path: String,
        lastIndexedAt: Double? = nil
    ) {
        self.id = id
        self.collectionID = collectionID
        self.name = name
        self.path = path
        self.lastIndexedAt = lastIndexedAt
    }
}

public struct LibraryDocument: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var collectionID: String
    public var folderID: String?
    public var title: String
    public var filePath: String
    public var fileHash: String
    public var pageCount: Int
    public var abstractSummary: String
    public var toc: [TOCItem]
    public var indexStatus: String
    public var engineUsed: String
    public var indexedAt: Double?
    public var chunkCount: Int
    public var figureCount: Int

    public init(
        id: String = UUID().uuidString,
        collectionID: String,
        folderID: String? = nil,
        title: String,
        filePath: String,
        fileHash: String = "",
        pageCount: Int = 0,
        abstractSummary: String = "",
        toc: [TOCItem] = [],
        indexStatus: String = "pending",
        engineUsed: String = "llama",
        indexedAt: Double? = nil,
        chunkCount: Int = 0,
        figureCount: Int = 0
    ) {
        self.id = id
        self.collectionID = collectionID
        self.folderID = folderID
        self.title = title
        self.filePath = filePath
        self.fileHash = fileHash
        self.pageCount = pageCount
        self.abstractSummary = abstractSummary
        self.toc = toc
        self.indexStatus = indexStatus
        self.engineUsed = engineUsed
        self.indexedAt = indexedAt
        self.chunkCount = chunkCount
        self.figureCount = figureCount
    }
}

public struct DocumentChunk: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var documentID: String
    public var pageNumber: Int
    public var chunkIndex: Int
    public var prevChunkID: String?
    public var nextChunkID: String?
    public var breadcrumb: String
    public var content: String
    public var embedding: [Float]

    public init(
        id: String,
        documentID: String,
        pageNumber: Int,
        chunkIndex: Int,
        prevChunkID: String?,
        nextChunkID: String?,
        breadcrumb: String,
        content: String,
        embedding: [Float] = []
    ) {
        self.id = id
        self.documentID = documentID
        self.pageNumber = pageNumber
        self.chunkIndex = chunkIndex
        self.prevChunkID = prevChunkID
        self.nextChunkID = nextChunkID
        self.breadcrumb = breadcrumb
        self.content = content
        self.embedding = embedding
    }
}

public struct DocumentFigure: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var documentID: String
    public var pageNumber: Int
    public var breadcrumb: String
    public var figureLabel: String
    public var captionText: String
    public var surroundingContext: String
    public var croppedImagePath: String
    public var fullPageImagePath: String
    public var bbox: NormalizedRect
    public var visualEmbedding: [Float]
    public var captionEmbedding: [Float]

    public init(
        id: String,
        documentID: String,
        pageNumber: Int,
        breadcrumb: String,
        figureLabel: String,
        captionText: String,
        surroundingContext: String,
        croppedImagePath: String,
        fullPageImagePath: String,
        bbox: NormalizedRect,
        visualEmbedding: [Float] = [],
        captionEmbedding: [Float] = []
    ) {
        self.id = id
        self.documentID = documentID
        self.pageNumber = pageNumber
        self.breadcrumb = breadcrumb
        self.figureLabel = figureLabel
        self.captionText = captionText
        self.surroundingContext = surroundingContext
        self.croppedImagePath = croppedImagePath
        self.fullPageImagePath = fullPageImagePath
        self.bbox = bbox
        self.visualEmbedding = visualEmbedding
        self.captionEmbedding = captionEmbedding
    }
}

public struct ScopeFilter: Codable, Equatable, Sendable {
    public var moduleIDs: [String]?
    public var moduleNames: [String]?
    public var collectionIDs: [String]?
    public var collectionNames: [String]?
    public var folderIDs: [String]?
    public var folderNames: [String]?
    public var folderPaths: [String]?
    public var documentIDs: [String]?
    public var documentTitles: [String]?
    /// Absolute folder paths (subfolders of an imported folder); matches every document below them.
    public var pathPrefixes: [String]?
    public var pageStart: Int?
    public var pageEnd: Int?
    public var useUISelection: Bool?
    /// When true, module/collection/folder/document ID filters are combined with OR (union of the
    /// selected levels) instead of AND. Used for the checkbox multi-selection of the desktop app.
    public var matchAnyLevel: Bool?

    public init(
        moduleIDs: [String]? = nil,
        moduleNames: [String]? = nil,
        collectionIDs: [String]? = nil,
        collectionNames: [String]? = nil,
        folderIDs: [String]? = nil,
        folderNames: [String]? = nil,
        folderPaths: [String]? = nil,
        documentIDs: [String]? = nil,
        documentTitles: [String]? = nil,
        pathPrefixes: [String]? = nil,
        pageStart: Int? = nil,
        pageEnd: Int? = nil,
        useUISelection: Bool? = nil,
        matchAnyLevel: Bool? = nil
    ) {
        self.moduleIDs = moduleIDs
        self.moduleNames = moduleNames
        self.collectionIDs = collectionIDs
        self.collectionNames = collectionNames
        self.folderIDs = folderIDs
        self.folderNames = folderNames
        self.folderPaths = folderPaths
        self.documentIDs = documentIDs
        self.documentTitles = documentTitles
        self.pathPrefixes = pathPrefixes
        self.pageStart = pageStart
        self.pageEnd = pageEnd
        self.useUISelection = useUISelection
        self.matchAnyLevel = matchAnyLevel
    }

    public var isEmpty: Bool {
        (moduleIDs?.isEmpty ?? true) &&
        (moduleNames?.isEmpty ?? true) &&
        (collectionIDs?.isEmpty ?? true) &&
        (collectionNames?.isEmpty ?? true) &&
        (folderIDs?.isEmpty ?? true) &&
        (folderNames?.isEmpty ?? true) &&
        (folderPaths?.isEmpty ?? true) &&
        (documentIDs?.isEmpty ?? true) &&
        (documentTitles?.isEmpty ?? true) &&
        (pathPrefixes?.isEmpty ?? true) &&
        pageStart == nil && pageEnd == nil
    }

    public var summaryDescription: String {
        var parts: [String] = []
        if let m = moduleNames, !m.isEmpty { parts.append("Module: \(m.joined(separator: ","))") }
        if let c = collectionNames, !c.isEmpty { parts.append("Sammlungen: \(c.joined(separator: ","))") }
        if let fn = folderNames, !fn.isEmpty { parts.append("Ordner: \(fn.joined(separator: ","))") }
        if let fp = folderPaths, !fp.isEmpty { parts.append("Ordnerpfade: \(fp.joined(separator: ","))") }
        if let d = documentTitles, !d.isEmpty { parts.append("PDFs: \(d.map(CortexTextSanitizer.displayTitle).joined(separator: ", "))") }
        if (moduleNames ?? []).isEmpty, let m = moduleIDs, !m.isEmpty { parts.append("Module(\(m.count))") }
        if (collectionNames ?? []).isEmpty, let c = collectionIDs, !c.isEmpty { parts.append("Sammlungen(\(c.count))") }
        if (folderNames ?? []).isEmpty, let f = folderIDs, !f.isEmpty { parts.append("Ordner(\(f.count))") }
        if (documentTitles ?? []).isEmpty, let d = documentIDs, !d.isEmpty { parts.append("Dokumente(\(d.count))") }
        if let p = pathPrefixes, !p.isEmpty { parts.append("Unterordner: \(p.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))") }
        if let ps = pageStart, let pe = pageEnd {
            parts.append("S.\(ps)-\(pe)")
        } else if let ps = pageStart {
            parts.append("ab S.\(ps)")
        } else if let pe = pageEnd {
            parts.append("bis S.\(pe)")
        }
        return parts.isEmpty ? "Gesamte Bibliothek" : parts.joined(separator: " | ")
    }
}

public struct LibraryHierarchyFolderNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var collectionID: String
    public var name: String
    public var path: String
    public var isSelectedInUI: Bool
    public var documents: [LibraryDocument]

    public init(
        id: String,
        collectionID: String,
        name: String,
        path: String,
        isSelectedInUI: Bool,
        documents: [LibraryDocument]
    ) {
        self.id = id
        self.collectionID = collectionID
        self.name = name
        self.path = path
        self.isSelectedInUI = isSelectedInUI
        self.documents = documents
    }
}

public struct LibraryHierarchyCollectionNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var moduleID: String
    public var name: String
    public var description: String
    public var isSelectedInUI: Bool
    public var folders: [LibraryHierarchyFolderNode]
    public var directDocuments: [LibraryDocument]
    public var totalDocumentCount: Int

    public init(
        id: String,
        moduleID: String,
        name: String,
        description: String,
        isSelectedInUI: Bool,
        folders: [LibraryHierarchyFolderNode],
        directDocuments: [LibraryDocument],
        totalDocumentCount: Int
    ) {
        self.id = id
        self.moduleID = moduleID
        self.name = name
        self.description = description
        self.isSelectedInUI = isSelectedInUI
        self.folders = folders
        self.directDocuments = directDocuments
        self.totalDocumentCount = totalDocumentCount
    }
}

public struct LibraryHierarchyModuleNode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var iconName: String
    public var isSelectedInUI: Bool
    public var collections: [LibraryHierarchyCollectionNode]

    public init(
        id: String,
        name: String,
        iconName: String,
        isSelectedInUI: Bool,
        collections: [LibraryHierarchyCollectionNode]
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.isSelectedInUI = isSelectedInUI
        self.collections = collections
    }
}

public struct FigureResultItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { figureID }
    public var figureID: String
    public var documentID: String
    public var documentTitle: String
    public var documentPath: String
    public var collectionName: String
    public var moduleName: String
    public var pageNumber: Int
    public var breadcrumb: String
    public var label: String
    public var caption: String
    public var surroundingContext: String
    public var croppedImagePath: String
    public var fullPageImagePath: String
    public var bbox: NormalizedRect
    public var score: Double

    public init(
        figureID: String,
        documentID: String,
        documentTitle: String,
        documentPath: String,
        collectionName: String,
        moduleName: String,
        pageNumber: Int,
        breadcrumb: String,
        label: String,
        caption: String,
        surroundingContext: String,
        croppedImagePath: String,
        fullPageImagePath: String,
        bbox: NormalizedRect,
        score: Double
    ) {
        self.figureID = figureID
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.documentPath = documentPath
        self.collectionName = collectionName
        self.moduleName = moduleName
        self.pageNumber = pageNumber
        self.breadcrumb = breadcrumb
        self.label = label
        self.caption = caption
        self.surroundingContext = surroundingContext
        self.croppedImagePath = croppedImagePath
        self.fullPageImagePath = fullPageImagePath
        self.bbox = bbox
        self.score = score
    }
}

public struct SearchResultItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String { chunkID }
    public var rank: Int
    public var score: Double
    public var vectorScore: Double
    public var keywordScore: Double
    public var chunkID: String
    public var documentID: String
    public var documentTitle: String
    public var documentPath: String
    public var collectionID: String
    public var collectionName: String
    public var moduleID: String
    public var moduleName: String
    public var pageNumber: Int
    public var breadcrumb: String
    public var contextBefore: String
    public var matchedContent: String
    public var contextAfter: String
    public var fullPageImagePath: String
    public var figuresOnPage: [FigureResultItem]
    /// Number of neighbouring hits of the same document that were merged into this result.
    public var mergedNeighborCount: Int?
    /// Set when the hit is a figure (image search in the shared text/image vector space) instead of a text passage.
    public var figure: FigureResultItem?

    public var isFigure: Bool { figure != nil }

    /// A figure as a regular search hit: caption and recognised figure text stand in for the passage.
    public init(figureHit f: FigureResultItem, rank: Int, score: Double, collectionID: String = "", moduleID: String = "",
                allFiguresOnPage: [FigureResultItem]? = nil) {
        let pageFigs = (allFiguresOnPage?.isEmpty == false) ? allFiguresOnPage! : [f]
        self.init(
            rank: rank, score: score, vectorScore: f.score, keywordScore: 0,
            chunkID: "fig:" + f.figureID, documentID: f.documentID, documentTitle: f.documentTitle, documentPath: f.documentPath,
            collectionID: collectionID, collectionName: f.collectionName, moduleID: moduleID, moduleName: f.moduleName,
            pageNumber: f.pageNumber, breadcrumb: f.breadcrumb, contextBefore: "",
            matchedContent: [f.label, f.caption].filter { !$0.isEmpty }.joined(separator: ": "),
            contextAfter: f.surroundingContext, fullPageImagePath: f.fullPageImagePath, figuresOnPage: pageFigs
        )
        self.figure = f
    }

    public init(
        rank: Int,
        score: Double,
        vectorScore: Double,
        keywordScore: Double,
        chunkID: String,
        documentID: String,
        documentTitle: String,
        documentPath: String,
        collectionID: String,
        collectionName: String,
        moduleID: String,
        moduleName: String,
        pageNumber: Int,
        breadcrumb: String,
        contextBefore: String,
        matchedContent: String,
        contextAfter: String,
        fullPageImagePath: String,
        figuresOnPage: [FigureResultItem],
        mergedNeighborCount: Int? = nil
    ) {
        self.mergedNeighborCount = mergedNeighborCount
        self.rank = rank
        self.score = score
        self.vectorScore = vectorScore
        self.keywordScore = keywordScore
        self.chunkID = chunkID
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.documentPath = documentPath
        self.collectionID = collectionID
        self.collectionName = collectionName
        self.moduleID = moduleID
        self.moduleName = moduleName
        self.pageNumber = pageNumber
        self.breadcrumb = breadcrumb
        self.contextBefore = contextBefore
        self.matchedContent = matchedContent
        self.contextAfter = contextAfter
        self.fullPageImagePath = fullPageImagePath
        self.figuresOnPage = figuresOnPage
    }
}

public struct SearchResponsePayload: Codable, Sendable {
    public var query: String
    public var scope: ScopeFilter
    public var latencyMs: Double
    public var engine: String
    public var results: [SearchResultItem]

    public init(query: String, scope: ScopeFilter, latencyMs: Double, engine: String, results: [SearchResultItem]) {
        self.query = query
        self.scope = scope
        self.latencyMs = latencyMs
        self.engine = engine
        self.results = results
    }
}

public struct FigureSearchResponsePayload: Codable, Sendable {
    public var query: String
    public var scope: ScopeFilter
    public var latencyMs: Double
    public var engine: String
    public var figures: [FigureResultItem]

    public init(query: String, scope: ScopeFilter, latencyMs: Double, engine: String, figures: [FigureResultItem]) {
        self.query = query
        self.scope = scope
        self.latencyMs = latencyMs
        self.engine = engine
        self.figures = figures
    }
}

public struct DocumentOverviewPayload: Codable, Sendable {
    public var document: LibraryDocument
    public var collectionName: String
    public var moduleName: String
    public var figures: [FigureResultItem]

    public init(document: LibraryDocument, collectionName: String, moduleName: String, figures: [FigureResultItem]) {
        self.document = document
        self.collectionName = collectionName
        self.moduleName = moduleName
        self.figures = figures
    }
}

public struct AgentActivityEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var timestamp: Double
    public var source: String
    public var operation: String
    public var query: String
    public var scopeSummary: String
    public var resultCount: Int
    public var figureCount: Int
    public var latencyMs: Double
    public var engineUsed: String

    public init(
        id: String = UUID().uuidString,
        timestamp: Double = Date().timeIntervalSince1970,
        source: String,
        operation: String,
        query: String,
        scopeSummary: String,
        resultCount: Int,
        figureCount: Int,
        latencyMs: Double,
        engineUsed: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.operation = operation
        self.query = query
        self.scopeSummary = scopeSummary
        self.resultCount = resultCount
        self.figureCount = figureCount
        self.latencyMs = latencyMs
        self.engineUsed = engineUsed
    }
}

public struct SingleEngineMetrics: Codable, Equatable, Sendable {
    public var engine: EngineKind
    public var textLoadMs: Double
    public var visionLoadMs: Double
    public var queryLatencyP50Ms: Double
    public var queryLatencyP95Ms: Double
    public var batchTextThroughputChunksPerSec: Double
    public var imageEmbedLatencyMs: Double
    public var imageThroughputPerSec: Double
    public var peakMemoryMB: Double

    public init(
        engine: EngineKind,
        textLoadMs: Double,
        visionLoadMs: Double,
        queryLatencyP50Ms: Double,
        queryLatencyP95Ms: Double,
        batchTextThroughputChunksPerSec: Double,
        imageEmbedLatencyMs: Double,
        imageThroughputPerSec: Double,
        peakMemoryMB: Double
    ) {
        self.engine = engine
        self.textLoadMs = textLoadMs
        self.visionLoadMs = visionLoadMs
        self.queryLatencyP50Ms = queryLatencyP50Ms
        self.queryLatencyP95Ms = queryLatencyP95Ms
        self.batchTextThroughputChunksPerSec = batchTextThroughputChunksPerSec
        self.imageEmbedLatencyMs = imageEmbedLatencyMs
        self.imageThroughputPerSec = imageThroughputPerSec
        self.peakMemoryMB = peakMemoryMB
    }
}

public struct EngineBenchmarkReport: Codable, Equatable, Sendable {
    public var timestamp: Double
    public var hardwareModel: String
    public var llamaMetrics: SingleEngineMetrics?
    public var mlxMetrics: SingleEngineMetrics?
    public var meanTextCosineSimilarity: Double?
    public var minTextCosineSimilarity: Double?
    public var meanImageCosineSimilarity: Double?
    public var topKAgreementRate: Double?
    public var recommendation: String

    public init(
        timestamp: Double = Date().timeIntervalSince1970,
        hardwareModel: String,
        llamaMetrics: SingleEngineMetrics?,
        mlxMetrics: SingleEngineMetrics?,
        meanTextCosineSimilarity: Double?,
        minTextCosineSimilarity: Double?,
        meanImageCosineSimilarity: Double?,
        topKAgreementRate: Double?,
        recommendation: String
    ) {
        self.timestamp = timestamp
        self.hardwareModel = hardwareModel
        self.llamaMetrics = llamaMetrics
        self.mlxMetrics = mlxMetrics
        self.meanTextCosineSimilarity = meanTextCosineSimilarity
        self.minTextCosineSimilarity = minTextCosineSimilarity
        self.meanImageCosineSimilarity = meanImageCosineSimilarity
        self.topKAgreementRate = topKAgreementRate
        self.recommendation = recommendation
    }
}

public enum VectorMath {
    public static func encodeFloat32Blob(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func decodeFloat32Blob(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            return Array(ptr)
        }
    }

    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(count))
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    public static func dotProduct(_ a: [Float], _ bBlob: Data) -> Float {
        bBlob.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: Float.self)
            let count = min(a.count, ptr.count)
            guard count > 0, let base = ptr.baseAddress else { return 0 }
            var dot: Float = 0
            var normA: Float = 0
            var normB: Float = 0
            vDSP_dotpr(a, 1, base, 1, &dot, vDSP_Length(count))
            vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(count))
            vDSP_dotpr(base, 1, base, 1, &normB, vDSP_Length(count))
            let denom = sqrt(normA) * sqrt(normB)
            return denom > 1e-9 ? dot / denom : 0
        }
    }
}
