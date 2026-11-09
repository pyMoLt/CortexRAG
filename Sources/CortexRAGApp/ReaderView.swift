import SwiftUI
import PDFKit
import Quartz
import AppKit
import CortexCore

// MARK: - Controller (owns the PDFView, performs jumps and highlights)

@MainActor
@Observable
final class ReaderController {
    let pdfView = PDFView()
    var document: PDFDocument?
    var loadedPath: String?
    var currentPage = 1
    var pageCount = 0
    var findResults: [PDFSelection] = []
    var findIndex = 0
    var twoPages = false
    var zoomPercent = 100
    var lastJumpMatchedExactly = true
    private var highlightAnnotations: [(PDFPage, PDFAnnotation)] = []
    private var observer: NSObjectProtocol?
    private var scaleObserver: NSObjectProtocol?

    init() {
        pdfView.autoScales = true
        pdfView.minScaleFactor = 0.35
        pdfView.maxScaleFactor = 6.0
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageShadowsEnabled = true
        pdfView.backgroundColor = .underPageBackgroundColor
        observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            // Deferred: PDFKit posts this during its own layout pass; updating SwiftUI state synchronously
            // re-entered the sidebar's table view.
            DispatchQueue.main.async {
                guard let self, let page = self.pdfView.currentPage, let doc = self.pdfView.document else { return }
                let n = doc.index(for: page) + 1
                if self.currentPage != n { self.currentPage = n }
            }
        }
        scaleObserver = NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateZoom() }
        }
    }

    func load(path: String) {
        guard loadedPath != path else { return }
        clearHighlights()
        // Word, PowerPoint & co. are shown through their cached PDF rendition.
        guard let doc = PDFDocument(url: URL(fileURLWithPath: DocumentFormats.readablePDFPath(for: path))) else {
            document = nil
            loadedPath = nil
            pageCount = 0
            return
        }
        document = doc
        loadedPath = path
        pageCount = doc.pageCount
        pdfView.document = doc
        findResults = []
    }

    func go(toPage number: Int) {
        guard let doc = document, let page = doc.page(at: max(0, min(doc.pageCount - 1, number - 1))) else { return }
        pdfView.go(to: page)
        currentPage = doc.index(for: page) + 1
    }

    /// Jumps to `page` and marks the passage `text` (a chunk) as precisely as possible.
    func jump(page number: Int, text: String?) {
        clearHighlights()
        go(toPage: number)
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let doc = document, let page = doc.page(at: max(0, number - 1)) else {
            lastJumpMatchedExactly = true
            return
        }
        // Image-only slide (no text layer, text came from OCR): the whole slide is the passage.
        if (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 80 {
            lastJumpMatchedExactly = true
            return
        }
        if let selection = Self.selection(of: text, on: page) ?? Self.fuzzySelection(of: text, in: doc, preferring: page) {
            highlight(selection)
            if ProcessInfo.processInfo.environment["CORTEXRAG_DEBUG_DIR"] != nil {
                fputs("reader-highlight: \(highlightAnnotations.count) lines, \(selection.string?.count ?? 0) chars\n", stderr)
            }
            lastJumpMatchedExactly = true
        } else {
            lastJumpMatchedExactly = false
        }
    }

    /// Frames a figure (normalized top-left bbox from indexing) on its page.
    func highlightFigure(bbox: NormalizedRect, page number: Int) {
        guard let doc = document, let page = doc.page(at: max(0, number - 1)) else { return }
        lastJumpMatchedExactly = true
        let mb = page.bounds(for: .mediaBox)
        let rect = CGRect(
            x: mb.minX + bbox.x * mb.width,
            y: mb.minY + (1 - bbox.y - bbox.height) * mb.height,
            width: bbox.width * mb.width,
            height: bbox.height * mb.height
        )
        highlight(rect: rect, on: page)
        currentPage = number
    }

    func highlight(rect: CGRect, on page: PDFPage) {
        clearHighlights()
        let ann = PDFAnnotation(bounds: rect.insetBy(dx: -4, dy: -4), forType: .square, withProperties: nil)
        ann.color = NSColor.systemTeal
        let border = PDFBorder()
        border.lineWidth = 2.5
        ann.border = border
        ann.interiorColor = NSColor.systemTeal.withAlphaComponent(0.08)
        page.addAnnotation(ann)
        highlightAnnotations.append((page, ann))
        pdfView.go(to: rect.insetBy(dx: 0, dy: -60), on: page)
    }

    private func highlight(_ selection: PDFSelection) {
        var firstRect: (PDFPage, CGRect)?
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 1 else { continue }
                let ann = PDFAnnotation(bounds: bounds.insetBy(dx: -1.5, dy: -1), forType: .highlight, withProperties: nil)
                ann.color = NSColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(ann)
                highlightAnnotations.append((page, ann))
                if firstRect == nil { firstRect = (page, bounds) }
            }
        }
        if let (page, rect) = firstRect {
            // Scroll so that the first highlighted line sits in the upper third of the view.
            pdfView.go(to: CGRect(x: rect.minX, y: rect.minY - 260, width: rect.width, height: rect.height + 300), on: page)
        }
    }

    func clearHighlights() {
        for (page, ann) in highlightAnnotations { page.removeAnnotation(ann) }
        highlightAnnotations.removeAll()
    }

    func find(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let doc = document, q.count >= 2 else {
            findResults = []
            pdfView.highlightedSelections = nil
            return
        }
        findResults = Array(doc.findString(q, withOptions: [.caseInsensitive, .diacriticInsensitive]).prefix(300))
        for sel in findResults { sel.color = NSColor.systemYellow.withAlphaComponent(0.35) }
        // All matches stay marked; the current one is selected and scrolled into view.
        pdfView.highlightedSelections = findResults
        findIndex = 0
        if let first = findResults.first { focus(first) }
    }

    func stepFind(_ delta: Int) {
        guard !findResults.isEmpty else { return }
        findIndex = (findIndex + delta + findResults.count) % findResults.count
        focus(findResults[findIndex])
    }

    private func focus(_ sel: PDFSelection) {
        pdfView.setCurrentSelection(sel, animate: true)
        pdfView.scrollSelectionToVisible(nil)
        if let page = sel.pages.first, let doc = document { currentPage = doc.index(for: page) + 1 }
    }

    func clearFind() {
        findResults = []
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
    }

    func toggleTwoPages() {
        twoPages.toggle()
        pdfView.displayMode = twoPages ? .twoUpContinuous : .singlePageContinuous
        pdfView.displaysAsBook = twoPages
        pdfView.autoScales = true
        updateZoom()
    }

    func updateZoom() {
        zoomPercent = Int((pdfView.scaleFactor * 100).rounded())
    }

    func show(_ selection: PDFSelection) {
        clearHighlights()
        highlight(selection)
        if let page = selection.pages.first, let doc = document { currentPage = doc.index(for: page) + 1 }
    }

    func zoom(_ delta: CGFloat) {
        pdfView.autoScales = false
        pdfView.scaleFactor = max(0.3, min(4.0, pdfView.scaleFactor * (1 + delta)))
        updateZoom()
    }

    func fitWidth(margin: CGFloat = 24) {
        guard let page = pdfView.currentPage ?? document?.page(at: 0) else {
            pdfView.autoScales = true
            updateZoom()
            return
        }
        let mb = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let pageW = rotated ? mb.height : mb.width
        let viewW = pdfView.bounds.width
        guard pageW > 10, viewW > 120 else {
            pdfView.autoScales = true
            updateZoom()
            return
        }
        let perPageW = twoPages ? (viewW - margin * 2) / 2.0 : (viewW - margin)
        let targetScale = max(0.5, min(4.0, perPageW / pageW))
        pdfView.autoScales = false
        pdfView.scaleFactor = targetScale
        updateZoom()
    }

    // MARK: Text matching

    /// Locates an indexed chunk on its page. Chunks are cleaned before indexing (joined lines, footers removed, slide
    /// title moved to the front, figure text added), so the match works on words: several 4-word anchors spread over
    /// the chunk are looked up in the page's words, and the span between the outermost matching anchors is selected.
    static func selection(of text: String, on page: PDFPage) -> PDFSelection? {
        guard let pageString = page.string, !pageString.isEmpty,
              let range = matchRange(of: text, in: pageString) else { return nil }
        return page.selection(for: range)
    }

    /// Word-anchored match of `text` inside `pageString` (UTF-16 range of the page string), or nil.
    nonisolated static func matchRange(of text: String, in pageString: String) -> NSRange? {
        let pageWords = words(in: pageString)
        let chunkWords = words(in: text).map(\.word)
        guard chunkWords.count >= 2 else { return nil }
        let n = min(4, chunkWords.count)
        guard pageWords.count >= n else { return nil }
        var index: [String: [Int]] = [:]
        for i in 0...(pageWords.count - n) {
            index[pageWords[i..<(i + n)].map(\.word).joined(separator: " "), default: []].append(i)
        }
        // Anchors every few words across the whole chunk.
        let step = max(1, (chunkWords.count - n) / 12)
        var hits: [(page: Int, chunk: Int)] = []
        for c in stride(from: 0, through: chunkWords.count - n, by: step) {
            let key = chunkWords[c..<(c + n)].joined(separator: " ")
            if let positions = index[key] {
                // Prefer the occurrence consistent with the anchors found so far.
                let expected = hits.last.map { $0.page + (c - $0.chunk) }
                let best = expected.map { e in positions.min { abs($0 - e) < abs($1 - e) }! } ?? positions[0]
                hits.append((best, c))
            }
        }
        guard !hits.isEmpty else { return nil }
        // Keep the largest cluster of anchors whose page positions are consistent (drop stray matches).
        let sorted = hits.sorted { $0.page < $1.page }
        var bestCluster: ArraySlice<(page: Int, chunk: Int)> = sorted[0..<1]
        var start = 0
        for i in 1..<max(sorted.count, 1) where i < sorted.count {
            if sorted[i].page - sorted[i - 1].page > max(40, chunkWords.count) { start = i }
            if i - start + 1 > bestCluster.count { bestCluster = sorted[start...i] }
        }
        // A single short anchor is too weak for long chunks.
        if bestCluster.count == 1 && chunkWords.count > 12 && hits.count == 1 { return nil }
        let first = bestCluster.first!.page
        let last = min(pageWords.count - 1, bestCluster.last!.page + n - 1)
        let lo = pageWords[first].range.location
        var hi = pageWords[last].range.location + pageWords[last].range.length
        // Closing punctuation belongs to the passage ("… 4,0 mmol/l.").
        let ns = pageString as NSString
        while hi < ns.length, let sc = Unicode.Scalar(ns.character(at: hi)), ".,;:!?)»“\"%".unicodeScalars.contains(sc) { hi += 1 }
        return NSRange(location: lo, length: hi - lo)
    }

    /// Lowercased, diacritic-folded words with their UTF-16 ranges; hyphenated line breaks ("Vorschrei- ten") are
    /// compared as separate words on both sides, so they still line up.
    nonisolated static func words(in s: String) -> [(word: String, range: NSRange)] {
        let ns = s as NSString
        var out: [(String, NSRange)] = []
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            guard let scalar = Unicode.Scalar(c), CharacterSet.alphanumerics.contains(scalar) else { i += 1; continue }
            var j = i
            while j < ns.length, let sc = Unicode.Scalar(ns.character(at: j)), CharacterSet.alphanumerics.contains(sc) { j += 1 }
            let r = NSRange(location: i, length: j - i)
            out.append((ns.substring(with: r).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), r))
            i = j
        }
        return out
    }

    /// Fallback: find the first words of the chunk anywhere, preferring the target page.
    static func fuzzySelection(of text: String, in doc: PDFDocument, preferring page: PDFPage) -> PDFSelection? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { $0.count > 1 }
        for n in [8, 5, 3] where words.count >= n {
            let probe = words.prefix(n).joined(separator: " ")
            let matches = doc.findString(probe, withOptions: [.caseInsensitive])
            if let m = matches.first(where: { $0.pages.contains(page) }) ?? (n == 8 ? matches.first : nil) {
                return m
            }
        }
        return nil
    }

}

