import Foundation
@preconcurrency import PDFKit
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
import CortexCore

public typealias NormalizedRect = CortexCore.NormalizedRect

public struct ExtractedFigureCandidate: Sendable {
    public let id: String
    public let documentID: String
    public let pageNumber: Int
    public var breadcrumb: String
    public let figureLabel: String
    public var captionText: String
    public var surroundingContext: String
    public let croppedImagePath: String
    public let fullPageImagePath: String
    public let bbox: NormalizedRect
    /// 64-bit average hash of the crop, used to detect logos/banners repeated on many pages.
    public var visualHash: UInt64 = 0
    /// True when the crop was matched to a caption line ("Abb. 3", "Tabelle 2").
    public var hasCaption: Bool = false
    /// True when this figure sits on a lecture slide, landscape page, or sparse diagram page (< 900 chars);
    /// false when it is an inline figure/table on a dense portrait script or textbook page (>= 900 chars).
    public var isSlideOrSparsePage: Bool = false

    /// Loads the cropped figure from disk on demand. The candidate deliberately holds no CGImage:
    /// `cropping(to:)` shares the full page bitmap, so keeping crops alive retained every rendered
    /// page of the document until indexing finished (several GB for large scripts).
    public func loadImage() -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: croppedImagePath) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Loads the full rendered page/slide image from disk on demand (used for slides or when `ImageVectorMode == .fullPage`).
    public func loadFullPageImage() -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: fullPageImagePath) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Loads the figure with its immediate surrounding context on the page (nearby headings, axis labels, and caption line)
    /// without including the rest of a dense A4 script/textbook page.
    public func loadContextualCropImage() -> CGImage? {
        if let pageImg = loadFullPageImage() {
            let w = Double(pageImg.width)
            let h = Double(pageImg.height)
            let padX = 0.06
            let padTop = 0.06
            let padBottom = 0.10
            let rx = max(0.0, bbox.x - padX)
            let ry = max(0.0, bbox.y - padTop)
            let rw = min(1.0 - rx, bbox.width + padX * 2)
            let rh = min(1.0 - ry, bbox.height + padTop + padBottom)
            let rect = CGRect(
                x: Int(rx * w),
                y: Int(ry * h),
                width: max(64, Int(rw * w)),
                height: max(64, Int(rh * h))
            )
            if let contextual = pageImg.cropping(to: rect) {
                return contextual
            }
        }
        return loadImage()
    }
}

public struct ExtractedDocumentPackage: Sendable {
    public var document: LibraryDocument
    public var chunks: [DocumentChunk]
    public var figureCandidates: [ExtractedFigureCandidate]
}

