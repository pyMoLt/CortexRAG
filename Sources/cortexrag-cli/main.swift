import Foundation
import CortexCore
import CortexEmbedders
import CortexVision
import CortexIPC

// MARK: - Backend (only the running CortexRAG.app daemon)

/// CLI and MCP deliberately work only while CortexRAG.app runs with its daemon enabled.
/// Starting/quitting the app (or pausing the daemon) is the on/off switch for AI agents.
enum CortexBackend {
    static let offlineMessage = "CortexRAG ist für Agenten deaktiviert: Die App läuft nicht oder der CLI/MCP-Zugriff ist pausiert. Starte CortexRAG.app bzw. aktiviere den Zugriff in der App."

    static func send(_ req: IPCRequest) throws -> IPCResponse {
        guard CortexSocketClient.isDaemonRunning() else {
            throw CortexSocketClient.ClientError(offlineMessage)
        }
        return try CortexSocketClient.send(req)
    }
}

// MARK: - Argument helpers

struct ParsedArgs {
    var positional: [String] = []
    var flags: [String: String] = [:]
    var switches: Set<String> = []

    static let valueFlags: Set<String> = [
        "--module", "--collection", "--collection-id", "--folder", "--doc", "--context", "--context-chunks",
        "--window", "--top-k", "--engine", "--page-start", "--page-end", "--pages", "--page", "--before", "--after",
        "--path", "--chunk-id", "--content", "--granularity", "--chunk-granularity", "--max-chars",
        "--max-chars-per-chunk", "--min-score"
    ]

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if Self.valueFlags.contains(a), i + 1 < args.count {
                flags[a] = args[i + 1]
                i += 2
            } else if a.hasPrefix("--") {
                switches.insert(a)
                i += 1
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    func value(_ names: String...) -> String? {
        for n in names { if let v = flags[n] { return v } }
        return nil
    }

    func int(_ names: String...) -> Int? {
        for n in names { if let v = flags[n], let i = Int(v) { return i } }
        return nil
    }

    func has(_ name: String) -> Bool { switches.contains(name) }
}

func splitCSV(_ raw: String?) -> [String]? {
    guard let raw else { return nil }
    let items = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    return items.isEmpty ? nil : items
}

/// "12-18" or "12" -> (12, 18) / (12, 12)
func parsePageRange(_ raw: String?) -> (Int, Int)? {
    guard let raw else { return nil }
    let parts = raw.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    if parts.count == 2 { return (parts[0], parts[1]) }
    if parts.count == 1 { return (parts[0], parts[0]) }
    return nil
}

func scopeFromCLI(_ p: ParsedArgs) -> ScopeFilter {
    let useUI: Bool? = p.has("--use-ui-scope") ? true : ((p.has("--all-scope") || p.has("--all")) ? false : nil)
    return ScopeFilter(
        moduleNames: splitCSV(p.value("--module")),
        collectionNames: splitCSV(p.value("--collection")),
        folderNames: splitCSV(p.value("--folder")),
        documentTitles: splitCSV(p.value("--doc")),
        pageStart: p.int("--page-start"),
        pageEnd: p.int("--page-end"),
        useUISelection: useUI
    )
}

// MARK: - Compact, agent-friendly JSON views

enum AgentJSON {
    static func title(_ raw: String) -> String { CortexTextSanitizer.displayTitle(raw) }

    static func library(_ st: DaemonStatusPayload) -> [String: Any] {
        let tree: [[String: Any]] = st.hierarchy.map { mod in
            [
                "module": mod.name, "id": mod.id, "selected_in_app": mod.isSelectedInUI,
                "collections": mod.collections.map { col -> [String: Any] in
                    var c: [String: Any] = [
                        "collection": col.name, "id": col.id, "selected_in_app": col.isSelectedInUI,
                        "documents": col.directDocuments.map(doc)
                    ]
                    if !col.description.isEmpty { c["description"] = col.description }
                    if !col.folders.isEmpty {
                        c["folders"] = col.folders.map { f -> [String: Any] in
                            ["folder": f.name, "id": f.id, "path": f.path, "selected_in_app": f.isSelectedInUI, "documents": f.documents.map(doc)]
                        }
                    }
                    return c
                }
            ]
        }
        return [
            "engine": st.activeEngine,
            "app_selection": st.activeUIScope.isEmpty ? "keine (ganze Bibliothek)" : st.activeUIScope.summaryDescription,
            "app_selection_applies_to_agents": st.enforceUIScopeForAgents && !st.activeUIScope.isEmpty,
            "guidance": st.agentGuidance,
            "library": tree
        ]
    }

    static func doc(_ d: LibraryDocument) -> [String: Any] {
        ["title": title(d.title), "id": d.id, "pages": d.pageCount, "chunks": d.chunkCount, "figures": d.figureCount]
    }

