import AppKit
import SwiftUI
import CortexCore

/// Developer-only UI automation for visual verification without screen-recording permission.
/// Active only when the environment variable `CORTEXRAG_DEBUG_DIR` is set. The app then polls
/// `<dir>/cmd.txt` once per second and executes one command per line:
///   tab ask|figures|library|agents · query <text> · figquery <text> · select-doc <title> · clear-selection
///   reader-first-result · open-doc <title> · settings · snap <name> · appearance light|dark|system
/// Snapshots are written to `<dir>/<name>-<window>.png`.
@MainActor
enum DebugAutomation {
    private static var timer: Timer?

    static func startIfRequested(vm: AppViewModel) {
        guard timer == nil, let dir = ProcessInfo.processInfo.environment["CORTEXRAG_DEBUG_DIR"], !dir.isEmpty else { return }
        let cmdURL = URL(fileURLWithPath: dir).appendingPathComponent("cmd.txt")
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let text = try? String(contentsOf: cmdURL, encoding: .utf8), !text.isEmpty else { return }
                try? FileManager.default.removeItem(at: cmdURL)
                for line in text.split(separator: "\n") {
                    run(String(line), vm: vm, dir: dir)
                }
            }
        }
    }

    private static func run(_ line: String, vm: AppViewModel, dir: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard let cmd = parts.first else { return }
        let arg = parts.count > 1 ? parts[1] : ""
        switch cmd {
        case "tab":
            if let tab = WorkspaceTab.allCases.first(where: { "\($0)".lowercased() == arg.lowercased() }) { vm.activeTab = tab }
        case "query":
            vm.activeTab = .ask
            vm.searchQuery = arg
            vm.submitSearch()
        case "content-mode":
            vm.settings.searchContentMode = SearchContentMode(rawValue: arg) ?? .all
        case "select-doc":
            if let d = vm.documents.first(where: { CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(arg) }) {
                vm.toggleDocument(d.id)
            }
        case "select-col":
            if let c = vm.collections.first(where: { $0.name.localizedCaseInsensitiveContains(arg) }) { vm.toggleCollection(c.id) }
        case "clear-selection":
            vm.clearSelection()
        case "library-doc":
            vm.activeTab = .library
            vm.libraryDocumentID = vm.documents.first(where: { CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(arg) })?.id
        case "focus-result":
            let idx = max(0, (Int(arg) ?? 1) - 1)
            if idx < vm.searchResults.count { vm.highlightedResultID = vm.searchResults[idx].id }
        case "reader-first-result":
            if let r = vm.searchResults.first { vm.openReader(result: r) }
        case "reader-result":
            let idx = max(0, (Int(arg) ?? 1) - 1)
            if idx < vm.searchResults.count { vm.openReader(result: vm.searchResults[idx]) }
        case "reader-citation":
            vm.jumpToCitation(Int(arg) ?? 1)
        case "open-doc":
            if let d = vm.documents.first(where: { CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(arg) }) {
                vm.openReader(document: d)
            }
        case "settings":
            vm.settingsTab = Int(arg) ?? 0
            vm.openSettingsAction?()
        case "close-settings":
            NSApp.windows.first(where: { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Allgemein") || $0.title.contains("KI-Antworten")
                || $0.title.contains("General") || $0.title.contains("AI answers") })?.close()
        case "followup":
            vm.submitFollowUp(arg)
        case "pages":
            let parts = arg.split(separator: "-").compactMap { Int($0) }
            vm.pageStart = parts.first
            vm.pageEnd = parts.count > 1 ? parts[1] : nil
        case "reader-find", "reader-mode", "reader-two", "figure-detail", "reader-figure", "peek":
            // Handled by the respective views (they own the state).
            NotificationCenter.default.post(name: .init("CortexDebug"), object: "\(cmd) \(arg)")
        case "expand-folders":
            vm.expandAllSidebarFolders()
        case "collapse-folders":
            vm.collapseAllSidebarFolders()
        case "toggle-folder":
            vm.toggleFolderExpansion(arg, defaultExpanded: false)
        case "ai":
            vm.settings.enableAISynthesis = (arg == "on")
        case "ai-images":
            vm.settings.maxImagesForLLM = Int(arg) ?? (arg == "off" ? 0 : 4)
        case "image-mode":
            if let mode = ImageVectorMode(rawValue: arg) { vm.settings.imageVectorMode = mode }
        case "ac-only":
            vm.settings.indexOnlyOnACPower = (arg == "on")
        case "profile-url":
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, let i = vm.settings.llmProfiles.firstIndex(where: { $0.id == parts[0] }) {
                vm.settings.llmProfiles[i].endpointURL = parts[1]
            }
        case "profile-model":
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2, let i = vm.settings.llmProfiles.firstIndex(where: { $0.id == parts[0] }) {
                vm.settings.llmProfiles[i].model = parts[1]
            }
        case "profile-activate":
            vm.activateProfile(arg)
        case "ping-all":
            Task { await vm.pingAllProfiles() }
        case "focus-answer":
            vm.highlightedResultID = nil
            DispatchQueue.main.async { vm.highlightedResultID = "answer" }
        case "dump-state":
            let st = vm.synthesisState
            let obj: [String: Any] = ["model": st.modelUsed, "error": st.errorMessage ?? "", "generating": st.isGenerating,
                                      "answer": String(st.answerText.prefix(600)), "turns": vm.previousTurns.count,
                                      "sources": vm.conversationSources.count,
                                      "figureSources": vm.conversationSources.filter(\.isFigure).count,
                                      "profile": vm.settings.activeLLMProfile?.name ?? "",
                                      "promptTokens": st.promptTokens ?? -1, "cachedTokens": st.cachedPromptTokens ?? -1,
                                      "firstTokenMs": st.firstTokenMs ?? -1, "submitToAIRequestMs": (vm.lastAIRequestAt?.timeIntervalSince(vm.lastSubmitAt ?? .distantFuture)).map { $0 * 1000 } ?? -1,
                                      "searchMs": vm.lastSearchLatencyMs ?? -1, "images": st.promptImages.count, "latencyMs": st.latencyMs,
                                      "pings": vm.profilePings.mapValues { "\($0.ok) \($0.message)" }]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "accent":
            if let c = AccentChoice(rawValue: arg) { vm.settings.accentChoice = c }
        case "export":
            let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { break }
            let text: String
            switch parts[0] {
            case "md": text = ExportFormatter.conversationMarkdown(vm)
            case "latex": text = ExportFormatter.conversationLaTeX(vm)
            case "script": text = ExportFormatter.studyScriptMarkdown(vm)
            case "json": text = ExportFormatter.resultsJSON(vm)
            default: text = ExportFormatter.resultsMarkdownList(vm)
            }
            try? text.write(toFile: parts[1], atomically: true, encoding: .utf8)
        case "reranker":
            vm.settings.neuralReranker = NeuralRerankerModel(rawValue: arg) ?? .none
        case "toggle-context":
            vm.settings.showSurroundingContextExpanded.toggle()
        case "agents":
            vm.setAgentAccess(arg == "on")
        case "thinking":
            vm.setThinking(arg == "on")
        case "appearance":
            vm.settings.appearanceMode = AppAppearanceMode(rawValue: arg) ?? .system
        case "import":
            vm.beginImport(arg.components(separatedBy: "|").map { URL(fileURLWithPath: $0) })
        case "import-confirm":
            if let p = vm.pendingImport { vm.confirmImport(p, target: p.target) }
        case "import-cancel":
            vm.pendingImport = nil
        case "import-drop":
            // import-drop <topic name>|<path>
            let p = arg.components(separatedBy: "|")
            if p.count == 2, let t = vm.collections.first(where: { $0.name.localizedCaseInsensitiveContains(p[0]) }) {
                vm.importDirect([URL(fileURLWithPath: p[1])], topicID: t.id)
            }
        case "import-cancel-all":
            vm.importer.cancelAll()
        case "import-pause":
            vm.importer.pause()
        case "import-resume":
            vm.importer.resume()
        case "deduplicate":
            vm.deduplicateLibrary()
        case "reindex-doc":
            if let doc = vm.documents.first(where: { $0.title.localizedCaseInsensitiveContains(arg) }) {
                vm.reindex([doc])
            }
        case "battery-mode":
            switch arg {
            case "pause":
                vm.settings.indexOnlyOnACPower = true
            case "minimal":
                vm.settings.indexOnlyOnACPower = false
                vm.settings.batteryThrottlingMode = .ecoSilent
            case "balanced":
                vm.settings.indexOnlyOnACPower = false
                vm.settings.batteryThrottlingMode = .balanced
            case "maximal":
                vm.settings.indexOnlyOnACPower = false
                vm.settings.batteryThrottlingMode = .turbo
            default:
                break
            }
        case "followup-open":
            NotificationCenter.default.post(name: .init("CortexDebug"), object: arg.isEmpty ? "followup-open" : "followup-open \(arg)")
        case "followup-send":
            NotificationCenter.default.post(name: .init("CortexDebug"), object: "followup-send \(arg)")
        case "filter":
            vm.sidebarFilter = arg
        case "select-subfolder":
            vm.toggleSubfolder(arg)
        case "new-area":
            vm.createModule(name: arg)
        case "move-topic":
            // move-topic <topic>|<area or empty>
            let p = arg.components(separatedBy: "|")
            if p.count == 2, let t = vm.collections.first(where: { $0.name.localizedCaseInsensitiveContains(p[0]) }) {
                vm.moveCollection(t.id, toModule: vm.modules.first { $0.name.localizedCaseInsensitiveContains(p[1]) && !p[1].isEmpty }?.id ?? "")
            }
        case "dump-library":
            let obj: [String: Any] = [
                "areas": vm.modules.map(\.name),
                "topics": vm.collections.map { c in ["name": c.name, "area": vm.modules.first { $0.id == c.moduleID }?.name ?? ""] },
                "folders": vm.watchedFolders.map { f in ["name": f.name, "topic": vm.collectionName(f.collectionID), "path": f.path] },
                "documents": vm.documents.map { d in ["title": d.title, "topic": vm.collectionName(d.collectionID),
                                                       "folder": vm.watchedFolders.first { $0.id == d.folderID }?.name ?? "",
                                                       "chunks": d.chunkCount, "figures": d.figureCount] },
                "queue": vm.importer.jobs.map { "\($0.title): \($0.state) (\($0.detail))" },
                "queueRunning": vm.importer.isRunning,
                "pending": vm.pendingImport.map { "\($0.target)" } ?? "",
                "scope": vm.scopeSummary,
                "scoped": vm.scopedDocuments.count,
                "expandedFolders": Array(vm.expandedFolderPaths),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: arg))
            }
        case "refresh-captions":
            vm.refreshFigureCaptions()
        case "snap":
            snapshot(name: arg.isEmpty ? "snap" : arg, dir: dir)
        default:
            break
        }
    }

    private static func snapshot(name: String, dir: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible && window.frame.width > 300 {
            guard let view = window.contentView?.superview ?? window.contentView else { continue }
            let bounds = view.bounds
            guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            view.cacheDisplay(in: bounds, to: rep)
            let label = (window.title.isEmpty ? "window\(i)" : window.title).replacingOccurrences(of: "/", with: "-")
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(label).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