struct PDFThumbnailHost: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.pdfView = pdfView
        v.thumbnailSize = CGSize(width: 150, height: 200)
        v.backgroundColor = .clear
        v.maximumNumberOfColumns = 1
        return v
    }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
}

struct PDFKitHost: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView {
        if let scroll = pdfView.subviews.first(where: { $0 is NSScrollView }) as? NSScrollView {
            scroll.allowsMagnification = true
            scroll.minMagnification = 0.4
            scroll.maxMagnification = 5.0
        }
        return pdfView
    }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

// MARK: - Reader window

enum ReaderSidebarMode: String, CaseIterable, Identifiable {
    case pages = "Seiten"
    case outline = "Inhalt"
    case sections = "Abschnitte"
    case figures = "Abbildungen"
    case search = "Suche"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .pages: return "square.grid.2x2"
        case .outline: return "list.bullet.indent"
        case .sections: return "text.alignleft"
        case .figures: return "photo"
        case .search: return "magnifyingglass"
        }
    }
}

struct ReaderWindowView: View {
    @Bindable var vm: AppViewModel
    @State private var controller = ReaderController()
    @State private var mode: ReaderSidebarMode = .sections
    @State private var rows: [ReaderSectionRow] = []
    @State private var outline: [TOCItem] = []
    @State private var figures: [FigureResultItem] = []
    @State private var findQuery = ""
    @State private var activeChunkID: String?
    @State private var lastFindQuery = ""