    static func figure(_ f: FigureResultItem, withDocument: Bool) -> [String: Any] {
        var o: [String: Any] = [
            "figure_id": f.figureID,
            "label": f.label,
            "page": f.pageNumber,
            "image": f.croppedImagePath,
            "markdown": "![\(f.label)](\(f.croppedImagePath))"
        ]
        let cleanedCaption = ChunkDisplayCleaner.clean(f.caption)
        if !cleanedCaption.isEmpty { o["caption"] = cleanedCaption }
        if withDocument {
            o["document"] = title(f.documentTitle)
            o["document_id"] = f.documentID
            o["page_image"] = f.fullPageImagePath
            o["score"] = f.score
            if !f.breadcrumb.isEmpty { o["section"] = title(f.breadcrumb) }
        }
        return o
    }

    static func hit(_ r: SearchResultItem, includeFigures: Bool) -> [String: Any] {
        var o: [String: Any] = [
            "rank": r.rank,
            "score": r.score,
            "chunk_id": r.chunkID,
            "document": title(r.documentTitle),
            "document_id": r.documentID,
            "collection": r.collectionName,
            "page": r.pageNumber,
            "section": title(r.breadcrumb),
            "text": CortexTextSanitizer.cleanText(r.matchedContent),
            "pdf_path": r.documentPath,
            "page_image": r.fullPageImagePath
        ]
        if r.isFigure { o["kind"] = "figure" }
        if !r.contextBefore.isEmpty { o["context_before"] = CortexTextSanitizer.cleanText(r.contextBefore) }
        if !r.contextAfter.isEmpty { o["context_after"] = CortexTextSanitizer.cleanText(r.contextAfter) }
        if includeFigures && !r.figuresOnPage.isEmpty {
            o["figures_on_page"] = r.figuresOnPage.map { figure($0, withDocument: false) }
        }
        return o
    }

    static func render(_ resp: IPCResponse, includeFigures: Bool = true) -> Any {
        if !resp.ok { return ["error": resp.error ?? "Unbekannter Fehler"] }
        if let st = resp.status { return library(st) }
        if let sr = resp.searchResponse {
            return [
                "query": sr.query, "scope": sr.scope.summaryDescription, "latency_ms": Int(sr.latencyMs.rounded()),
                "results": sr.results.map { hit($0, includeFigures: includeFigures) }
            ] as [String: Any]
        }
        if let fr = resp.figureResponse {
            return [
                "query": fr.query, "scope": fr.scope.summaryDescription,
                "figures": fr.figures.map { figure($0, withDocument: true) }
            ] as [String: Any]
        }
        if let ex = resp.expandedItem { return hit(ex, includeFigures: true) }
        if let ov = resp.documentOverview {
            return [
                "title": title(ov.document.title), "id": ov.document.id, "pdf_path": ov.document.filePath,
                "module": ov.moduleName, "collection": ov.collectionName,
                "pages": ov.document.pageCount, "chunks": ov.document.chunkCount,
                "toc": ov.document.toc.map { ["title": $0.title, "page": $0.pageNumber, "level": $0.level] as [String: Any] },
                "figure_count": ov.figures.count,
                "figures_preview": ov.figures.prefix(15).map { figure($0, withDocument: false) },
                "hint": "Weitere Abbildungen gezielt über cortex_search_figures oder cortex_get_page_figures mit document=<id> und page=<Seitenzahl> abrufen."
            ] as [String: Any]
        }
        if let pt = resp.pageText {
            return [
                "document": title(pt.documentTitle), "document_id": pt.documentID, "page_count": pt.pageCount,
                "pdf_path": pt.documentPath,
                "pages": pt.pages.map { ["page": $0.page, "text": CortexTextSanitizer.cleanText($0.text)] as [String: Any] }
            ] as [String: Any]
        }
        if let d = resp.indexedDocument { return ["indexed": doc(d)] }
        if let b = resp.benchmarkReport {
            return ["hardware": b.hardwareModel, "recommendation": b.recommendation, "text_cosine_parity": b.meanTextCosineSimilarity ?? 0]
        }
        return ["ok": true]
    }

    static func string(_ obj: Any, pretty: Bool = true) -> String {
        let opts: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: opts) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - CLI entry point

@main
struct CortexRAGCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            return
        }
        let p = ParsedArgs(Array(args.dropFirst()))

        if ["--help", "-h", "help"].contains(command) {
            printUsage()
            return
        }

        if command == "mcp" {
            await MCPServer().run()
            return
        }

        let json = p.has("--json")
        let compact = p.has("--compact")