public enum PDFVisionPipeline {
    public struct PipelineError: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// - Parameter sourceURL: the original file when `fileURL` is a converted rendition (Word, PowerPoint …);
    ///   title, path and hash of the document come from the original.
    public static func processPDF(
        at fileURL: URL,
        sourceURL: URL? = nil,
        documentID: String = UUID().uuidString,
        collectionID: String,
        folderID: String? = nil,
        maxPages: Int = 50_000,
        progress: (@Sendable (String) -> Void)? = nil
    ) throws -> ExtractedDocumentPackage {
        try CortexPaths.ensureDirectories()
        guard let pdf = PDFDocument(url: fileURL) else {
            throw PipelineError("PDF konnte nicht geöffnet werden: \(fileURL.path)")
        }
        if pdf.isLocked {
            throw PipelineError("Das PDF '\(fileURL.lastPathComponent)' ist passwortgeschützt und gesperrt.")
        }
        guard pdf.pageCount > 0 else {
            throw PipelineError("Das PDF '\(fileURL.lastPathComponent)' enthält keine Seiten.")
        }

        let settings = CortexSettingsManager.shared.settings
        let original = sourceURL ?? fileURL
        let cancelGen = PowerManager.shared.currentCancelGeneration
        let cancelPath = (original.path as NSString).standardizingPath
        try PowerManager.shared.waitUntilIndexingAllowed(generation: cancelGen, path: cancelPath, progress: progress)

        let fileHash = try computeSHA256(of: original)
        let pageCount = min(pdf.pageCount, maxPages)
        let docTitle = CortexTextSanitizer.repairEncoding(original.deletingPathExtension().lastPathComponent)

        let docPagesDir = CortexPaths.pagesAssetsDir.appendingPathComponent(documentID, isDirectory: true)
        let docFiguresDir = CortexPaths.figuresAssetsDir.appendingPathComponent(documentID, isDirectory: true)
        try FileManager.default.createDirectory(at: docPagesDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docFiguresDir, withIntermediateDirectories: true)

        // 1. Extract TOC Outline
        var toc = extractTOC(from: pdf)
        let initialTocEmpty = toc.isEmpty

        // 2. Pass 1 per page: render, layout OCR, page text (accurate OCR for image-only slides), figures.
        // Pages are analysed in bounded parallel windows according to PowerManager's throttling mode so
        // multi-core CPU/Vision hardware is utilised while peak memory and battery rules stay strictly bounded.
        struct PageRecord: Sendable {
            let number: Int
            var text: String
            /// Largest text line in the upper part of the page (slide title candidate).
            let titleCandidate: String?
            /// Text recognised inside cropped figures that the PDF text layer does not contain.
            var figureOCR: [String]
            let landscape: Bool
        }
        struct PageWindowOutput: Sendable {
            let record: PageRecord
            let figures: [ExtractedFigureCandidate]
            let detectedHeading: TOCItem?
        }

        var records: [PageRecord] = []
        records.reserveCapacity(pageCount)
        var figureCandidates: [ExtractedFigureCandidate] = []

        let renderScale = max(1.0, min(3.0, Double(settings.renderDPI) / 72.0))

        final class WindowCollector: @unchecked Sendable {
            private let lock = NSLock()
            private var outputs: [PageWindowOutput?]
            private(set) var workerError: Error?

            init(count: Int) {
                self.outputs = [PageWindowOutput?](repeating: nil, count: count)
            }

            func store(_ output: PageWindowOutput, at index: Int) {
                lock.lock()
                outputs[index] = output
                lock.unlock()
            }

            func recordError(_ error: Error) {
                lock.lock()
                if workerError == nil { workerError = error }
                lock.unlock()
            }

            func collectedOutputs() -> [PageWindowOutput] {
                lock.lock()
                defer { lock.unlock() }
                return outputs.compactMap { $0 }
            }
        }

        let pdfLock = NSLock()
        let initialTocSnapshot = toc
        var batchStart = 0

        // Open CoreGraphics PDF document for reentrant, thread-safe parallel page rendering without locks
        let sharedCGDoc = CGPDFDocument(fileURL as CFURL)

        while batchStart < pageCount {
            if PowerManager.shared.isCancelled(generation: cancelGen, path: cancelPath) { throw CancellationError() }
            try PowerManager.shared.waitUntilIndexingAllowed(generation: cancelGen, path: cancelPath, progress: progress)

            let activeThrottle = PowerManager.shared.activeThrottlingMode()
            let windowSize: Int = {
                switch activeThrottle {
                case .ecoSilent:
                    return 1
                case .balanced:
                    return 3
                case .turbo:
                    return min(10, max(4, ProcessInfo.processInfo.activeProcessorCount))
                }
            }()

            let currentBatchStart = batchStart
            let batchEnd = min(pageCount, currentBatchStart + windowSize)
            let batchCount = batchEnd - currentBatchStart
            let firstPageNumber = currentBatchStart + 1
            progress?("Analysiere PDF '\(docTitle)' Seite \(firstPageNumber)–\(batchEnd)/\(pageCount) (Vision & Layout)...")

            struct FastPageMeta: Sendable {
                let pageIndex: Int
                let rawPageText: String
                let landscape: Bool
            }

            // Quick extraction of text layer and layout bounds under pdfLock (takes <0.5ms total for the whole batch)
            var extractedMetas: [FastPageMeta] = []
            extractedMetas.reserveCapacity(batchCount)
            pdfLock.lock()
            for offset in 0..<batchCount {
                let pIndex = currentBatchStart + offset
                if let p = pdf.page(at: pIndex) {
                    let str = (p.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let b = p.bounds(for: .mediaBox)
                    let rot = p.rotation % 180 != 0
                    let ls = rot ? b.height > b.width : b.width > b.height
                    extractedMetas.append(FastPageMeta(pageIndex: pIndex, rawPageText: str, landscape: ls))
                } else {
                    extractedMetas.append(FastPageMeta(pageIndex: pIndex, rawPageText: "", landscape: false))
                }
            }
            pdfLock.unlock()
            let metas = extractedMetas

            let collector = WindowCollector(count: batchCount)

            // Render and process pages in parallel across CPU and Neural Engine/GPU with ZERO lock contention
            DispatchQueue.concurrentPerform(iterations: batchCount) { offset in
                autoreleasepool {
                    if PowerManager.shared.isCancelled(generation: cancelGen, path: cancelPath) {
                        collector.recordError(CancellationError())
                        return
                    }
                    do {
                        try PowerManager.shared.waitUntilIndexingAllowed(generation: cancelGen, path: cancelPath, progress: progress)
                    } catch {
                        collector.recordError(error)
                        return
                    }

                    let pageIndex = currentBatchStart + offset
                    let pageNumber = pageIndex + 1
                    let meta = metas[offset]

                    // Render page: prefer lock-free thread-safe CoreGraphics CGPDFDocument
                    var pageCGImage: CGImage? = nil
                    if let cgPage = sharedCGDoc?.page(at: pageNumber) {
                        pageCGImage = renderCGPDFPage(cgPage, scale: renderScale)
                    }
                    if pageCGImage == nil {
                        pdfLock.lock()
                        if let pdfPage = pdf.page(at: pageIndex) {
                            pageCGImage = renderPDFPage(pdfPage, scale: renderScale)
                        }
                        pdfLock.unlock()
                    }

                    if PowerManager.shared.isCancelled(generation: cancelGen, path: cancelPath) {
                        collector.recordError(CancellationError())
                        return
                    }

                    let fullPageURL = docPagesDir.appendingPathComponent("page_\(pageNumber).png")

                    // Fast OCR for layout (caption lines, text boxes, title size) on every page.
                    let visionLines = pageCGImage.map { recognizeLinesWithBoxes(in: $0) } ?? []

                    var pageText = meta.rawPageText
                    if pageText.count < 80, let pageCGImage {
                        // Image-only slide or scan: accurate OCR with German/English language correction.
                        let accurate = recognizeLinesWithBoxes(in: pageCGImage, accurate: true)
                        if !accurate.isEmpty { pageText = accurate.map(\.text).joined(separator: "\n") }
                    }

                    if PowerManager.shared.isCancelled(generation: cancelGen, path: cancelPath) {
                        collector.recordError(CancellationError())
                        return
                    }

                    let heading = initialTocEmpty ? detectHeadingInPageText(pageText, pageNumber: pageNumber) : nil
                    let initialBreadcrumb = resolveBreadcrumb(docTitle: docTitle, pageNumber: pageNumber, toc: initialTocSnapshot)

                    var figureOCR: [String] = []
                    var figs: [ExtractedFigureCandidate] = []
                    if settings.enableFigureCropping, let pageCGImage {
                        figs = extractFiguresFromPage(
                            pageImage: pageCGImage,
                            pdfPage: nil,
                            visionLines: visionLines,
                            pageText: pageText,
                            documentID: documentID,
                            pageNumber: pageNumber,
                            breadcrumb: initialBreadcrumb,
                            figuresDir: docFiguresDir,
                            fullPagePath: fullPageURL.path
                        )
                        if !figs.isEmpty {
                            // Only write temporary page PNG when the page actually contains figures
                            try? savePNG(pageCGImage, to: fullPageURL)
                        }

                        // Smart figure OCR: on sparse slides/diagrams (where text only lives inside figures),
                        // extract embedded text. On dense textbook pages, the caption is already in pageText,
                        // eliminating massive redundant Vision OCR delays.
                        let isSparseSlideOrDiagram = meta.rawPageText.count < 200 || meta.landscape
                        if isSparseSlideOrDiagram {
                            for fig in figs {
                                if PowerManager.shared.isCancelled(generation: cancelGen, path: cancelPath) { break }
                                if let img = fig.loadImage() {
                                    let recs = recognizeLinesWithBoxes(in: img, accurate: activeThrottle != .turbo)
                                    figureOCR += recs.map(\.text)
                                }
                            }
                        }
                    }

                    let rec = PageRecord(
                        number: pageNumber,
                        text: pageText,
                        titleCandidate: titleCandidate(visionLines),
                        figureOCR: figureOCR,
                        landscape: meta.landscape
                    )
                    let out = PageWindowOutput(record: rec, figures: figs, detectedHeading: heading)
                    collector.store(out, at: offset)
                }
            }

            if let err = collector.workerError { throw err }

            for out in collector.collectedOutputs() {
                if initialTocEmpty, let h = out.detectedHeading {
                    toc.append(h)
                }
                records.append(out.record)
                figureCandidates.append(contentsOf: out.figures)
            }

            PowerManager.shared.throttlePause(generation: cancelGen, path: cancelPath)
            batchStart = batchEnd
        }

        // Pass 2: clean with the profile of the whole document, then title, breadcrumb and chunks.
        progress?("Bereinige Text von '\(docTitle)' ...")
        let profile = DocumentTextProfile.build(from: records.map(\.text))
        // Slides: landscape pages, or handouts/exports with little text per page.
        let medianChars = records.map(\.text.count).sorted()[safe: records.count / 2] ?? 0
        let slideDeck = !records.isEmpty
            && (Double(records.filter(\.landscape).count) / Double(records.count) >= 0.6 || (records.count >= 5 && medianChars < 900))
        let landscapeByPage = Dictionary(uniqueKeysWithValues: records.map { ($0.number, $0.landscape) })

        var rawChunks: [(page: Int, breadcrumb: String, text: String)] = []
        var firstPagesPreview: [String] = []
        var slideTOC: [TOCItem] = []
        var cleanedByPage: [Int: String] = [:]
        var titleByPage: [Int: String] = [:]
        var breadcrumbByPage: [Int: String] = [:]

        for rec in records {
            var cleaned = IndexTextPreparer.cleanPage(rec.text, page: rec.number, profile: profile)
            // Figure text is cleaned as one block so diagram labels are joined like page text.
            let figureText = IndexTextPreparer.cleanPage(rec.figureOCR.joined(separator: "\n"), page: rec.number, profile: profile)
            cleaned = IndexTextPreparer.mergeOCRLines(figureText.components(separatedBy: "\n"), into: cleaned)
            var breadcrumb = resolveBreadcrumb(docTitle: docTitle, pageNumber: rec.number, toc: toc)
            // The outline entry for this page, if it is a real title ("Mythos 1:") and not "Foliennummer 13".
            let outlineTitle = toc.last(where: { $0.pageNumber == rec.number }).map(\.title)
            let outlineIsGeneric = outlineTitle.map(IndexTextPreparer.isGenericOutlineLabel)
                ?? (toc.last(where: { $0.pageNumber <= rec.number }).map { IndexTextPreparer.isGenericOutlineLabel($0.title) } ?? true)
            if slideDeck {
                let title = IndexTextPreparer.slideTitle(cleanedPage: cleaned, ocrCandidate: rec.titleCandidate)
                cleaned = IndexTextPreparer.titleFirst(cleaned, title: title)
                if let title { titleByPage[rec.number] = title }
                if let title, outlineIsGeneric {
                    breadcrumb = "\(docTitle) > \(title)"
                }
                let tocTitle = outlineIsGeneric ? title : outlineTitle
                if let tocTitle, slideTOC.last?.title != tocTitle {
                    slideTOC.append(TOCItem(title: tocTitle, pageNumber: rec.number, level: 1))
                }
            }
            cleanedByPage[rec.number] = cleaned
            breadcrumbByPage[rec.number] = breadcrumb
            if firstPagesPreview.count < 3 && !cleaned.isEmpty {
                firstPagesPreview.append(String(cleaned.prefix(400)))
            }

            // A slide stays one chunk unless it is very long; prose is cut at line/sentence boundaries.
            let target = slideDeck ? max(settings.targetChunkSize, Int(Double(settings.targetChunkSize) * 1.6)) : settings.targetChunkSize
            // Short slides ("Theorem 1: Consensus under asynchronous network partitions") are still real content.
            let minLength = slideDeck ? min(settings.minChunkLength, 25) : settings.minChunkLength
            let segments = IndexTextPreparer.chunk(cleaned, target: target, overlap: settings.chunkOverlap)
                .filter { $0.count >= minLength }
            if !segments.isEmpty {
                for seg in segments { rawChunks.append((page: rec.number, breadcrumb: breadcrumb, text: seg)) }
            } else {
                let figs = figureCandidates.filter { $0.pageNumber == rec.number }
                if !figs.isEmpty {
                    // Purely visual page: keep a findable stub with the figure captions.
                    let figSummary = figs.map { "\($0.figureLabel): \($0.captionText)" }.joined(separator: " | ")
                    rawChunks.append((page: rec.number, breadcrumb: breadcrumb, text: "[Grafik-/Diagrammseite \(rec.number)] \(figSummary)"))
                }
            }
        }
        // Slide decks get an outline of real slide titles (replacing "Foliennummer N" entries).
        if slideDeck, !slideTOC.isEmpty, toc.isEmpty || toc.contains(where: { IndexTextPreparer.isGenericOutlineLabel($0.title) }) {
            toc = slideTOC
        }
        // Figures get the cleaned page text, the final breadcrumb, and slide-vs-script classification.
        for i in figureCandidates.indices {
            let n = figureCandidates[i].pageNumber
            let pageTextClean = cleanedByPage[n] ?? ""
            figureCandidates[i].surroundingContext = String(pageTextClean.prefix(600))
            figureCandidates[i].breadcrumb = breadcrumbByPage[n] ?? figureCandidates[i].breadcrumb
            figureCandidates[i].isSlideOrSparsePage = slideDeck || (landscapeByPage[n] ?? false) || pageTextClean.count < 900
            // Uncaptioned crops: read the caption from the PDF text layer around the figure (exact text with umlauts);
            // the fast layout OCR next to the image is only the fallback, after removing running headers and noise.
            if !figureCandidates[i].hasCaption, let pdfPage = pdf.page(at: n - 1),
               let fromPDF = pdfCaption(for: figureCandidates[i].bbox, on: pdfPage, pageNumber: n, profile: profile) {
                figureCandidates[i].captionText = fromPDF
            } else if let caption = IndexTextPreparer.cleanCaption(figureCandidates[i].captionText, page: n, profile: profile) {
                figureCandidates[i].captionText = caption
            } else {
                figureCandidates[i].captionText = titleByPage[n]
                    ?? sectionTitle(fromBreadcrumb: figureCandidates[i].breadcrumb)
                    ?? figureCandidates[i].figureLabel
            }
        }

        // 2b. Drop uncaptioned crops that repeat on 3+ pages (logos, header banners, slide backgrounds)
        let repeated = FigureFilter.repeatedHashes(figureCandidates.filter { !$0.hasCaption }.map { ($0.visualHash, $0.pageNumber) })
        if !repeated.isEmpty {
            let (drop, keep) = figureCandidates.reduce(into: ([ExtractedFigureCandidate](), [ExtractedFigureCandidate]())) { acc, c in
                if !c.hasCaption && repeated.contains(where: { FigureFilter.hamming($0, c.visualHash) <= 5 }) { acc.0.append(c) } else { acc.1.append(c) }
            }
            let keptPages = Set(keep.map(\.pageNumber))
            for c in drop {
                try? FileManager.default.removeItem(atPath: c.croppedImagePath)
                if !keptPages.contains(c.pageNumber) {
                    try? FileManager.default.removeItem(atPath: c.fullPageImagePath)
                }
            }
            figureCandidates = keep
        }

        // 3. Build Doubly-Linked DocumentChunk Array (prev_chunk_id / next_chunk_id)
        let chunkIDs = (0..<rawChunks.count).map { "chk_\(documentID)_\($0)" }
        var chunks: [DocumentChunk] = []
        chunks.reserveCapacity(rawChunks.count)

        for (i, item) in rawChunks.enumerated() {
            let prevID = i > 0 ? chunkIDs[i - 1] : nil
            let nextID = (i + 1) < rawChunks.count ? chunkIDs[i + 1] : nil
            chunks.append(DocumentChunk(
                id: chunkIDs[i],
                documentID: documentID,
                pageNumber: item.page,
                chunkIndex: i,
                prevChunkID: prevID,
                nextChunkID: nextID,
                breadcrumb: item.breadcrumb,
                content: item.text,
                embedding: []
            ))
        }

        // 4. Build Abstract Summary
        let tocPreview = toc.prefix(12).map { "• S. \($0.pageNumber): \($0.title)" }.joined(separator: "\n")
        let introSnippet = firstPagesPreview.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        let abstractSummary = """
        Dokument: \(docTitle) (\(pageCount) Seiten, \(chunks.count) Text-Abschnitte, \(figureCandidates.count) extrahierte Grafiken/Diagramme).
        Struktur / Kapitel:
        \(tocPreview.isEmpty ? "(Keine explizite Kapitel-Gliederung)" : tocPreview)
        Vorschau: \(String(introSnippet.prefix(500)))
        """

        let doc = LibraryDocument(
            id: documentID,
            collectionID: collectionID,
            folderID: folderID,
            title: docTitle,
            filePath: original.path,
            fileHash: fileHash,
            pageCount: pageCount,
            abstractSummary: abstractSummary,
            toc: toc,
            indexStatus: "processing",
            engineUsed: "llama",
            indexedAt: Date().timeIntervalSince1970,
            chunkCount: chunks.count,
            figureCount: figureCandidates.count
        )

        return ExtractedDocumentPackage(document: doc, chunks: chunks, figureCandidates: figureCandidates)
    }

    // MARK: - Figure Detection & Cropping (Apple Vision + Connected Visual Regions)

    private struct RecognizedLine {
        let text: String
        /// Normalized in top-left coordinate system: (x: 0..1, y: 0..1 from top, width, height)
        let topLeftRect: NormalizedRect
    }

    /// Fast mode for layout analysis; accurate mode (German/English language correction) where the text is used.
    private static func recognizeLinesWithBoxes(in cgImage: CGImage, accurate: Bool = false) -> [RecognizedLine] {
        var output: [RecognizedLine] = []
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = accurate
        if accurate { request.recognitionLanguages = ["de-DE", "en-US"] }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        guard let observations = request.results else { return [] }
        for obs in observations {
            guard let topCandidate = obs.topCandidates(1).first else { continue }
            let b = obs.boundingBox // Vision uses bottom-left origin
            let topLeftY = 1.0 - b.origin.y - b.size.height
            output.append(RecognizedLine(
                text: topCandidate.string,
                topLeftRect: NormalizedRect(
                    x: Double(b.origin.x),
                    y: Double(max(0, topLeftY)),
                    width: Double(b.size.width),
                    height: Double(b.size.height)
                )
            ))
        }
        return output.sorted { $0.topLeftRect.y < $1.topLeftRect.y }
    }

    /// Slide title candidate: the tallest readable line in the upper 40 % of the page,
    /// preferring multi-word titles in the top quarter over isolated all-caps diagram words.
    private static func titleCandidate(_ lines: [RecognizedLine]) -> String? {
        let candidates = lines.filter {
            $0.topLeftRect.y < 0.4
                && $0.text.filter(\.isLetter).count >= 3
                && !ChunkDisplayCleaner.isGarbled($0.text)
                && !IndexTextPreparer.isLogoOrNoiseFragment($0.text)
                && !IndexTextPreparer.isGenericOutlineLabel($0.text)
        }
        guard !candidates.isEmpty else { return nil }
        func score(_ line: RecognizedLine) -> Double {
            let words = line.text.split(separator: " ").filter { $0.filter(\.isLetter).count >= 2 }
            let letters = line.text.filter(\.isLetter)
            let isSingleAllCapsWord = words.count <= 1 && !letters.isEmpty && letters.allSatisfy(\.isUppercase)
            var s = line.topLeftRect.height
            if line.topLeftRect.y < 0.22 { s *= 1.25 }
            if words.count >= 2 { s *= 1.35 }
            if isSingleAllCapsWord && line.topLeftRect.y > 0.16 { s *= 0.40 }
            return s
        }
        return candidates.max { score($0) < score($1) }?.text
    }

    /// On-demand figure cropping for a single page of an already-indexed document (e.g. when an MCP agent
    /// queries `cortex_get_page_figures` for a high-scoring page).
    public static func extractFiguresForPageOnDemand(
        document: LibraryDocument,
        pageNumber: Int
    ) -> [ExtractedFigureCandidate] {
        guard pageNumber >= 1 else { return [] }
        try? CortexPaths.ensureDirectories()
        let docPagesDir = CortexPaths.pagesAssetsDir.appendingPathComponent(document.id, isDirectory: true)
        let docFiguresDir = CortexPaths.figuresAssetsDir.appendingPathComponent(document.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: docFiguresDir, withIntermediateDirectories: true)

        let fullPageURL = docPagesDir.appendingPathComponent("page_\(pageNumber).png")
        var pageCGImage: CGImage?
        if let src = CGImageSourceCreateWithURL(fullPageURL as CFURL, nil) {
            pageCGImage = CGImageSourceCreateImageAtIndex(src, 0, nil)
        }

        var pageText = ""
        let readablePath = DocumentFormats.readablePDFPath(for: document.filePath)
        let docURL = URL(fileURLWithPath: readablePath)
        if let pdf = PDFDocument(url: docURL), pageNumber <= pdf.pageCount, let pdfPage = pdf.page(at: pageNumber - 1) {
            pageText = (pdfPage.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageCGImage == nil {
                let scale = max(1.0, min(3.0, Double(CortexSettingsManager.shared.settings.renderDPI) / 72.0))
                pageCGImage = renderPDFPage(pdfPage, scale: scale)
            }
        }

        guard let cgImage = pageCGImage else { return [] }
        let visionLines = recognizeLinesWithBoxes(in: cgImage)
        if pageText.count < 40 {
            let acc = recognizeLinesWithBoxes(in: cgImage, accurate: true)
            if !acc.isEmpty { pageText = acc.map(\.text).joined(separator: "\n") }
        }
        let breadcrumb = resolveBreadcrumb(docTitle: document.title, pageNumber: pageNumber, toc: document.toc)
        var figs = extractFiguresFromPage(
            pageImage: cgImage,
            pdfPage: nil,
            visionLines: visionLines,
            pageText: pageText,
            documentID: document.id,
            pageNumber: pageNumber,
            breadcrumb: breadcrumb,
            figuresDir: docFiguresDir,
            fullPagePath: fullPageURL.path
        )
        if figs.isEmpty {
            // Fallback: save the slide/page image into figuresDir when no sub-boxes were segmented
            let fallbackURL = docFiguresDir.appendingPathComponent("p\(pageNumber)_full.png")
            try? savePNG(cgImage, to: fallbackURL)
            let slideTitle = titleCandidate(visionLines) ?? "Seite \(pageNumber)"
            figs.append(ExtractedFigureCandidate(
                id: "fig_\(document.id)_p\(pageNumber)_full",
                documentID: document.id,
                pageNumber: pageNumber,
                breadcrumb: breadcrumb,
                figureLabel: "Folie/Seite \(pageNumber)",
                captionText: slideTitle,
                surroundingContext: String(pageText.prefix(600)),
                croppedImagePath: fallbackURL.path,
                fullPageImagePath: fullPageURL.path,
                bbox: NormalizedRect(x: 0, y: 0, width: 1, height: 1),
                visualHash: 0,
                hasCaption: true,
                isSlideOrSparsePage: true
            ))
        }
        return figs
    }

    /// Ensures that `fig.croppedImagePath` exists on disk as a ready-to-use cropped PNG.
    /// If the file was removed or the figure only had a bbox, renders the PDF page and crops `fig.bbox` on the fly.
    @discardableResult
    public static func ensureCroppedFigureExists(_ fig: FigureResultItem) -> String {
        if !fig.croppedImagePath.isEmpty, FileManager.default.fileExists(atPath: fig.croppedImagePath) {
            AssetCache.touch(fig.croppedImagePath)   // keeps recently used crops in the bounded cache
            return fig.croppedImagePath
        }
        let docFiguresDir = CortexPaths.figuresAssetsDir.appendingPathComponent(fig.documentID, isDirectory: true)
        try? FileManager.default.createDirectory(at: docFiguresDir, withIntermediateDirectories: true)
        let targetURL = fig.croppedImagePath.isEmpty
            ? docFiguresDir.appendingPathComponent("p\(fig.pageNumber)_\(fig.figureID).png")
            : URL(fileURLWithPath: fig.croppedImagePath)
        let readablePath = DocumentFormats.readablePDFPath(for: fig.documentPath)
        guard let pdf = PDFDocument(url: URL(fileURLWithPath: readablePath)),
              fig.pageNumber >= 1, fig.pageNumber <= pdf.pageCount,
              let pdfPage = pdf.page(at: fig.pageNumber - 1) else {
            return fig.croppedImagePath
        }
        let scale = max(1.0, min(3.0, Double(CortexSettingsManager.shared.settings.renderDPI) / 72.0))
        guard let pageImg = renderPDFPage(pdfPage, scale: scale) else { return fig.croppedImagePath }
        let w = Double(pageImg.width)
        let h = Double(pageImg.height)
        let b = fig.bbox
        let rect = CGRect(
            x: Int(max(0.0, min(1.0, b.x)) * w),
            y: Int(max(0.0, min(1.0, b.y)) * h),
            width: max(64, Int(max(0.05, min(1.0 - b.x, b.width)) * w)),
            height: max(64, Int(max(0.05, min(1.0 - b.y, b.height)) * h))
        )
        let outImg = pageImg.cropping(to: rect) ?? pageImg
        try? savePNG(outImg, to: targetURL)
        return targetURL.path
    }

    private static func extractFiguresFromPage(
        pageImage: CGImage,
        pdfPage: PDFPage?,
        visionLines: [RecognizedLine],
        pageText: String,
        documentID: String,
        pageNumber: Int,
        breadcrumb: String,
        figuresDir: URL,
        fullPagePath: String
    ) -> [ExtractedFigureCandidate] {
        let imgW = pageImage.width
        let imgH = pageImage.height
        guard imgW > 100, imgH > 100 else { return [] }

        // 1. Identify caption lines (Abb. X, Fig. X, Schema, Diagramm, Tabelle)
        let captionPattern = #"^(Abb\.|Abbildung|Fig\.|Figure|Schema|Scheme|Diagramm|Diagram|Tab\.|Tabelle|Table|Chart|Graph)\s*[0-9A-Za-z\.\-]*"#
        let captionRegex = try? NSRegularExpression(pattern: captionPattern, options: [.caseInsensitive])

        var captionLines: [(index: Int, line: RecognizedLine, label: String)] = []
        for (idx, line) in visionLines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let regex = captionRegex else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
               let r = Range(match.range, in: trimmed) {
                let label = String(trimmed[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                captionLines.append((idx, line, label))
            }
        }

        // 2. Compute non-text visual occupancy grid (48 cols x 64 rows)
        let detectedBoxes = detectNonTextVisualBoxes(pageImage: pageImage, textLines: visionLines)

        var finalFigures: [ (bbox: NormalizedRect, label: String, caption: String) ] = []

        // Match detected visual boxes with nearest caption, or keep standalone significant visual diagrams
        var usedCaptions: Set<Int> = []
        for box in detectedBoxes {
            var bestCaptionIdx: Int?
            var bestDist = 1.0
            for (cIdx, cap) in captionLines.enumerated() {
                let boxBottom = box.y + box.height
                let capTop = cap.line.topLeftRect.y
                let verticalDist = abs(capTop - boxBottom)
                let verticalAboveDist = abs(box.y - (cap.line.topLeftRect.y + cap.line.topLeftRect.height))
                let d = min(verticalDist, verticalAboveDist)
                if d < 0.25 && d < bestDist {
                    bestDist = d
                    bestCaptionIdx = cIdx
                }
            }

            if let cIdx = bestCaptionIdx {
                usedCaptions.insert(cIdx)
                let capEntry = captionLines[cIdx]
                // Gather multi-line caption if the next line is immediately below
                var fullCap = capEntry.line.text
                if capEntry.index + 1 < visionLines.count {
                    let nextLine = visionLines[capEntry.index + 1]
                    if nextLine.topLeftRect.y - (capEntry.line.topLeftRect.y + capEntry.line.topLeftRect.height) < 0.025 {
                        fullCap += " " + nextLine.text
                    }
                }
                finalFigures.append((bbox: box, label: capEntry.label, caption: fullCap))
            } else if box.width * box.height >= max(0.04, CortexSettingsManager.shared.settings.minFigureAreaRatio),
                      FigureFilter.isPlausibleStandalone(box),
                      !FigureFilter.isPlainTextBlock(box, lines: visionLines.map(\.topLeftRect)) {
                // Significant standalone diagram/figure on page/slide
                let fallbackLabel = "Abb. S.\(pageNumber)-\(finalFigures.count + 1)"
                let nearbyText = findNearestText(to: box, in: visionLines)
                finalFigures.append((bbox: box, label: fallbackLabel, caption: nearbyText))
            }
        }

        // 3. Also handle captions that didn't match a grid box (e.g. light vector line diagram directly above caption)
        for (cIdx, capEntry) in captionLines.enumerated() where !usedCaptions.contains(cIdx) {
            let capY = capEntry.line.topLeftRect.y
            let isTable = capEntry.label.lowercased().hasPrefix("tab")
            let syntheticBox: NormalizedRect
            if isTable {
                // Table captions stand above the table: take the region below the caption.
                let top = min(0.95, capY + capEntry.line.topLeftRect.height + 0.005)
                syntheticBox = NormalizedRect(x: 0.06, y: top, width: 0.88, height: max(0.05, min(0.42, 0.97 - top)))
            } else {
                let regionTop = max(0.05, capY - 0.36)
                let regionH = max(0.15, capY - regionTop - 0.01)
                syntheticBox = NormalizedRect(x: 0.08, y: regionTop, width: 0.84, height: regionH)
            }
            finalFigures.append((bbox: syntheticBox, label: capEntry.label, caption: capEntry.line.text))
        }

        // 4. Crop and save up to 4 top figures per page
        var results: [ExtractedFigureCandidate] = []
        for (idx, item) in finalFigures.prefix(4).enumerated() {
            let pad = 0.015
            let rx = max(0.0, item.bbox.x - pad)
            let ry = max(0.0, item.bbox.y - pad)
            let rw = min(1.0 - rx, item.bbox.width + pad * 2)
            let rh = min(1.0 - ry, item.bbox.height + pad * 2)

            let cropRect = CGRect(
                x: Int(rx * Double(imgW)),
                y: Int(ry * Double(imgH)),
                width: max(64, Int(rw * Double(imgW))),
                height: max(64, Int(rh * Double(imgH)))
            )
            guard let cropped = pageImage.cropping(to: cropRect) else { continue }
            let captioned = !item.label.hasPrefix("Abb. S.\(pageNumber)-")
            let stats = FigureFilter.visualStats(cropped)
            // Near-uniform crops (empty boxes, coloured backgrounds) carry no information.
            if !captioned && stats.contrast < 0.035 { continue }

            let figID = "fig_\(documentID)_p\(pageNumber)_\(idx + 1)"
            let cropURL = figuresDir.appendingPathComponent("p\(pageNumber)_fig\(idx + 1).png")
            try? savePNG(cropped, to: cropURL)

            let contextSnippet = String(pageText.prefix(600))
            results.append(ExtractedFigureCandidate(
                id: figID,
                documentID: documentID,
                pageNumber: pageNumber,
                breadcrumb: breadcrumb,
                figureLabel: item.label,
                captionText: item.caption.isEmpty ? "\(item.label) (\(breadcrumb))" : item.caption,
                surroundingContext: contextSnippet,
                croppedImagePath: cropURL.path,
                fullPageImagePath: fullPagePath,
                bbox: NormalizedRect(x: rx, y: ry, width: rw, height: rh),
                visualHash: stats.hash,
                hasCaption: captioned
            ))
        }

        return results
    }

    private static func detectNonTextVisualBoxes(pageImage: CGImage, textLines: [RecognizedLine]) -> [NormalizedRect] {
        let gridW = 48
        let gridH = 64
        let w = pageImage.width
        let h = pageImage.height

        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: &rgba,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return [] }
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(pageImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Build text mask on grid (only mask pure body text lines wider than 25% of page)
        var textMask = [Bool](repeating: false, count: gridW * gridH)
        for line in textLines where line.topLeftRect.width > 0.22 && line.topLeftRect.height < 0.045 {
            let gx0 = max(0, Int(line.topLeftRect.x * Double(gridW)))
            let gx1 = min(gridW - 1, Int((line.topLeftRect.x + line.topLeftRect.width) * Double(gridW)))
            let gy0 = max(0, Int(line.topLeftRect.y * Double(gridH)))
            let gy1 = min(gridH - 1, Int((line.topLeftRect.y + line.topLeftRect.height) * Double(gridH)))
            for gy in gy0...gy1 {
                for gx in gx0...gx1 {
                    textMask[gy * gridW + gx] = true
                }
            }
        }

        // Check visual ink & color saturation per cell
        var visualGrid = [Bool](repeating: false, count: gridW * gridH)
        let cellW = max(1, w / gridW)
        let cellH = max(1, h / gridH)

        for gy in 2..<(gridH - 2) {
            for gx in 1..<(gridW - 1) {
                if textMask[gy * gridW + gx] { continue }
                var nonWhiteCount = 0
                var coloredCount = 0
                let sampleStep = 2
                var totalSamples = 0
                for py in stride(from: gy * cellH, to: min(h, (gy + 1) * cellH), by: sampleStep) {
                    for px in stride(from: gx * cellW, to: min(w, (gx + 1) * cellW), by: sampleStep) {
                        totalSamples += 1
                        let off = (py * w + px) * 4
                        let r = Int(rgba[off])
                        let g = Int(rgba[off + 1])
                        let b = Int(rgba[off + 2])
                        let lum = (r + g + b) / 3
                        let sat = max(abs(r - g), max(abs(g - b), abs(r - b)))
                        if lum < 238 { nonWhiteCount += 1 }
                        if sat > 28 { coloredCount += 1 }
                    }
                }
                if totalSamples > 0 {
                    let inkRatio = Double(nonWhiteCount) / Double(totalSamples)
                    let colorRatio = Double(coloredCount) / Double(totalSamples)
                    if inkRatio > 0.08 || colorRatio > 0.04 {
                        visualGrid[gy * gridW + gx] = true
                    }
                }
            }
        }

        // Dilate 1 cell to bridge dashed lines and diagram labels
        var dilated = visualGrid
        for gy in 1..<(gridH - 1) {
            for gx in 1..<(gridW - 1) where visualGrid[gy * gridW + gx] {
                for dy in -1...1 {
                    for dx in -1...1 {
                        dilated[(gy + dy) * gridW + (gx + dx)] = true
                    }
                }
            }
        }

        // Connected components BFS
        var visited = [Bool](repeating: false, count: gridW * gridH)
        var boxes: [NormalizedRect] = []

        for gy in 0..<gridH {
            for gx in 0..<gridW {
                let startIdx = gy * gridW + gx
                guard dilated[startIdx] && !visited[startIdx] else { continue }
                var queue = [(gx, gy)]
                visited[startIdx] = true
                var minX = gx, maxX = gx, minY = gy, maxY = gy
                var count = 0

                while !queue.isEmpty {
                    let (cx, cy) = queue.removeLast()
                    count += 1
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)

                    for (nx, ny) in [(cx-1, cy), (cx+1, cy), (cx, cy-1), (cx, cy+1)] {
                        if nx >= 0, nx < gridW, ny >= 0, ny < gridH {
                            let nIdx = ny * gridW + nx
                            if dilated[nIdx] && !visited[nIdx] {
                                visited[nIdx] = true
                                queue.append((nx, ny))
                            }
                        }
                    }
                }

                let bw = Double(maxX - minX + 1) / Double(gridW)
                let bh = Double(maxY - minY + 1) / Double(gridH)
                // Keep meaningful visual regions (diagrams, charts, anatomy figures)
                if bw >= 0.16 && bh >= 0.10 && (bw * bh) >= 0.035 && count >= 18 {
                    boxes.append(NormalizedRect(
                        x: Double(minX) / Double(gridW),
                        y: Double(minY) / Double(gridH),
                        width: bw,
                        height: bh
                    ))
                }
            }
        }

        return boxes.sorted { ($0.width * $0.height) > ($1.width * $1.height) }
    }

    /// Caption from the PDF text layer around a figure (normalized top-left `bbox` of the rendered page): the band below
    /// the figure, then above it, then the labels inside it. A line starting with "Abb./Tab./Fig." wins. nil without
    /// a usable text layer there (scans, image-only slides) or on rotated pages.
    public static func pdfCaption(for bbox: NormalizedRect, on page: PDFPage, pageNumber: Int,
                                  profile: DocumentTextProfile = .empty) -> String? {
        guard page.rotation % 180 == 0 else { return nil }
        let mb = page.bounds(for: .mediaBox)
        func pageRect(x: Double, top: Double, width: Double, height: Double) -> CGRect {
            CGRect(x: mb.minX + x * mb.width, y: mb.minY + (1 - top - height) * mb.height,
                   width: width * mb.width, height: height * mb.height)
        }
        let x = max(0, bbox.x - 0.02)
        let w = min(1 - x, bbox.width + 0.04)
        let bottom = min(1, bbox.y + bbox.height)
        let bands: [CGRect] = [
            pageRect(x: x, top: bottom, width: w, height: min(0.09, 1 - bottom)),          // below
            pageRect(x: x, top: max(0, bbox.y - 0.06), width: w, height: min(0.06, bbox.y)), // above
            pageRect(x: bbox.x, top: bbox.y, width: bbox.width, height: bbox.height),        // inside (labels)
        ]
        // Whole lines only: a rectangle cuts words at its edges ("nige Stunden …").
        let raws = bands.compactMap { r -> String? in
            guard r.width > 4, r.height > 4, let sel = page.selection(for: r) else { return nil }
            sel.extendForLineBoundaries()
            return sel.string
        }
        // A real caption line ("Abb. 3 …", "F-1.6 Credé-Handgriff") in any band wins over surrounding prose.
        for raw in raws {
            if let line = IndexTextPreparer.captionLine(in: raw),
               let caption = IndexTextPreparer.cleanCaption(line, page: pageNumber, profile: profile) {
                return caption
            }
        }
        return raws.lazy.compactMap { IndexTextPreparer.cleanCaption($0, page: pageNumber, profile: profile) }.first
    }

    /// Last part of a breadcrumb ("Doc > Kapitel > Abschnitt" → "Abschnitt"), unless it is a generic page label.
    static func sectionTitle(fromBreadcrumb breadcrumb: String) -> String? {
        guard let last = breadcrumb.components(separatedBy: " > ").dropFirst().last,
              !IndexTextPreparer.isGenericOutlineLabel(last), !last.hasPrefix("Seite ") else { return nil }
        return last
    }

    private static func findNearestText(to box: NormalizedRect, in lines: [RecognizedLine]) -> String {
        let boxBottom = box.y + box.height
        let candidates = lines.filter { line in
            guard !IndexTextPreparer.isLogoOrNoiseFragment(line.text), !ChunkDisplayCleaner.isGarbled(line.text) else { return false }
            let distBelow = abs(line.topLeftRect.y - boxBottom)
            let distAbove = abs(box.y - (line.topLeftRect.y + line.topLeftRect.height))
            return min(distBelow, distAbove) < 0.08
        }
        return candidates.prefix(2).map(\.text).joined(separator: " ")
    }

    // MARK: - Rendering & Text Helpers

    public static func renderPDFPage(_ page: PDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Renders a CGPDFPage directly via CoreGraphics C API (thread-safe, reentrant, zero lock contention).
    public static func renderCGPDFPage(_ page: CGPDFPage, scale: CGFloat = 2.0) -> CGImage? {
        let bounds = page.getBoxRect(.mediaBox)
        let width = max(1, Int(bounds.width * scale))
        let height = max(1, Int(bounds.height * scale))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.setFillColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    public static func savePNG(_ image: CGImage, to url: URL, maxPixel: Int = 1400) throws {
        var outImage = image
        let maxDim = max(image.width, image.height)
        if maxPixel > 0, maxDim > maxPixel {
            let ratio = Double(maxPixel) / Double(maxDim)
            let nw = max(1, Int((Double(image.width) * ratio).rounded()))
            let nh = max(1, Int((Double(image.height) * ratio).rounded()))
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            if let ctx = CGContext(
                data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: nw * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) {
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
                if let scaled = ctx.makeImage() { outImage = scaled }
            }
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw PipelineError("Cannot create PNG destination at \(url.path)")
        }
        CGImageDestinationAddImage(dest, outImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw PipelineError("Failed to write PNG to \(url.path)")
        }
    }

    private static func extractTOC(from pdf: PDFDocument) -> [TOCItem] {
        guard let root = pdf.outlineRoot else { return [] }
        var items: [TOCItem] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                let label = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !label.isEmpty, let page = child.destination?.page {
                    let pageIdx = pdf.index(for: page)
                    if pageIdx != NSNotFound {
                        items.append(TOCItem(title: label, pageNumber: pageIdx + 1, level: level))
                    }
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 1)
        return items
    }

    private static func detectHeadingInPageText(_ text: String, pageNumber: Int) -> TOCItem? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.count >= 4, first.count <= 90 else { return nil }
        let headingPattern = #"^([0-9]+(\.[0-9]+)*\s+[A-ZÄÖÜ]|Kapitel\s+[0-9]+|Vorlesung\s+[0-9]+|Teil\s+[0-9IVX]+)"#
        if first.range(of: headingPattern, options: .regularExpression) != nil {
            return TOCItem(title: first, pageNumber: pageNumber, level: 1)
        }
        return nil
    }

    private static func resolveBreadcrumb(docTitle: String, pageNumber: Int, toc: [TOCItem]) -> String {
        let active = toc.filter { $0.pageNumber <= pageNumber }
        guard !active.isEmpty else { return "\(docTitle) > Seite \(pageNumber)" }
        var levelMap: [Int: String] = [:]
        for item in active {
            levelMap[item.level] = item.title
            for deeper in levelMap.keys where deeper > item.level {
                levelMap.removeValue(forKey: deeper)
            }
        }
        let path = levelMap.keys.sorted().compactMap { levelMap[$0] }.joined(separator: " > ")
        return "\(docTitle) > \(path)"
    }

    public static func computeSHA256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}


// MARK: - Figure plausibility filters

public enum FigureFilter {
    /// Rejects banner strips and near full-page backgrounds that have no caption.
    public static func isPlausibleStandalone(_ box: NormalizedRect) -> Bool {
        let aspect = box.width / max(box.height, 0.001)
        if aspect > 7 || aspect < 1.0 / 7 { return false }          // header/footer bars, side strips
        if box.width * box.height > 0.85 { return false }          // whole slide background
        if box.height < 0.06 || box.width < 0.08 { return false }  // tiny icons
        return true
    }

    /// 8×8 average hash and a contrast measure (std-dev of 16×16 grey values, 0…1).
    public static func visualStats(_ image: CGImage) -> (hash: UInt64, contrast: Double) {
        func grey(_ size: Int) -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: size * size)
            let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                          bytesPerRow: size, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                ctx.interpolationQuality = .medium
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
                return true
            }
            return ok ? pixels : []
        }
        let small = grey(8)
        var hash: UInt64 = 0
        if small.count == 64 {
            let mean = small.reduce(0) { $0 + Int($1) } / 64
            for (i, v) in small.enumerated() where Int(v) > mean { hash |= (1 << UInt64(i)) }
        }
        let mid = grey(16)
        var contrast = 0.0
        if !mid.isEmpty {
            let m = Double(mid.reduce(0) { $0 + Int($1) }) / Double(mid.count)
            let variance = mid.reduce(0.0) { $0 + pow(Double($1) - m, 2) } / Double(mid.count)
            contrast = sqrt(variance) / 255.0
        }
        return (hash, contrast)
    }