    // The body reads no per-page state (current page, zoom): those live in small subviews, so scrolling through a
    // long PDF does not re-render the window, its toolbar and the sidebar lists.
    var body: some View {
        Group {
            if let target = vm.readerTarget {
                if !FileManager.default.fileExists(atPath: DocumentFormats.readablePDFPath(for: target.documentPath)) {
                    ContentUnavailableView {
                        Label("Dokument nicht gefunden", systemImage: "doc.questionmark")
                    } description: {
                        Text("„\(target.title)“ liegt nicht mehr unter\n\(target.documentPath)\nDie indizierten Abschnitte bleiben durchsuchbar. Zum Lesen die Datei zurücklegen oder neu importieren.")
                    }
                } else {
                    NavigationSplitView {
                        ReaderSidebar(controller: controller, mode: $mode, rows: rows, outline: outline, figures: figures,
                                      activeChunkID: $activeChunkID, findQuery: findQuery)
                            .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 380)
                    } detail: {
                        ZStack(alignment: .bottom) {
                            PDFKitHost(pdfView: controller.pdfView)
                                .ignoresSafeArea(edges: .bottom)
                            VStack(spacing: 10) {
                                ReaderMatchNotice(controller: controller, page: target.pageNumber)
                                ReaderControlBar(controller: controller)
                            }
                            .padding(.bottom, 18)
                        }
                        .overlay(alignment: .top) { ReaderProgressLine(controller: controller) }
                    }
                    .navigationTitle(target.title)
                    .toolbar { toolbarContent(target) }
                    .searchable(text: $findQuery, placement: .toolbar, prompt: "Im Dokument suchen")
                    .onSubmit(of: .search) {
                        if controller.findResults.isEmpty || lastFindQuery != findQuery {
                            controller.find(findQuery)
                            lastFindQuery = findQuery
                            mode = .search
                        } else {
                            controller.stepFind(1)
                        }
                    }
                    .onChange(of: findQuery) { _, q in if q.isEmpty { controller.clearFind(); lastFindQuery = "" } }
                    .onChange(of: target.token, initial: true) { _, _ in apply(target) }
                }
            } else {
                ContentUnavailableView("Kein Dokument geöffnet", systemImage: "book.pages",
                                       description: Text("Öffne ein Dokument aus der Bibliothek oder einem Suchtreffer."))
            }
        }
        .frame(minWidth: 900, minHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: .init("CortexDebug"))) { note in
            guard let cmd = note.object as? String else { return }
            let parts = cmd.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts.first {
            case "reader-find":
                findQuery = arg
                controller.find(arg)
                lastFindQuery = arg
                mode = .search
            case "reader-mode":
                if let m = ReaderSidebarMode.allCases.first(where: { "\($0)" == arg }) { mode = m }
            case "reader-two":
                controller.toggleTwoPages()
            case "reader-figure":
                if let fig = figures.first(where: { $0.pageNumber > 1 }) ?? figures.first {
                    mode = .figures
                    controller.highlightFigure(bbox: fig.bbox, page: fig.pageNumber)
                }
            case "reader-quicklook":
                if let t = vm.readerTarget { QuickLookPresenter.shared.show(URL(fileURLWithPath: t.documentPath)) }
            default: break
            }
        }
    }

    private func apply(_ target: ReaderTarget) {
        let isNewDocument = controller.loadedPath != target.documentPath
        controller.load(path: target.documentPath)
        if isNewDocument {
            let chunks = (target.documentID.flatMap { try? vm.service.db.listChunks(documentID: $0) }) ?? []
            if let id = target.documentID { vm.ensureTextProfiles(for: [id]) }
            let docID = target.documentID ?? ""
            // Display texts are computed once per document, not on every render.
            rows = chunks.map { c in
                ReaderSectionRow(id: c.id, page: c.pageNumber, section: Self.sectionName(c.breadcrumb),
                                 preview: String(vm.displayText(c.content, documentID: docID, page: c.pageNumber).prefix(240)),
                                 content: c.content)
            }
            outline = controller.outlineItems().nonEmptyOr(vm.document(id: target.documentID)?.toc ?? [])
            figures = (target.documentID.flatMap { try? vm.service.db.getDocumentOverview(titleOrID: $0)?.figures }) ?? []
            findQuery = ""
            controller.findResults = []
            if target.chunkText == nil && target.figureBBox == nil { mode = .pages }
        }
        // Wait one layout pass so PDFView knows its size before scrolling.
        DispatchQueue.main.async {
            if let bbox = target.figureBBox {
                controller.highlightFigure(bbox: bbox, page: target.pageNumber)
            } else {
                controller.jump(page: target.pageNumber, text: target.chunkText)
            }
            activeChunkID = target.chunkText.flatMap { text in rows.first(where: { $0.content == text })?.id }
        }
    }

    static func sectionName(_ breadcrumb: String) -> String {
        let parts = CortexTextSanitizer.displayTitle(breadcrumb).components(separatedBy: " > ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " › ") : breadcrumb
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbarContent(_ target: ReaderTarget) -> some ToolbarContent {
        let url = URL(fileURLWithPath: target.documentPath)
        ToolbarItemGroup(placement: .primaryAction) {
            ReaderFindStepper(controller: controller)
            Button { QuickLookPresenter.shared.show(url) } label: { Image(systemName: "eye") }
                .help("Quick Look (⌘Y)")
                .keyboardShortcut("y", modifiers: .command)
            OpenWithMenu(url: url)
            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                .help("Teilen")
            Menu {
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Pfad kopieren") { NSPasteboard.copy(target.documentPath) }
                Button("Zitat kopieren (Titel, aktuelle Seite)") { NSPasteboard.copy("\(target.title), S. \(controller.currentPage)") }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuIndicator(.hidden)
            .help("Weitere Aktionen")
        }
    }
}

// MARK: - Reader pieces (each observes only what it shows)

struct ReaderSectionRow: Identifiable, Equatable {
    let id: String
    let page: Int
    let section: String
    let preview: String
    let content: String
}

private extension Array {
    func nonEmptyOr(_ fallback: [Element]) -> [Element] { isEmpty ? fallback : self }
}

extension ReaderController {
    /// Outline of the PDF (bookmarks), flattened with levels.
    func outlineItems() -> [TOCItem] {
        guard let doc = document, let root = doc.outlineRoot else { return [] }
        var items: [TOCItem] = []
        func walk(_ node: PDFOutline, level: Int) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let label = child.label, let page = child.destination?.page {
                    items.append(TOCItem(title: label, pageNumber: doc.index(for: page) + 1, level: level))
                }
                walk(child, level: level + 1)
            }
        }
        walk(root, level: 1)
        // Exports without real titles ("Foliennummer 3") are no outline: the indexed slide titles are better.
        return items.allSatisfy { IndexTextPreparer.isGenericOutlineLabel($0.title) } ? [] : items
    }
}