        do {
            guard let req = try buildRequest(command: command, p: p) else {
                fputs("Unbekannter Befehl: \(command)\n\n", stderr)
                printUsage()
                Foundation.exit(1)
            }
            let resp = try CortexBackend.send(req)
            if compact {
                print(AgentJSON.string(AgentJSON.render(resp, includeFigures: !p.has("--no-figures"))))
            } else if json {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                print(String(data: try enc.encode(resp), encoding: .utf8) ?? "{}")
            } else {
                printHuman(resp)
            }
            if !resp.ok { Foundation.exit(1) }
        } catch {
            if json || compact {
                print(AgentJSON.string(["ok": false, "error": "\(error)"]))
            } else {
                fputs("Fehler: \(error)\n", stderr)
            }
            Foundation.exit(1)
        }
    }

    static func buildRequest(command: String, p: ParsedArgs) throws -> IPCRequest? {
        switch command {
        case "status", "library", "tree":
            return IPCRequest(action: .status, source: "cli")

        case "engine":
            let raw = p.value("--engine") ?? p.positional.first ?? ""
            guard let kind = EngineKind(rawValue: raw.lowercased()) else {
                throw CortexSocketClient.ClientError("Bitte Engine angeben: cortexrag engine llama|mlx")
            }
            return IPCRequest(action: .switchEngine, source: "cli", engine: kind)

        case "search", "figures":
            let query = p.positional.joined(separator: " ")
            guard !query.isEmpty else {
                throw CortexSocketClient.ClientError("Bitte einen Suchbegriff angeben, z. B. cortexrag \(command) \"Raft Consensus\"")
            }
            let topK = p.int("--top-k") ?? 6
            let engine = p.value("--engine").flatMap { EngineKind(rawValue: $0.lowercased()) }
            if command == "figures" {
                return IPCRequest(action: .figures, source: "cli", query: query, scope: scopeFromCLI(p), topK: topK, engine: engine)
            }
            let contentMode = p.value("--content").flatMap { SearchContentMode(rawValue: $0.lowercased()) }
                ?? (p.has("--no-figures") ? .text : .all)
            return IPCRequest(
                action: .search, source: "cli", query: query, scope: scopeFromCLI(p),
                contextChunks: p.int("--context", "--context-chunks", "--window") ?? 1,
                includeFigures: !p.has("--no-figures"), content: contentMode, topK: topK, engine: engine,
                chunkGranularity: p.value("--granularity", "--chunk-granularity"),
                maxCharsPerChunk: p.int("--max-chars", "--max-chars-per-chunk"),
                minScore: p.value("--min-score").flatMap { Double($0) }
            )

        case "page-figures", "crop-page":
            let doc = p.value("--doc") ?? p.positional.first ?? ""
            guard !doc.isEmpty else {
                throw CortexSocketClient.ClientError("Bitte Titel oder ID der PDF angeben, z. B. cortexrag page-figures \"Distributed_Systems\" --page 19")
            }
            let page = p.int("--page", "--page-start") ?? (p.positional.count >= 2 ? Int(p.positional[1]) : nil) ?? 1
            return IPCRequest(
                action: .pageFigures,
                source: "cli",
                documentQuery: doc,
                pageNumber: page,
                cropIfMissing: true
            )

        case "expand", "context":
            let chunkID = p.value("--chunk-id") ?? p.positional.first ?? ""
            guard !chunkID.isEmpty else { throw CortexSocketClient.ClientError("Bitte eine chunk_id angeben.") }
            return IPCRequest(action: .expand, source: "cli", chunkID: chunkID,
                              beforeChunks: p.int("--before") ?? 2, afterChunks: p.int("--after") ?? 2)

        case "toc", "info", "overview":
            let doc = p.value("--doc") ?? p.positional.joined(separator: " ")
            guard !doc.isEmpty else { throw CortexSocketClient.ClientError("Bitte Titel oder ID der PDF angeben.") }
            return IPCRequest(action: .documentOverview, source: "cli", documentQuery: doc)

        case "read":
            let doc = p.value("--doc") ?? p.positional.joined(separator: " ")
            guard !doc.isEmpty else { throw CortexSocketClient.ClientError("Bitte Titel oder ID der PDF angeben, z. B. cortexrag read \"Distributed_Systems\" --pages 3-5") }
            let range = parsePageRange(p.value("--pages")) ?? (p.int("--page-start") ?? 1, p.int("--page-end") ?? p.int("--page-start") ?? 1)
            return IPCRequest(action: .readPages, source: "cli",
                              scope: ScopeFilter(pageStart: range.0, pageEnd: range.1), documentQuery: doc)

        case "index", "ingest":
            let path = p.value("--path") ?? p.positional.first ?? ""
            guard !path.isEmpty else { throw CortexSocketClient.ClientError("Bitte --path <PDF-oder-Ordner> angeben.") }
            let absPath = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: absPath, isDirectory: &isDir) else {
                throw CortexSocketClient.ClientError("Pfad nicht gefunden: \(absPath)")
            }
            return IPCRequest(
                action: isDir.boolValue ? .indexFolder : .indexPDF, source: "cli", path: absPath,
                collectionID: p.value("--collection-id"), collectionName: p.value("--collection"),
                engine: p.value("--engine").flatMap { EngineKind(rawValue: $0.lowercased()) },
                force: p.has("--force")
            )

        case "benchmark":
            return IPCRequest(action: .benchmark, source: "cli")

        default:
            return nil
        }
    }

    // MARK: Human readable output

    static func printHuman(_ resp: IPCResponse) {
        guard resp.ok else {
            fputs("Fehler: \(resp.error ?? "Unbekannter Fehler")\n", stderr)
            return
        }
        let t = AgentJSON.title

        if let st = resp.status {
            print("CortexRAG  ·  verbunden mit App (\(st.socketPath))")
            print("Engine:      \(st.activeEngine)")
            print("App-Auswahl: \(st.activeUIScope.isEmpty ? "keine – ganze Bibliothek" : st.activeUIScope.summaryDescription)\(st.enforceUIScopeForAgents ? "" : " (für Agenten deaktiviert)")")
            print("")
            for mod in st.hierarchy {
                print("\(mod.isSelectedInUI ? "●" : "○") \(mod.name)  [\(mod.id)]")
                for col in mod.collections {
                    print("   \(col.isSelectedInUI ? "●" : "○") \(col.name)  [\(col.id)] · \(col.totalDocumentCount) PDF")
                    for fol in col.folders {
                        print("      \(fol.isSelectedInUI ? "●" : "○") 📁 \(fol.name)  [\(fol.id)]")
                        for d in fol.documents { print("         · \(t(d.title))  (\(d.pageCount) S., \(d.figureCount) Abb.)  [\(d.id)]") }
                    }
                    for d in col.directDocuments { print("      · \(t(d.title))  (\(d.pageCount) S., \(d.figureCount) Abb.)  [\(d.id)]") }
                }
            }
        }

        if let sr = resp.searchResponse {
            print("„\(sr.query)“  ·  \(sr.results.count) Treffer  ·  \(sr.latencyMs) ms  ·  \(sr.scope.summaryDescription)\n")
            for r in sr.results {
                print("[\(r.rank)] \(t(r.documentTitle)) – S. \(r.pageNumber)   (Score \(r.score))")
                print("    \(t(r.breadcrumb))")
                print("    chunk_id: \(r.chunkID)")
                let text = CortexTextSanitizer.cleanText(r.matchedContent)
                print(text.split(separator: "\n").map { "    │ \($0)" }.joined(separator: "\n"))
                for f in r.figuresOnPage.prefix(3) { print("    🖼  \(f.label): \(f.croppedImagePath)") }
                print("")
            }
        }

        if let fr = resp.figureResponse {
            print("Abbildungen für „\(fr.query)“  ·  \(fr.scope.summaryDescription)\n")
            for (i, f) in fr.figures.enumerated() {
                print("[\(i + 1)] \(f.label) – \(t(f.documentTitle)) S. \(f.pageNumber)   (Score \(f.score))")
                let cleanedCaption = ChunkDisplayCleaner.clean(f.caption)
                if !cleanedCaption.isEmpty { print("    \(cleanedCaption)") }
                print("    \(f.croppedImagePath)\n")
            }
        }

        if let ex = resp.expandedItem {
            print("\(t(ex.documentTitle)) – S. \(ex.pageNumber)  ·  \(t(ex.breadcrumb))\n")
            if !ex.contextBefore.isEmpty { print("── davor ──\n\(CortexTextSanitizer.cleanText(ex.contextBefore))\n") }
            print("── Treffer ──\n\(CortexTextSanitizer.cleanText(ex.matchedContent))\n")
            if !ex.contextAfter.isEmpty { print("── danach ──\n\(CortexTextSanitizer.cleanText(ex.contextAfter))") }
        }

        if let ov = resp.documentOverview {
            print("\(t(ov.document.title))  [\(ov.document.id)]")
            print("\(ov.moduleName) › \(ov.collectionName)  ·  \(ov.document.pageCount) S.  ·  \(ov.document.chunkCount) Abschnitte  ·  \(ov.figures.count) Abb.")
            print(ov.document.filePath)
            if !ov.document.toc.isEmpty {
                print("\nInhalt:")
                for item in ov.document.toc {
                    print("\(String(repeating: "  ", count: max(0, item.level - 1)))  S. \(item.pageNumber)  \(item.title)")
                }
            }
        }

        if let pt = resp.pageText {
            print("\(t(pt.documentTitle))  (\(pt.pageCount) S.)\n")
            if pt.pages.isEmpty { print("(Kein indizierter Text in diesem Seitenbereich.)") }
            for page in pt.pages {
                print("━━ Seite \(page.page) ━━\n\(CortexTextSanitizer.cleanText(page.text))\n")
            }
        }

        if let d = resp.indexedDocument {
            print("✓ Indiziert: \(t(d.title)) (\(d.pageCount) S., \(d.chunkCount) Abschnitte, \(d.figureCount) Abb.)")
        }

        if let bm = resp.benchmarkReport {
            print("Benchmark (\(bm.hardwareModel))")
            for (name, m) in [("llama.cpp", bm.llamaMetrics), ("MLX", bm.mlxMetrics)] {
                guard let m else { continue }
                print("  \(name): Query p50 \(m.queryLatencyP50Ms) ms · p95 \(m.queryLatencyP95Ms) ms · \(m.batchTextThroughputChunksPerSec) Chunks/s · Peak \(m.peakMemoryMB) MB")
            }
            print("  Text-Parität: \(bm.meanTextCosineSimilarity ?? 0)  ·  Top-1-Übereinstimmung: \(bm.topKAgreementRate ?? 0) %")
            print("  \(bm.recommendation)")
        }
    }

    static func printUsage() {
        print("""
        cortexrag – CLI & MCP-Server für CortexRAG

        Bibliothek
          cortexrag status                         Bibliotheksbaum, Engine, Auswahl in der App
          cortexrag toc "<PDF>"                    Inhaltsverzeichnis & Abbildungen einer PDF
          cortexrag read "<PDF>" --pages 3-5       Indizierten Text einzelner Seiten lesen (max. 20)

        Suchen
          cortexrag search "<Frage>" [Filter] [--content all|text|figures] [--context 1] [--top-k 6] [--granularity compact|standard|expanded] [--max-chars N] [--min-score 0.X] [--no-figures]
          cortexrag figures "<Beschreibung>" [Filter] [--top-k 6]
          cortexrag page-figures "<PDF>" --page N  Alle freigestellten Bilder/Diagramme einer Seite abrufen (oder live croppen)
          cortexrag expand <chunk_id> [--before 2] [--after 2]

          Filter: --module <Name> --collection <Name> --folder <Name> --doc <Titel|ID>
                  (mehrere kommagetrennt) --page-start N --page-end N
                  --use-ui-scope (Auswahl der App)   --all (ganze Bibliothek, App-Auswahl ignorieren)

        Verwaltung
          cortexrag index <PDF-oder-Ordner> --collection <Name> [--force]   (unveränderte PDFs werden übersprungen)
          cortexrag engine llama|mlx
          cortexrag benchmark

        Agenten
          cortexrag mcp                            MCP-Server über stdio

        Ausgabe
          --json        vollständige Rohdaten     --compact   kompaktes JSON für Skripte/Agenten

        CLI und MCP funktionieren nur, solange CortexRAG.app läuft und der Agenten-Zugriff aktiv ist.
        """)
    }
}