    public static func hamming(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }

    /// A region mostly covered by text lines that all start in one column is running text (bullet list),
    /// not a figure. Tables keep several text columns and are therefore not rejected.
    public static func isPlainTextBlock(_ box: NormalizedRect, lines: [NormalizedRect]) -> Bool {
        let inside = lines.filter { l in
            let cx = l.x + l.width / 2, cy = l.y + l.height / 2
            return cx >= box.x && cx <= box.x + box.width && cy >= box.y && cy <= box.y + box.height
        }
        guard inside.count >= 2 else { return false }
        let covered = inside.reduce(0.0) { $0 + $1.width * $1.height }
        let coverage = covered / max(box.width * box.height, 0.0001)
        var columns: [Int: Int] = [:]
        for l in inside { columns[Int((l.x / 0.04).rounded()), default: 0] += 1 }
        let realColumns = columns.values.filter { $0 >= 2 }.count
        return coverage > 0.3 && realColumns < 2
    }

    /// Hashes that occur (within Hamming distance 5) on at least `minPages` different pages.
    public static func repeatedHashes(_ items: [(hash: UInt64, page: Int)], minPages: Int = 3) -> [UInt64] {
        var result: [UInt64] = []
        for item in items where item.hash != 0 && !result.contains(where: { hamming($0, item.hash) <= 5 }) {
            let pages = Set(items.filter { hamming($0.hash, item.hash) <= 5 }.map(\.page))
            if pages.count >= minPages { result.append(item.hash) }
        }
        return result
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