/// Thin reading-progress line under the toolbar.
struct ReaderProgressLine: View {
    let controller: ReaderController
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Theme.accentGradient)
                .frame(width: geo.size.width * CGFloat(controller.currentPage) / CGFloat(max(controller.pageCount, 1)), height: 2.5)
                .animation(Theme.quick, value: controller.currentPage)
        }
        .frame(height: 2.5)
    }
}

struct ReaderMatchNotice: View {
    let controller: ReaderController
    let page: Int
    var body: some View {
        if !controller.lastJumpMatchedExactly {
            Label("Textstelle nicht exakt gefunden – Seite \(page) geöffnet", systemImage: "info.circle")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassSurface(cornerRadius: 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct ReaderFindStepper: View {
    let controller: ReaderController
    var body: some View {
        if !controller.findResults.isEmpty {
            HStack(spacing: 2) {
                Text("\(controller.findIndex + 1) / \(controller.findResults.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button { controller.stepFind(-1) } label: { Image(systemName: "chevron.up") }.help("Vorheriger Treffer")
                Button { controller.stepFind(1) } label: { Image(systemName: "chevron.down") }.help("Nächster Treffer (↩)")
            }
        }
    }
}

/// Floating glass controls: page navigation, zoom, layout, highlight.
struct ReaderControlBar: View {
    let controller: ReaderController
    @State private var pageField = ""

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                barButton("chevron.left", help: "Vorherige Seite") { controller.go(toPage: controller.currentPage - 1) }
                    .disabled(controller.currentPage <= 1)
                TextField("\(controller.currentPage)", text: $pageField)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .frame(width: 38)
                    .onSubmit {
                        if let n = Int(pageField) { controller.go(toPage: n) }
                        pageField = ""
                    }
                    .help("Seitenzahl eingeben und ↩")
                Text("/ \(controller.pageCount)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                barButton("chevron.right", help: "Nächste Seite") { controller.go(toPage: controller.currentPage + 1) }
                    .disabled(controller.currentPage >= controller.pageCount)
            }
            Divider().frame(height: 18)
            HStack(spacing: 4) {
                barButton("minus", help: "Verkleinern (⌘-)") { controller.zoom(-0.15) }
                    .keyboardShortcut("-", modifiers: .command)
                Button { controller.fitWidth() } label: {
                    Text("\(controller.zoomPercent) %")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .frame(width: 48)
                }
                .buttonStyle(.plain)
                .help("An Breite anpassen (⌘0)")
                .keyboardShortcut("0", modifiers: .command)
                barButton("plus", help: "Vergrößern (⌘+)") { controller.zoom(0.15) }
                    .keyboardShortcut("+", modifiers: .command)
            }
            Divider().frame(height: 18)
            barButton(controller.twoPages ? "book" : "doc.plaintext", help: controller.twoPages ? "Einzelseiten" : "Doppelseiten") { controller.toggleTwoPages() }
            barButton("highlighter", help: "Markierungen entfernen") {
                controller.clearHighlights()
                controller.clearFind()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassSurface(cornerRadius: 22, interactive: true)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
        .onAppear { controller.updateZoom() }
    }

    private func barButton(_ icon: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// "Öffnen mit": every app that can open the document (Preview, Acrobat, PowerPoint, Keynote …).
struct OpenWithMenu: View {
    let url: URL
    var body: some View {
        Menu {
            let apps = NSWorkspace.shared.urlsForApplications(toOpen: url)
            let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
            if let defaultApp {
                Button(appName(defaultApp) + " (Standard)") { open(with: defaultApp) }
                Divider()
            }
            ForEach(apps.filter { $0 != defaultApp }.prefix(12), id: \.self) { app in
                Button(appName(app)) { open(with: app) }
            }
        } label: {
            Image(systemName: "arrow.up.forward.app")
        }
        .menuIndicator(.hidden)
        .help("Öffnen mit …")
    }

    private func appName(_ app: URL) -> String {
        FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    private func open(with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

// MARK: - Sidebar

struct ReaderSidebar: View {
    let controller: ReaderController
    @Binding var mode: ReaderSidebarMode
    let rows: [ReaderSectionRow]
    let outline: [TOCItem]
    let figures: [FigureResultItem]
    @Binding var activeChunkID: String?
    let findQuery: String

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(ReaderSidebarMode.allCases) { m in
                    Image(systemName: m.icon).help(LocalizedStringKey(m.rawValue)).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Text(LocalizedStringKey(mode.rawValue)).textCase(.uppercase)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)

            switch mode {
            case .pages: PDFThumbnailHost(pdfView: controller.pdfView).padding(.horizontal, 6)
            case .outline: ReaderOutlineList(controller: controller, items: outline)
            case .sections: ReaderSectionList(controller: controller, rows: rows, activeChunkID: $activeChunkID)
            case .figures: ReaderFigureList(controller: controller, figures: figures)
            case .search: ReaderSearchList(controller: controller, query: findQuery)
            }
        }
    }
}

struct ReaderOutlineList: View {
    let controller: ReaderController
    let items: [TOCItem]

    var body: some View {
        if items.isEmpty {
            ContentUnavailableView("Kein Inhaltsverzeichnis", systemImage: "list.bullet.indent",
                                   description: Text("Dieses Dokument enthält keine Gliederung."))
        } else {
            let current = items.last(where: { $0.pageNumber <= controller.currentPage })?.id
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            Button { controller.go(toPage: item.pageNumber) } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: item.level <= 1 ? .semibold : .regular))
                                        .lineLimit(2)
                                        .padding(.leading, CGFloat(max(0, item.level - 1)) * 12)
                                    Spacer(minLength: 6)
                                    Text("\(item.pageNumber)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(item.id == current ? Theme.accent.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: current) { _, id in
                    if let id { withAnimation(Theme.quick) { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }
}

struct ReaderSectionList: View {
    let controller: ReaderController
    let rows: [ReaderSectionRow]
    @Binding var activeChunkID: String?

    var body: some View {
        if rows.isEmpty {
            ContentUnavailableView("Keine Abschnitte", systemImage: "text.alignleft",
                                   description: Text("Das Dokument ist nicht indiziert."))
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { row in
                            let active = activeChunkID == row.id
                            Button {
                                activeChunkID = row.id
                                controller.jump(page: row.page, text: row.content)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text("S. \(row.page)")
                                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                                            .foregroundStyle(Theme.accent)
                                        Text(row.section)
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(row.preview)
                                        .font(.system(size: 11.5))
                                        .lineLimit(3)
                                        .foregroundStyle(.primary)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(active ? Theme.accent.opacity(0.14) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(row.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .onChange(of: activeChunkID, initial: true) { _, id in
                    guard let id else { return }
                    // Lazy rows have estimated heights at first; scroll again once they are measured.
                    for delay in [0.15, 0.6] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }
}

struct ReaderFigureList: View {
    let controller: ReaderController
    let figures: [FigureResultItem]

    var body: some View {
        if figures.isEmpty {
            ContentUnavailableView("Keine Abbildungen", systemImage: "photo",
                                   description: Text("Für dieses Dokument wurden keine Abbildungen ausgeschnitten."))
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(figures) { fig in
                        Button {
                            controller.highlightFigure(bbox: fig.bbox, page: fig.pageNumber)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                AssetImage(path: fig.croppedImagePath, maxHeight: 120, cornerRadius: 8, figure: fig)
                                HStack {
                                    Text(fig.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.figure)
                                    Spacer()
                                    Text("S. \(fig.pageNumber)").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .contentCard(cornerRadius: 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }
        }
    }
}

struct ReaderSearchList: View {
    let controller: ReaderController
    let query: String

    var body: some View {
        VStack(spacing: 6) {
            if controller.findResults.isEmpty {
                Text(query.isEmpty ? "Suchbegriff oben rechts eingeben" : "Keine Treffer")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(.top, 8)
            } else {
                Text("\(controller.findResults.count) Treffer")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.findResults.enumerated()), id: \.offset) { i, sel in
                        Button { controller.findIndex = i; controller.show(sel) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                let pageNo = sel.pages.first.flatMap { controller.document?.index(for: $0) }.map { $0 + 1 } ?? 0
                                Text("Seite \(pageNo)").font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.accent)
                                Text(context(for: sel)).font(.system(size: 11.5)).lineLimit(2)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(i == controller.findIndex ? Theme.accent.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }

    private func context(for sel: PDFSelection) -> String {
        guard let copy = sel.copy() as? PDFSelection else { return sel.string ?? "" }
        copy.extend(atStart: 40)
        copy.extend(atEnd: 60)
        return (copy.string ?? "").replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Quick Look

/// Apple's Quick Look panel for the original file (also Word/PowerPoint originals).
@MainActor
final class QuickLookPresenter: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLookPresenter()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