// MARK: - MCP server (JSON-RPC 2.0 over stdio)

struct MCPServer {
    static let supportedVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
    CortexRAG durchsucht die lokale Fachbibliothek des Nutzers (Lehrbücher, Vorlesungsfolien, Skripte) mit Vektor- & Hybridsuche.
    Workflow für KI-Modelle & Agenten:
    1) cortex_list_library: Liefert den Bibliotheksbaum (Fachbereiche, Sammlungen, Ordner, Dokumente) und die aktuelle App-Auswahl.
    2) cortex_search_knowledge: Hauptsuchwerkzeug für Text & Abbildungen.
       - Token- & Kontextoptimierung: Nutze 'chunk_granularity: "compact"' oder 'max_chars_per_chunk' (z. B. 400), um Context Window und Antwortzeit zu schonen. Nutze 'min_score' (z. B. 0.35–0.5), um irrelevantes Rauschen auszufiltern.
       - Multimodalität: Setze 'include_base64_images: true' oder nutze cortex_get_page_figures, wenn du Diagramme, Systemarchitekturen oder Schemata visuell analysieren willst.
    3) cortex_get_page_figures: Liefert alle fertig ausgeschnittenen (gecroppten) Abbildungen einer Seite als Markdown-Einbettungen (![Label](file:///...)) sowie optional als direkte Base64-Bilddaten für Bildverarbeitung.
    4) cortex_expand_context oder cortex_read_pages: Längere Passagen oder ganze Kapitel am Stück lesen; cortex_get_document_overview für das Inhaltsverzeichnis.
    Zitiere Fundstellen stets mit Dokumenttitel und genauer Seitenzahl.
    """

    func run() async {
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else {
                send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                continue
            }
            if let batch = parsed as? [[String: Any]] {
                for msg in batch { await handle(msg) }
            } else if let msg = parsed as? [String: Any] {
                await handle(msg)
            }
        }
    }

    private func handle(_ msg: [String: Any]) async {
        let method = msg["method"] as? String ?? ""
        let id = msg["id"]
        let params = msg["params"] as? [String: Any] ?? [:]
        // Notifications (no id) never get a response.
        guard let id, !(id is NSNull) else { return }

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedVersions.contains(requested) ? requested : Self.supportedVersions[0]
            reply(id, [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "cortexrag", "title": "CortexRAG Fachbibliothek", "version": "2.0.0"],
                "instructions": Self.instructions
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": Self.tools])
        case "resources/list":
            reply(id, ["resources": [Any]()])
        case "resources/templates/list":
            reply(id, ["resourceTemplates": [Any]()])
        case "prompts/list":
            reply(id, ["prompts": [Any]()])
        case "tools/call":
            await callTool(id: id, params: params)
        default:
            send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private func callTool(id: Any, params: [String: Any]) async {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        let req: IPCRequest
        var includeFigures = true
        var includeBase64Images = false
        do {
            switch name {
            case "cortex_list_library":
                req = IPCRequest(action: .status, source: "mcp")
            case "cortex_get_document_overview":
                req = IPCRequest(action: .documentOverview, source: "mcp", documentQuery: try requireString(args, "document", "document_title", "document_id", "document_name"))
            case "cortex_search_knowledge":
                includeFigures = bool(args["include_figures"]) ?? true
                includeBase64Images = bool(args["include_base64_images"]) ?? false
                let contentMode = (args["content"] as? String).flatMap { SearchContentMode(rawValue: $0.lowercased()) }
                    ?? (includeFigures ? .all : .text)
                req = IPCRequest(
                    action: .search, source: "mcp", query: try requireString(args, "query"), scope: scope(args),
                    contextChunks: min(5, max(0, int(args["context_chunks"]) ?? 1)), includeFigures: includeFigures,
                    content: contentMode, topK: min(30, max(1, int(args["top_k"]) ?? 6)), engine: engine(args),
                    chunkGranularity: args["chunk_granularity"] as? String,
                    maxCharsPerChunk: int(args["max_chars_per_chunk"]),
                    minScore: double(args["min_score"])
                )
            case "cortex_search_figures":
                includeBase64Images = bool(args["include_base64_images"]) ?? false
                req = IPCRequest(action: .figures, source: "mcp", query: try requireString(args, "query"), scope: scope(args),
                                 topK: min(30, max(1, int(args["top_k"]) ?? 6)), engine: engine(args))
            case "cortex_get_page_figures":
                let doc = try requireString(args, "document", "document_id", "document_title", "document_name")
                let page = int(args["page"] ?? args["page_number"] ?? args["page_start"]) ?? 1
                let cropIfMissing = bool(args["crop_if_missing"]) ?? true
                includeBase64Images = bool(args["include_base64_images"]) ?? false
                req = IPCRequest(
                    action: .pageFigures,
                    source: "mcp",
                    documentQuery: doc,
                    pageNumber: page,
                    cropIfMissing: cropIfMissing
                )
            case "cortex_expand_context":
                req = IPCRequest(action: .expand, source: "mcp", chunkID: try requireString(args, "chunk_id"),
                                 beforeChunks: min(10, max(0, int(args["before"]) ?? 2)),
                                 afterChunks: min(10, max(0, int(args["after"]) ?? 2)))
            case "cortex_read_pages":
                let start = int(args["page_start"] ?? args["page"]) ?? 1
                let end = int(args["page_end"]) ?? start
                req = IPCRequest(action: .readPages, source: "mcp", scope: ScopeFilter(pageStart: start, pageEnd: end),
                                 documentQuery: try requireString(args, "document", "document_title", "document_id", "document_name"))
            case "cortex_switch_engine":
                guard let eng = engine(args) else { throw ToolError("Parameter 'engine' muss 'llama' oder 'mlx' sein.") }
                req = IPCRequest(action: .switchEngine, source: "mcp", engine: eng)
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32602, "message": "Unknown tool: \(name)"]])
                return
            }
        } catch {
            reply(id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            return
        }

        do {
            let resp = try CortexBackend.send(req)
            let body = AgentJSON.render(resp, includeFigures: includeFigures)
            var contentBlocks: [[String: Any]] = [["type": "text", "text": AgentJSON.string(body, pretty: false)]]
            if includeBase64Images {
                var imagesToInclude: [String] = []
                if let figs = resp.figureResponse?.figures {
                    imagesToInclude.append(contentsOf: figs.prefix(4).map(\.croppedImagePath))
                } else if let topHit = resp.searchResponse?.results.first {
                    imagesToInclude.append(contentsOf: topHit.figuresOnPage.prefix(3).map(\.croppedImagePath))
                }
                for path in imagesToInclude {
                    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                        contentBlocks.append([
                            "type": "image",
                            "data": data.base64EncodedString(),
                            "mimeType": "image/png"
                        ])
                    }
                }
            }
            // Compact JSON keeps agent context usage low.
            reply(id, ["content": contentBlocks, "isError": !resp.ok])
        } catch {
            reply(id, ["content": [["type": "text", "text": "Fehler: \(error)"]], "isError": true])
        }
    }

    // MARK: Argument parsing

    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    private func requireString(_ args: [String: Any], _ keys: String...) throws -> String {
        for k in keys {
            if let s = args[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        throw ToolError("Pflichtparameter '\(keys[0])' fehlt.")
    }

    private func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private func bool(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let s = v as? String { return ["true", "1", "yes", "ja"].contains(s.lowercased()) }
        return nil
    }

    private func list(_ v: Any?) -> [String]? {
        if let s = v as? String { return splitCSV(s) }
        if let arr = v as? [Any] {
            let items = arr.compactMap { $0 as? String }.flatMap { splitCSV($0) ?? [] }
            return items.isEmpty ? nil : items
        }
        return nil
    }

    private func engine(_ args: [String: Any]) -> EngineKind? {
        (args["engine"] as? String).flatMap { EngineKind(rawValue: $0.lowercased()) }
    }

    private func scope(_ args: [String: Any]) -> ScopeFilter {
        ScopeFilter(
            moduleNames: list(args["module"] ?? args["modules"]),
            collectionNames: list(args["collection"] ?? args["collections"]),
            folderNames: list(args["folder"] ?? args["folders"]),
            documentTitles: list(args["document"] ?? args["documents"]),
            pageStart: int(args["page_start"]),
            pageEnd: int(args["page_end"]),
            useUISelection: bool(args["use_ui_selection"])
        )
    }

    // MARK: Output

    private func reply(_ id: Any, _ result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func send(_ msg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: [.withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return }
        print(str)
        fflush(stdout)
    }

    // MARK: Tool definitions

    static var scopeProperties: [String: Any] { [
        "module": ["type": "string", "description": "Fachbereich (Name oder ID), mehrere kommagetrennt"],
        "collection": ["type": "string", "description": "Sammlung/Fach, z. B. 'Verteilte Systeme' (Name oder ID), mehrere kommagetrennt"],
        "folder": ["type": "string", "description": "Vorlesungsordner (Name, Pfad oder ID)"],
        "document": ["type": "string", "description": "Einzelne PDF(s): Titel oder ID, mehrere kommagetrennt"],
        "use_ui_selection": ["type": "boolean", "description": "true: in der aktuell in der App angehakten Auswahl suchen. false: App-Auswahl ignorieren."]
    ] }

    static var tools: [[String: Any]] {
        let readOnly: [String: Any] = ["readOnlyHint": true, "openWorldHint": false]
        var searchProps = scopeProperties
        searchProps["query"] = ["type": "string", "description": "Frage oder Fachbegriff in natürlicher Sprache"]
        searchProps["content"] = ["type": "string", "enum": ["all", "text", "figures"], "description": "Was gesucht wird: 'all' (Text + Bilder gemeinsam per Rank-Fusion, Standard), 'text' (nur Textstellen), 'figures' (nur Abbildungen)"]
        searchProps["page_start"] = ["type": "integer", "description": "Optional: nur ab dieser Seite"]
        searchProps["page_end"] = ["type": "integer", "description": "Optional: nur bis zu dieser Seite"]
        searchProps["context_chunks"] = ["type": "integer", "description": "Nachbarabschnitte davor/danach (0–5, Standard 1)"]
        searchProps["top_k"] = ["type": "integer", "description": "Anzahl Treffer (1–30, Standard 6)"]
        searchProps["include_figures"] = ["type": "boolean", "description": "Abbildungen der Fundseite mitliefern (Standard true)"]
        searchProps["include_base64_images"] = ["type": "boolean", "description": "Gecroppte PNGs der Trefferseite direkt als Base64-Bilder einbetten (Standard false)"]
        searchProps["chunk_granularity"] = [
            "type": "string",
            "enum": ["compact", "standard", "expanded"],
            "description": "Detailgrad der Textauszüge: 'compact' (~300 Zeichen, spart Modell-Kontext), 'standard' (vollständiger Chunk ~800–1200 Zeichen), 'expanded' (inklusive Vor- und Nachkontext)"
        ]
        searchProps["max_chars_per_chunk"] = [
            "type": "integer",
            "description": "Maximale Zeichenanzahl pro Chunk (z. B. 400 oder 800) zur Begrenzung der Context-Größe"
        ]
        searchProps["min_score"] = [
            "type": "number",
            "description": "Mindest-Relevanzwert (0.0 bis 1.0), filtert ungenaue Treffer heraus"
        ]

        var figureProps = scopeProperties
        figureProps["query"] = ["type": "string", "description": "Beschreibung der gesuchten Abbildung, Tabelle oder des Schemas"]
        figureProps["top_k"] = ["type": "integer", "description": "Anzahl Abbildungen (1–30, Standard 6)"]
        figureProps["include_base64_images"] = ["type": "boolean", "description": "Optional: true gibt die gecroppten PNG-Bilder zusätzlich als native MCP-Bildblöcke (Base64) zurück (Standard false)"]

        return [
            [
                "name": "cortex_list_library",
                "title": "Bibliothek anzeigen",
                "description": "Zuerst aufrufen. Liefert den Bibliotheksbaum (Fachbereich → Sammlung → Ordner → PDF) mit IDs, Seiten- und Abbildungszahlen sowie die aktuelle Auswahl des Nutzers in der App.",
                "inputSchema": ["type": "object", "properties": [String: Any]()],
                "annotations": readOnly
            ],
            [
                "name": "cortex_search_knowledge",
                "title": "Wissen & Abbildungen suchen",
                "description": "Hybride semantische + Stichwortsuche (Text + Bilder über Rank-Fusion). Liefert pro Treffer Text, Dokument, Seite, Kapitel, chunk_id, Nachbarabschnitte und freigestellte Abbildungen (figures_on_page). Steuere den Token-Verbrauch gezielt über 'chunk_granularity' ('compact', 'standard', 'expanded') oder 'max_chars_per_chunk'. Filtere Rauschen via 'min_score' (0.0–1.0) und erhalte multimodale Bildausschnitte direkt über 'include_base64_images: true'. Ohne Filter gilt die App-Auswahl (falls aktiv), sonst die ganze Bibliothek.",
                "inputSchema": ["type": "object", "properties": searchProps, "required": ["query"]],
                "annotations": readOnly
            ],
            [
                "name": "cortex_search_figures",
                "title": "Abbildungen suchen",
                "description": "Sucht ausgeschnittene Abbildungen, Diagramme und Tabellen. Liefert PNG-Pfade (image, page_image), Markdown-Einbettung, Bildunterschrift, Dokument und Seite.",
                "inputSchema": ["type": "object", "properties": figureProps, "required": ["query"]],
                "annotations": readOnly
            ],
            [
                "name": "cortex_get_page_figures",
                "title": "Bilder einer Seite freistellen & abrufen",
                "description": "Liefert alle fertig ausgeschnittenen (gecroppten) Abbildungen, Diagramme und Tabellen einer bestimmten Seite einer PDF zur visuellen Analyse oder Markdown-Einbettung. Falls die Bilder der Seite noch nicht vorliegen, werden sie automatisch per Apple Vision freigestellt und als PNG gespeichert. Mit 'include_base64_images: true' werden die Bilddaten direkt als multimodale Blöcke übermittelt.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "document": ["type": "string", "description": "Titel, ID oder Pfad der PDF (z. B. aus einem Suchtreffer)"],
                        "page": ["type": "integer", "description": "Seitenzahl (1-basiert), deren Bilder freigestellt und zurückgegeben werden sollen"],
                        "include_base64_images": ["type": "boolean", "description": "Optional: true liefert die gecroppten PNG-Bilder zusätzlich direkt als Base64-Bildblöcke ans Modell (Standard false)"]
                    ],
                    "required": ["document", "page"]
                ],
                "annotations": readOnly
            ],
            [
                "name": "cortex_expand_context",
                "title": "Kontext erweitern",
                "description": "Lädt die Abschnitte vor und nach einer chunk_id (oder fig:<figure_id>) aus einem Suchergebnis.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "chunk_id": ["type": "string", "description": "chunk_id aus cortex_search_knowledge (auch fig:<id> wird unterstützt)"],
                        "before": ["type": "integer", "description": "Abschnitte davor (0–10, Standard 2)"],
                        "after": ["type": "integer", "description": "Abschnitte danach (0–10, Standard 2)"]
                    ],
                    "required": ["chunk_id"]
                ],
                "annotations": readOnly
            ],
            [
                "name": "cortex_read_pages",
                "title": "Seiten lesen",
                "description": "Liest den indizierten Text eines Seitenbereichs einer PDF (maximal 20 Seiten pro Aufruf), z. B. um ein ganzes Kapitel zu erfassen.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "document": ["type": "string", "description": "Titel oder ID der PDF"],
                        "page_start": ["type": "integer", "description": "Erste Seite (Standard 1)"],
                        "page_end": ["type": "integer", "description": "Letzte Seite (Standard = page_start)"]
                    ],
                    "required": ["document"]
                ],
                "annotations": readOnly
            ],
            [
                "name": "cortex_get_document_overview",
                "title": "Inhaltsverzeichnis",
                "description": "Inhaltsverzeichnis (mit Seitenzahlen), Umfang und extrahierte Abbildungen einer PDF.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["document": ["type": "string", "description": "Titel oder ID der PDF"]],
                    "required": ["document"]
                ],
                "annotations": readOnly
            ],
            [
                "name": "cortex_switch_engine",
                "title": "Embedding-Engine wechseln",
                "description": "Wechselt die Embedding-Engine zwischen 'llama' (llama.cpp Metal) und 'mlx' (MLX Swift). Nur nötig für Vergleiche.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["engine": ["type": "string", "enum": ["llama", "mlx"]]],
                    "required": ["engine"]
                ],
                "annotations": ["readOnlyHint": false, "idempotentHint": true, "openWorldHint": false]
            ]
        ]
    }
}
