import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CortexCore
import CortexEmbedders
import CortexVision
import CortexIPC

public enum WorkspaceTab: String, CaseIterable, Identifiable {
    case ask = "Fragen"
    case library = "Bibliothek"
    case agents = "Agenten"

    public var id: String { rawValue }
    public var icon: String {
        switch self {
        case .ask: return "sparkle.magnifyingglass"
        case .library: return "books.vertical"
        case .agents: return "terminal"
        }
    }
}

/// A finished question/answer round of the follow-up conversation in the answer card.
public struct ConversationTurn: Identifiable, Equatable {
    public let id = UUID()
    public var question: String
    public var state: AISynthesisStreamState
    public var fullPrompt: String?
    /// New sources this follow-up added (nil for the first question).
    public var addedSources: Int?
    public var strategyNote: String?

    public init(
        question: String,
        state: AISynthesisStreamState,
        fullPrompt: String? = nil,
        addedSources: Int? = nil,
        strategyNote: String? = nil
    ) {
        self.question = question
        self.state = state
        self.fullPrompt = fullPrompt ?? state.fullPrompt
        self.addedSources = addedSources
        self.strategyNote = strategyNote
    }
}

public enum FollowUpSearchMode: String, CaseIterable, Sendable {
    case auto, always, never
    var label: String {
        switch self {
        case .auto: return "Automatisch suchen"
        case .always: return "Immer neu suchen"
        case .never: return "Nur bisherige Quellen"
        }
    }
    var icon: String {
        switch self {
        case .auto: return "sparkle.magnifyingglass"
        case .always: return "magnifyingglass"
        case .never: return "text.magnifyingglass"
        }
    }
}

/// Thread-safe holder for the last streamed state (decides whether the fallback is needed).
final class StreamBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AISynthesisStreamState?
    func set(_ v: AISynthesisStreamState) { lock.withLock { value = v } }
    func get() -> AISynthesisStreamState? { lock.withLock { value } }
}

/// What the reader window should show.
public struct ReaderTarget: Equatable {
    public var documentID: String?
    public var documentPath: String
    public var title: String
    public var pageNumber: Int
    public var chunkText: String?
    public var figureBBox: NormalizedRect?
    /// Changes on every request so that re-opening the same location re-triggers the jump.
    public var token = UUID()
}

@MainActor
@Observable
public final class AppViewModel {
    public static weak var shared: AppViewModel?

    public let service: CortexService
    private var daemon: CortexSocketDaemon?

    // MARK: Settings (single source of truth, persisted on every change)

    public var settings: CortexSettings = CortexSettingsManager.shared.settings {
        didSet {
            guard settings != oldValue else { return }
            // Keep the active server profile and the effective llm* fields in sync (both directions).
            var synced = settings
            let fieldsChanged = (synced.llmEndpointURL, synced.llmApiKey, synced.llmSelectedModel, synced.llmProviderPreset)
                != (oldValue.llmEndpointURL, oldValue.llmApiKey, oldValue.llmSelectedModel, oldValue.llmProviderPreset)
            if synced.activeLLMProfileID != oldValue.activeLLMProfileID || synced.llmProfiles != oldValue.llmProfiles && !fieldsChanged {
                synced.applyActiveProfile()
            } else if fieldsChanged {
                synced.storeFieldsIntoActiveProfile()
            }
            if synced != settings { settings = synced }
            CortexSettingsManager.shared.settings = settings
            applySystemSettings(old: oldValue)
        }
    }

    // MARK: Library

    public var modules: [LibraryModule] = []
    public var collections: [LibraryCollection] = []
    public var watchedFolders: [WatchedFolder] = []
    public var documents: [LibraryDocument] = []
    public var agentEvents: [AgentActivityEvent] = []

    // Checkbox multi-selection across all levels (combined with OR)
    public var selectedModuleIDs: Set<String> = []
    public var selectedCollectionIDs: Set<String> = []
    public var selectedFolderIDs: Set<String> = []
    public var selectedDocumentIDs: Set<String> = []
    /// Subfolders of imported folders (absolute paths); selects everything below them.
    public var selectedSubfolderPaths: Set<String> = []
    /// Sidebar expansion state across all levels (Area -> Topic -> Root folder -> Subfolders at any depth).
    public var collapsedAreaIDs: Set<String> = []
    public var collapsedTopicIDs: Set<String> = []
    public var expandedFolderPaths: Set<String> = []
    public var collapsedFolderPaths: Set<String> = []

    public func isAreaExpanded(_ areaID: String) -> Bool {
        !collapsedAreaIDs.contains(areaID)
    }

    public func toggleAreaExpansion(_ areaID: String) {
        if collapsedAreaIDs.contains(areaID) { collapsedAreaIDs.remove(areaID) } else { collapsedAreaIDs.insert(areaID) }
    }

    public func isTopicExpanded(_ topicID: String) -> Bool {
        !collapsedTopicIDs.contains(topicID)
    }

    public func toggleTopicExpansion(_ topicID: String) {
        if collapsedTopicIDs.contains(topicID) { collapsedTopicIDs.remove(topicID) } else { collapsedTopicIDs.insert(topicID) }
    }

    public func isFolderExpanded(_ path: String, defaultExpanded: Bool) -> Bool {
        if expandedFolderPaths.contains(path) { return true }
        if collapsedFolderPaths.contains(path) { return false }
        return defaultExpanded
    }

    public func toggleFolderExpansion(_ path: String, defaultExpanded: Bool) {
        let current = isFolderExpanded(path, defaultExpanded: defaultExpanded)
        if current {
            expandedFolderPaths.remove(path)
            collapsedFolderPaths.insert(path)
        } else {
            collapsedFolderPaths.remove(path)
            expandedFolderPaths.insert(path)
        }
    }

    public func expandAllSidebarFolders() {
        collapsedAreaIDs.removeAll()
        collapsedTopicIDs.removeAll()
        collapsedFolderPaths.removeAll()
        for doc in documents {
            var dir = ((doc.filePath as NSString).deletingLastPathComponent as NSString).standardizingPath
            while dir.count > 1 && dir != "/" {
                expandedFolderPaths.insert(dir)
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
        for folder in watchedFolders {
            expandedFolderPaths.insert((folder.path as NSString).standardizingPath)
        }
    }

    public func collapseAllSidebarFolders() {
        expandedFolderPaths.removeAll()
    }

    /// Text of the sidebar filter field.
    public var sidebarFilter = ""
    /// Import waiting for the target dialog (drop on empty space, import button, menu).
    public var pendingImport: PendingImport?
    /// Optional page range applied to every search (1-based, inclusive).
    /// Values below 1 mean "no limit" (an emptied or zeroed field clears the bound).
    public var pageStart: Int? {
        didSet {
            if let p = pageStart, p < 1 { pageStart = nil; return }
            if pageStart != oldValue { scopeChanged() }
        }
    }
    public var pageEnd: Int? {
        didSet {
            if let p = pageEnd, p < 1 { pageEnd = nil; return }
            if pageEnd != oldValue { scopeChanged() }
        }
    }
    public var hasPageRange: Bool { pageStart != nil || pageEnd != nil }

    // MARK: Navigation & search

    public var activeTab: WorkspaceTab = .ask
    public var searchQuery: String = ""
    public var lastSubmittedQuery: String = ""
    public var searchResults: [SearchResultItem] = []
    public var isSearching = false
    public var lastSearchLatencyMs: Double?
    public var highlightedResultID: String?
    public var libraryDocumentID: String?

    // MARK: Display text cleanup (UI only; indexed text and LLM context stay raw)

    /// Per-document header/footer statistics for `ChunkDisplayCleaner`.
    @ObservationIgnored private var textProfiles: [String: DocumentTextProfile] = [:]

    public func ensureTextProfiles(for documentIDs: some Sequence<String>) {
        for id in Set(documentIDs) where textProfiles[id] == nil {
            let texts = (try? service.db.listChunks(documentID: id).map(\.content)) ?? []
            textProfiles[id] = DocumentTextProfile.build(from: texts)
        }
    }

    /// Text as shown in result cards and the reader: cleaned unless the user chose "Original".
    public func displayText(_ raw: String, documentID: String, page: Int? = nil) -> String {
        guard settings.chunkDisplayMode == .cleaned else { return raw }
        return ChunkDisplayCleaner.clean(raw, page: page, profile: textProfiles[documentID] ?? .empty)
    }

    // MARK: AI answer

    public var synthesisState = AISynthesisStreamState()
    /// Question of the answer currently shown/streaming (first search or latest follow-up).
    public var currentQuestion = ""
    /// Finished earlier rounds; empty unless the user asked a follow-up.
    public var previousTurns: [ConversationTurn] = []
    /// Stable, numbered sources of the conversation: index + 1 = citation number.
    public var conversationSources: [SearchResultItem] = []
    public var currentAddedSources: Int?
    public var currentStrategyNote: String?
    public var followUpSearchMode: FollowUpSearchMode = .auto
    public var isFollowUpSearching = false
    public var isConversation: Bool { !previousTurns.isEmpty }
    public var llmPingResult: LLMPingResult?
    /// Last ping per server profile (id → result).
    public var profilePings: [String: LLMPingResult] = [:]
    public var pingingProfiles: Set<String> = []
    public var isPingingLLM = false
    public var llmTestMessage: String?
    public var isTestingLLM = false
    private var synthesisTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    // MARK: Reader

    public var readerTarget: ReaderTarget?
    public var openWindowAction: OpenWindowAction?
    public var openSettingsAction: (() -> Void)?
    public var settingsTab = 0

    // MARK: Engine, daemon, jobs

    public var activeEngine: EngineKind = CortexSettingsManager.shared.settings.defaultEngine
    public var isSwitchingEngine = false
    public var isRefreshingCaptions = false
    /// Timing of the last question (debug measurements): when it was submitted and when the AI request started.
    @ObservationIgnored public var lastSubmitAt: Date?
    @ObservationIgnored public var lastAIRequestAt: Date?
    public var isDaemonActive = false
    public var memoryUsageMB: Double = 0
    /// Sequential indexing queue shown at the bottom of the sidebar.
    let importer: ImportQueue
    public var isIndexing: Bool { importer.isRunning }
    public var progressMessage = ""
    public var isBenchmarking = false
    public var benchmarkReport: EngineBenchmarkReport?
    public var errorBanner: String?
    /// Download progress (0…1) per reranker model while a download runs.
    public var rerankerDownloads: [NeuralRerankerModel: Double] = [:]
    @ObservationIgnored private var rerankerDownloadTasks: [NeuralRerankerModel: Task<Void, Never>] = [:]
    public var toast: LocalizedStringKey?

    // MARK: Onboarding & First-Time Setup

    public var showSetupAssistant: Bool = false
    public var isDownloadingEmbeddingModel: Bool = false
    public var embeddingDownloadProgress: Double = 0.0
    public var embeddingDownloadStatusText: String = ""
    public var embeddingGemmaStatus: EmbeddingGemmaStatus = CortexModelDownloader.checkEmbeddingGemmaStatus()

    public func refreshEmbeddingModelStatus() {
        embeddingGemmaStatus = CortexModelDownloader.checkEmbeddingGemmaStatus()
    }

    public func startEmbeddingModelDownload() {
        guard !isDownloadingEmbeddingModel else { return }
        isDownloadingEmbeddingModel = true
        embeddingDownloadProgress = 0.02
        embeddingDownloadStatusText = "Initialisiere Download ..."
        Task {
            do {
                try await CortexModelDownloader.downloadEmbeddingGemma { [weak self] prog, status in
                    Task { @MainActor in
                        self?.embeddingDownloadProgress = prog
                        self?.embeddingDownloadStatusText = status
                    }
                }
                refreshEmbeddingModelStatus()
                isDownloadingEmbeddingModel = false
                showToast("EmbeddingGemma 2 erfolgreich eingerichtet!")
            } catch {
                isDownloadingEmbeddingModel = false
                embeddingDownloadStatusText = "Fehler: \(error.localizedDescription)"
                showToast("Download fehlgeschlagen")
            }
        }
    }

    public func completeOnboarding() {
        settings.hasCompletedOnboarding = true
        showSetupAssistant = false
    }

    private var idleTimer: Timer?
    private var assetPruneTimer: Timer?
    @ObservationIgnored private var folderWatcher: FolderWatcher?

    public init() {
        // Network answers (AI servers, model lists, pings) are never needed again: keep them in memory only instead of
        // the default on-disk HTTP cache in ~/Library/Caches, and drop what earlier versions stored there.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let bundleID = Bundle.main.bundleIdentifier {
            let dir = caches.appendingPathComponent(bundleID, isDirectory: true)
            for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        URLCache.shared = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0)
        let initial = CortexSettingsManager.shared.settings
        let svc = try! CortexService(defaultEngine: initial.defaultEngine)
        self.service = svc
        self.importer = ImportQueue(service: svc)
        let sockDaemon = CortexSocketDaemon(service: svc)
        self.daemon = sockDaemon
        Self.shared = self
        if initial.shouldShowOnboarding {
            self.showSetupAssistant = true
        }

        sockDaemon.onActivityLogged = { [weak self] in
            Task { @MainActor in
                self?.refreshAgentEvents()
                await self?.syncEngineAndMemory()
            }
        }

        importer.engine = { [weak self] in self?.activeEngine ?? initial.defaultEngine }
        importer.onDocumentFinished = { [weak self] in self?.refreshLibrary() }
        importer.onQueueFinished = { [weak self] indexed, failed in
            guard let self else { return }
            if failed > 0 {
                self.showToast("Import beendet – \(failed) Fehler")
            } else if indexed > 0 {
                self.showToast("\(indexed) Dokument(e) indiziert")
            }
            Task { await self.updateMemoryStats() }
        }

        _ = try? svc.db.deduplicateDocuments()
        refreshLibrary()
        if initial.agentAccessEnabled { startDaemon() }
        Task { await service.updateUIScope(currentScopeFilter, enforceForAgents: initial.shareSelectionWithAgents) }

        Task {
            if ProcessInfo.processInfo.environment["CORTEX_KEEP_PAGE_PNGS"] != "1" {
                let pagesDir = CortexPaths.pagesAssetsDir
                if let items = try? FileManager.default.contentsOfDirectory(at: pagesDir, includingPropertiesForKeys: nil) {
                    for url in items { try? FileManager.default.removeItem(at: url) }
                }
            }
            try? await svc.warmUpTextDaemon()
            await syncEngineAndMemory()
            await pingLLMEndpoint()
            await pingAllProfiles()
        }

        DispatchQueue.main.async { [weak self] in
            if let self { DebugAutomation.startIfRequested(vm: self) }
        }
        // Catch up with changes made while the app was closed (incremental, skipped if nothing changed).
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.syncFolders() }

        // Bounded crop/page-image cache: shortly after launch, then every 6 hours (files are regenerated on demand).
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { AssetCache.prune() }
        assetPruneTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { AssetCache.prune() }
        }

        idleTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.service.checkAndPerformIdleCleanup()
                await self.syncEngineAndMemory()
            }
        }
    }

    // MARK: - System settings side effects

    private func applySystemSettings(old: CortexSettings) {
        if settings.searchContentMode != old.searchContentMode || settings.minFigureScore != old.minFigureScore,
           !lastSubmittedQuery.isEmpty {
            performSearch(query: lastSubmittedQuery)
        }
        if settings.showDockIcon != old.showDockIcon {
            NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
            if settings.showDockIcon { NSApp.activate(ignoringOtherApps: true) }
        }
        if settings.accentChoice != old.accentChoice {
            Theme.accentChoice = settings.accentChoice
        }
        if settings.interfaceLanguage != old.interfaceLanguage {
            Self.applyInterfaceLanguage(settings.interfaceLanguage)
        }
        if settings.appearanceMode != old.appearanceMode {
            Self.applyAppearance(settings.appearanceMode)
        }
        if settings.agentAccessEnabled != old.agentAccessEnabled {
            settings.agentAccessEnabled ? startDaemon() : stopDaemon()
        }
        if settings.autoWatchFolders != old.autoWatchFolders {
            updateFolderWatching()
            if settings.autoWatchFolders { syncFolders() }
        }
        if settings.shareSelectionWithAgents != old.shareSelectionWithAgents {
            pushScopeToService()
        }
        if settings.defaultEngine != old.defaultEngine, settings.defaultEngine != activeEngine {
            switchEngine(to: settings.defaultEngine)
        }
        if settings.llmEndpointURL != old.llmEndpointURL || settings.llmApiKey != old.llmApiKey {
            Task { await pingLLMEndpoint() }
        }
        if settings.neuralReranker != old.neuralReranker {
            Task { await service.unloadNeuralReranker() }
        }
        let searchRelevant = settings.enableReranker != old.enableReranker
            || settings.neuralReranker != old.neuralReranker
            || settings.maxDisplayedResults != old.maxDisplayedResults
            || settings.defaultContextRadius != old.defaultContextRadius
            || settings.embeddingDimension != old.embeddingDimension
            || settings.hybridDenseWeight != old.hybridDenseWeight
            || settings.minCosineScore != old.minCosineScore
        if searchRelevant && !lastSubmittedQuery.isEmpty {
            performSearch(query: lastSubmittedQuery)
        }
    }

    /// macOS picks the app's localisation at launch from `AppleLanguages`; the change applies after a restart.
    static func applyInterfaceLanguage(_ lang: InterfaceLanguage) {
        switch lang {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .german: UserDefaults.standard.set(["de"], forKey: "AppleLanguages")
        case .english: UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
    }

    /// Starts a fresh instance of the app bundle and quits this one.
    public func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        shutdownAndResetOnExit()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Language the running process actually uses for its interface.
    public var activeInterfaceLanguageCode: String { Bundle.main.preferredLocalizations.first ?? "de" }

    static func applyAppearance(_ mode: AppAppearanceMode) {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Library

    public func refreshLibrary() {
        do {
            modules = try service.db.listModules()
            collections = try service.db.listCollections()
            watchedFolders = try service.db.listWatchedFolders()
            documents = try service.db.listDocuments()
            refreshAgentEvents()
            updateFolderWatching()
        } catch {
            errorBanner = "Datenbank-Fehler: \(error)"
        }
    }

    // MARK: - Folder watching (FSEvents, incremental)

    private func updateFolderWatching() {
        guard settings.autoWatchFolders else {
            folderWatcher?.stop()
            return
        }
        if folderWatcher == nil {
            folderWatcher = FolderWatcher { [weak self] roots in
                Task { @MainActor in self?.syncFolders(paths: roots) }
            }
        }
        folderWatcher?.watch(watchedFolders.map(\.path))
    }

    /// Queues new or modified PDFs of watched folders (new path, or file changed after it was indexed).
    /// Unchanged files are not even hashed, so a check of large folders is cheap.
    public func syncFolders(paths: [String]? = nil) {
        guard settings.autoWatchFolders else { return }
        let targets = watchedFolders.filter { paths == nil || paths!.contains($0.path) }
        guard !targets.isEmpty else { return }
        let power = PowerManager.shared.canRunIndexing(settings: settings)
        guard power.canRun else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in self?.syncFolders(paths: targets.map(\.path)) }
            return
        }
        let known = Dictionary(documents.map { ($0.filePath, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [(url: URL, topicID: String, folderID: String?)] = []
        for folder in targets where FileManager.default.fileExists(atPath: folder.path) {
            for pdf in ImportPlan.collectPDFs(in: URL(fileURLWithPath: folder.path)) {
                if let doc = known[pdf.path] {
                    let modified = (try? pdf.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    guard modified > (doc.indexedAt ?? 0) else { continue }
                }
                items.append((pdf, folder.collectionID, folder.id))
            }
        }
        if !items.isEmpty { importer.enqueue(items) }
    }

    public func refreshAgentEvents() {
        agentEvents = (try? service.db.listAgentEvents(limit: 100)) ?? []
    }

    public func clearAgentEvents() {
        try? service.db.run("DELETE FROM agent_events")
        refreshAgentEvents()
    }

    public func document(id: String?) -> LibraryDocument? {
        guard let id else { return nil }
        return documents.first(where: { $0.id == id })
    }

    public func collectionName(_ id: String) -> String {
        collections.first(where: { $0.id == id })?.name ?? ""
    }

    // MARK: - Scope (checkbox multi-selection, OR-combined)

    public var hasSelection: Bool {
        !(selectedModuleIDs.isEmpty && selectedCollectionIDs.isEmpty && selectedFolderIDs.isEmpty && selectedDocumentIDs.isEmpty
          && selectedSubfolderPaths.isEmpty)
    }

    public var currentScopeFilter: ScopeFilter {
        let mods = modules.filter { selectedModuleIDs.contains($0.id) }.map(\.name)
        let cols = collections.filter { selectedCollectionIDs.contains($0.id) }.map(\.name)
        let fols = watchedFolders.filter { selectedFolderIDs.contains($0.id) }.map(\.name)
        let docs = documents.filter { selectedDocumentIDs.contains($0.id) }.map(\.title)
        return ScopeFilter(
            moduleIDs: selectedModuleIDs.isEmpty ? nil : Array(selectedModuleIDs),
            moduleNames: mods.isEmpty ? nil : mods,
            collectionIDs: selectedCollectionIDs.isEmpty ? nil : Array(selectedCollectionIDs),
            collectionNames: cols.isEmpty ? nil : cols,
            folderIDs: selectedFolderIDs.isEmpty ? nil : Array(selectedFolderIDs),
            folderNames: fols.isEmpty ? nil : fols,
            documentIDs: selectedDocumentIDs.isEmpty ? nil : Array(selectedDocumentIDs),
            documentTitles: docs.isEmpty ? nil : docs,
            pathPrefixes: selectedSubfolderPaths.isEmpty ? nil : Array(selectedSubfolderPaths),
            pageStart: pageStart,
            pageEnd: pageEnd,
            matchAnyLevel: true
        )
    }

    /// Union of all documents covered by the checkbox selection.
    public var scopedDocuments: [LibraryDocument] {
        guard hasSelection else { return documents }
        let colsOfMods = Set(collections.filter { selectedModuleIDs.contains($0.moduleID) }.map(\.id))
        return documents.filter { d in
            selectedDocumentIDs.contains(d.id)
                || selectedCollectionIDs.contains(d.collectionID)
                || colsOfMods.contains(d.collectionID)
                || (d.folderID.map { selectedFolderIDs.contains($0) } ?? false)
                || selectedSubfolderPaths.contains { d.filePath.hasPrefix($0 + "/") }
        }
    }

    public var scopeSummary: String {
        let range: String = {
            switch (pageStart, pageEnd) {
            case let (a?, b?): return " · S. \(a)–\(b)"
            case let (a?, nil): return " · ab S. \(a)"
            case let (nil, b?): return " · bis S. \(b)"
            default: return ""
            }
        }()
        guard hasSelection else { return "Ganze Bibliothek" + range }
        var parts: [String] = []
        parts += modules.filter { selectedModuleIDs.contains($0.id) }.map(\.name)
        parts += collections.filter { selectedCollectionIDs.contains($0.id) }.map(\.name)
        parts += watchedFolders.filter { selectedFolderIDs.contains($0.id) }.map(\.name)
        parts += selectedSubfolderPaths.sorted().map { ImportSuggester.displayName(forFolder: ($0 as NSString).lastPathComponent) }
        parts += documents.filter { selectedDocumentIDs.contains($0.id) }.map { CortexTextSanitizer.displayTitle($0.title) }
        return parts.joined(separator: " · ") + range
    }

    private func pushScopeToService() {
        let scope = currentScopeFilter
        let share = settings.shareSelectionWithAgents
        Task { await service.updateUIScope(hasSelection ? scope : ScopeFilter(), enforceForAgents: share) }
    }

    private func scopeChanged() {
        pushScopeToService()
        if !lastSubmittedQuery.isEmpty {
            performSearch(query: lastSubmittedQuery)
        }
    }

    private func toggle(_ set: inout Set<String>, _ id: String) {
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
    }

    public func toggleModule(_ id: String) { toggle(&selectedModuleIDs, id); scopeChanged() }
    public func toggleCollection(_ id: String) { toggle(&selectedCollectionIDs, id); scopeChanged() }
    public func toggleFolder(_ id: String) { toggle(&selectedFolderIDs, id); scopeChanged() }
    public func toggleDocument(_ id: String) { toggle(&selectedDocumentIDs, id); scopeChanged() }
    public func toggleSubfolder(_ path: String) { toggle(&selectedSubfolderPaths, path); scopeChanged() }

    public func selectOnly(moduleID: String? = nil, collectionID: String? = nil, folderID: String? = nil,
                           documentID: String? = nil, subfolderPath: String? = nil) {
        selectedModuleIDs = moduleID.map { [$0] } ?? []
        selectedCollectionIDs = collectionID.map { [$0] } ?? []
        selectedFolderIDs = folderID.map { [$0] } ?? []
        selectedDocumentIDs = documentID.map { [$0] } ?? []
        selectedSubfolderPaths = subfolderPath.map { [$0] } ?? []
        scopeChanged()
    }

    public func clearSelection() { selectOnly() }

    // MARK: - Search

    public func submitSearch() {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            lastSubmittedQuery = ""
            searchResults = []
            synthesisTask?.cancel()
            synthesisState = AISynthesisStreamState()
            return
        }
        performSearch(query: q)
    }

    public func performSearch(query q: String) {
        lastSubmitAt = Date()
        if q != lastSubmittedQuery || !previousTurns.isEmpty { endConversation() }
        lastSubmittedQuery = q
        let scope = currentScopeFilter
        let radius = settings.defaultContextRadius
        let topK = max(1, settings.maxDisplayedResults)
        let engine = activeEngine
        isSearching = true
        searchTask?.cancel()
        searchTask = Task {
            do {
                let resp = try await service.search(
                    query: q, scope: hasSelection ? scope : ScopeFilter(pageStart: pageStart, pageEnd: pageEnd, useUISelection: false),
                    contextChunks: radius, includeFigures: true, topK: topK, source: "ui", engineOverride: engine,
                    content: settings.searchContentMode
                )
                guard !Task.isCancelled else { return }
                ensureTextProfiles(for: resp.results.map(\.documentID))
                withAnimation(Theme.spring) {
                    searchResults = resp.results
                    lastSearchLatencyMs = resp.latencyMs
                    isSearching = false
                }
                if settings.enableAISynthesis && settings.aiSynthesisTrigger == .automatic && !resp.results.isEmpty {
                    triggerAISynthesis()
                } else {
                    synthesisTask?.cancel()
                    synthesisState = AISynthesisStreamState()
                }
                refreshAgentEvents()
                await updateMemoryStats()
            } catch {
                isSearching = false
                errorBanner = "Suche fehlgeschlagen: \(error)"
            }
        }
    }

    // MARK: - AI answer

    public func setAIEnabled(_ on: Bool) {
        guard settings.enableAISynthesis != on else { return }
        settings.enableAISynthesis = on
        if on, !searchResults.isEmpty {
            triggerAISynthesis()
        } else if !on {
            cancelAISynthesis()
            synthesisState = AISynthesisStreamState()
        }
    }

    public func setThinking(_ on: Bool) {
        settings.enableThinking = on
        if settings.enableAISynthesis && !searchResults.isEmpty { triggerAISynthesis() }
    }

    /// Generates (or regenerates) the answer for the current round.
    public func triggerAISynthesis() {
        synthesisTask?.cancel()
        pendingStreamState = nil
        if previousTurns.isEmpty {
            let q = lastSubmittedQuery
            guard !q.isEmpty, !searchResults.isEmpty else { return }
            currentQuestion = q
            conversationSources = Array(searchResults.prefix(max(1, settings.maxChunksForLLM)))
            currentAddedSources = nil
        }
        streamCurrentRound()
    }

    private func streamCurrentRound() {
        lastAIRequestAt = Date()
        let question = currentQuestion
        let sources = conversationSources
        let history = previousTurns.map {
            ConversationExchange(
                question: $0.question,
                answer: $0.state.answerText,
                fullPrompt: $0.fullPrompt,
                promptImages: $0.state.promptImages,
                rawAnswer: $0.state.rawText.isEmpty ? nil : $0.state.rawText
            )
        }
        let newSourcesStartIndex = previousTurns.isEmpty ? 0 : max(0, conversationSources.count - (currentAddedSources ?? 0))
        let primary = settings
        let primaryName = settings.activeLLMProfile?.name
        let fallback = settings.fallbackLLMProfile
        synthesisTask = Task { [weak self] in
            let last = StreamBox()
            await CortexLLMService.shared.streamRAGSynthesis(
                query: question, chunks: sources, settings: primary, history: history,
                newSourcesStartIndex: newSourcesStartIndex, useAllChunks: true
            ) { newState in
                last.set(newState)
                var tagged = newState
                if let primaryName, !newState.modelUsed.isEmpty { tagged.modelUsed += " · \(primaryName)" }
                Task { @MainActor in
                    guard let self, !Task.isCancelled else { return }
                    self.applyStreamedState(tagged)
                }
            }
            // Fallback: the active server failed before producing any text → answer once via the fallback profile.
            guard !Task.isCancelled, let fallback, let final = last.get(),
                  final.errorMessage != nil, final.answerText.isEmpty else { return }
            let fallbackSettings = primary.using(profile: fallback)
            await CortexLLMService.shared.streamRAGSynthesis(
                query: question, chunks: sources, settings: fallbackSettings, history: history,
                newSourcesStartIndex: newSourcesStartIndex, useAllChunks: true
            ) { newState in
                var tagged = newState
                tagged.modelUsed = "\(fallbackSettings.llmSelectedModel) · Fallback: \(fallback.name)"
                Task { @MainActor in
                    guard let self, !Task.isCancelled else { return }
                    self.applyStreamedState(tagged)
                }
            }
        }
    }

    /// How a follow-up is turned into library searches (decided by rules, not by an extra model call).
    public enum FollowUpStrategy: Equatable, Sendable {
        /// Pure instruction ("kürzer", "als Tabelle"): answer from the existing sources.
        case noSearch
        /// Elliptic add-on ("und bei einer Netzwerkpartition?"): searched together with the first question.
        case appended
        /// Self-contained question: searched on its own and combined with the first question; hits are merged.
        case standalone

        var note: String {
            switch self {
            case .noSearch: return "aus bisherigen Quellen"
            case .appended: return "ergänzt die erste Frage"
            case .standalone: return "eigene Suche"
            }
        }
    }

    /// Rules: instruction words only → no search; short or elliptic ("und …", "bei …", ≤ 4 content words) → appended;
    /// a full sentence (≥ 5 content words or ≥ 45 characters with its own question structure) → standalone.
    func followUpStrategy(for text: String) -> FollowUpStrategy {
        Self.classifyFollowUp(text, hasNewTerms: !newTerms(in: text).isEmpty, mode: followUpSearchMode,
                              rules: LanguageRules.for(settings.contentLanguage))
    }

    nonisolated static func classifyFollowUp(_ text: String, hasNewTerms: Bool, mode: FollowUpSearchMode,
                                             rules: LanguageRules = .for(.mixed)) -> FollowUpStrategy {
        if mode == .never { return .noSearch }
        if mode == .auto && !hasNewTerms { return .noSearch }
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        let contentWords = lower.components(separatedBy: CharacterSet.letters.inverted).filter { $0.count >= 4 }
        let elliptic = rules.ellipticStarts.contains { lower.hasPrefix($0) }
        let questionWord = rules.questionStarts.contains { lower.hasPrefix($0) }
        if elliptic && contentWords.count <= 6 { return .appended }
        if contentWords.count >= 5 || (lower.count >= 45 && questionWord) { return .standalone }
        return .appended
    }

    /// Asks a follow-up in the answer card. New hits get the next free citation numbers so earlier
    /// citations stay valid; at most 12 sources per conversation.
    public func submitFollowUp(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !synthesisState.isGenerating, !synthesisState.answerText.isEmpty else { return }
        synthesisTask?.cancel()
        pendingStreamState = nil
        previousTurns.append(ConversationTurn(
            question: currentQuestion,
            state: synthesisState,
            fullPrompt: synthesisState.fullPrompt,
            addedSources: currentAddedSources,
            strategyNote: currentStrategyNote
        ))
        currentQuestion = text
        currentAddedSources = 0
        let strategy = followUpStrategy(for: text)
        currentStrategyNote = strategy.note
        synthesisState = AISynthesisStreamState(isGenerating: true, modelUsed: settings.llmSelectedModel)

        guard strategy != .noSearch else {
            streamCurrentRound()
            return
        }

        isFollowUpSearching = true
        let firstQuestion = previousTurns.first?.question ?? lastSubmittedQuery
        var queries = ["\(firstQuestion) \(text)"]
        if strategy == .standalone { queries.insert(text, at: 0) }
        let scope = hasSelection ? currentScopeFilter : ScopeFilter(pageStart: pageStart, pageEnd: pageEnd, useUISelection: false)
        let engine = activeEngine
        let maxNew = strategy == .standalone ? 4 : 3
        Task {
            defer { isFollowUpSearching = false }
            // Merge the hit lists of all queries round-robin, so the standalone search and the combined one both count.
            var lists: [[SearchResultItem]] = []
            for q in queries {
                if let resp = try? await service.search(
                    query: q, scope: scope, contextChunks: settings.defaultContextRadius,
                    includeFigures: true, topK: 8, source: "ui", engineOverride: engine,
                    content: settings.searchContentMode
                ) {
                    let best = resp.results.first?.score ?? 0
                    lists.append(resp.results.filter { $0.score >= best * 0.85 })
                }
            }
            var merged: [SearchResultItem] = []
            for i in 0..<(lists.map(\.count).max() ?? 0) {
                for list in lists where i < list.count { merged.append(list[i]) }
            }
            var added: [SearchResultItem] = []
            let room = max(0, 12 - conversationSources.count)
            for r in merged where added.count < min(maxNew, room) {
                let known = (conversationSources + added).contains {
                    $0.chunkID == r.chunkID || ($0.documentID == r.documentID && $0.pageNumber == r.pageNumber)
                }
                if !known { added.append(r) }
            }
            conversationSources += added
            currentAddedSources = added.count
            ensureTextProfiles(for: added.map(\.documentID))
            guard !Task.isCancelled else { return }
            streamCurrentRound()
        }
    }

    /// Words of a follow-up that the conversation has not covered yet (inflection-tolerant prefix match).
    func newTerms(in followUp: String) -> [String] {
        let instruction = LanguageRules.current().followUpInstructionWords
        let corpus = ([lastSubmittedQuery] + previousTurns.flatMap { [$0.question, $0.state.answerText] }
            + conversationSources.map { $0.matchedContent + " " + $0.breadcrumb }).joined(separator: " ").lowercased()
        let words = followUp.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !instruction.contains($0) }
        // Compare almost the whole word: inflection-tolerant ("Knoten" ~ "Knotens"), but compounds such as
        // "Netzwerkpartition" are not mistaken for "Netzwerkprotokoll".
        return Self.unknownTerms(words, in: corpus)
    }

    nonisolated static func unknownTerms(_ words: [String], in corpus: String) -> [String] {
        words.filter { !corpus.contains(String($0.prefix(max(6, $0.count - 3)))) }
    }

    public func endConversation() {
        guard !previousTurns.isEmpty || !conversationSources.isEmpty else { return }
        synthesisTask?.cancel()
        pendingStreamState = nil
        previousTurns = []
        conversationSources = []
        currentAddedSources = nil
        currentStrategyNote = nil
    }

    /// Returns to the first answer without follow-ups.
    public func resetToFirstAnswer() {
        guard let first = previousTurns.first else { return }
        synthesisTask?.cancel()
        pendingStreamState = nil
        let firstCount = max(1, settings.maxChunksForLLM)
        conversationSources = Array(conversationSources.prefix(firstCount))
        currentQuestion = first.question
        synthesisState = first.state
        currentAddedSources = nil
        previousTurns = []
    }

    private var lastStreamUIUpdate = Date.distantPast
    private var pendingStreamState: AISynthesisStreamState?

    /// Coalesces token-level updates to ~12 per second: re-rendering the Markdown answer for every token
    /// (≈100/s) cost up to 45 % CPU while streaming. Start and final states are applied immediately.
    private func applyStreamedState(_ newState: AISynthesisStreamState) {
        let isBoundary = !newState.isGenerating || synthesisState.isGenerating == false
        if isBoundary || Date().timeIntervalSince(lastStreamUIUpdate) >= 0.08 {
            pendingStreamState = nil
            lastStreamUIUpdate = Date()
            synthesisState = newState
            return
        }
        let firstPending = pendingStreamState == nil
        pendingStreamState = newState
        guard firstPending else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, let pending = self.pendingStreamState else { return }
            self.pendingStreamState = nil
            self.lastStreamUIUpdate = Date()
            self.synthesisState = pending
        }
    }

    public func cancelAISynthesis() {
        synthesisTask?.cancel()
        pendingStreamState = nil
        synthesisState.isGenerating = false
    }

    public func pingLLMEndpoint() async {
        isPingingLLM = true
        let s = settings
        let res = await CortexLLMService.shared.pingAndDiscoverModels(endpointURL: s.llmEndpointURL, apiKey: s.llmApiKey)
        llmPingResult = res
        isPingingLLM = false
        let current = res.models.first { $0.id == settings.llmSelectedModel }
        if res.ok, !res.models.isEmpty, current == nil || current?.isChatModel == false,
           let preferred = DiscoveredLLMModel.preferredChatModel(in: res.models) {
            settings.llmSelectedModel = preferred.id
        }
    }

    // MARK: - Server profiles

    public func pingProfile(_ profile: LLMServerProfile) async {
        pingingProfiles.insert(profile.id)
        let res = await CortexLLMService.shared.pingAndDiscoverModels(endpointURL: profile.endpointURL, apiKey: profile.apiKey)
        profilePings[profile.id] = res
        pingingProfiles.remove(profile.id)
    }

    public func pingAllProfiles() async {
        await withTaskGroup(of: Void.self) { group in
            for p in settings.llmProfiles {
                group.addTask { await self.pingProfile(p) }
            }
        }
    }

    public func activateProfile(_ id: String) {
        guard settings.activeLLMProfileID != id else { return }
        settings.activeLLMProfileID = id
        if let p = settings.activeLLMProfile { showToast("KI-Server: \(p.name)") }
        if settings.enableAISynthesis && !searchResults.isEmpty && !synthesisState.isGenerating { triggerAISynthesis() }
    }

    public func addProfile(remote: Bool) {
        var p = remote
            ? LLMServerProfile.defaultRemote(model: settings.llmSelectedModel)
            : LLMServerProfile.defaultLocal(model: settings.llmSelectedModel)
        if settings.llmProfiles.contains(where: { $0.id == p.id }) {
            p.id = UUID().uuidString
            p.name = remote ? "Remote \(settings.llmProfiles.filter(\.isRemote).count + 1)" : "Lokal \(settings.llmProfiles.filter { !$0.isRemote }.count + 1)"
        }
        settings.llmProfiles.append(p)
    }

    public func deleteProfile(_ id: String) {
        guard settings.llmProfiles.count > 1 else { return }
        settings.llmProfiles.removeAll { $0.id == id }
        if settings.activeLLMProfileID == id { settings.activeLLMProfileID = settings.llmProfiles[0].id }
        if settings.fallbackLLMProfileID == id { settings.fallbackLLMProfileID = "" }
        profilePings[id] = nil
    }

    public func testLLMGeneration() async {
        isTestingLLM = true
        llmTestMessage = nil
        let s = settings
        let res = await CortexLLMService.shared.testGeneration(endpointURL: s.llmEndpointURL, apiKey: s.llmApiKey, model: s.llmSelectedModel)
        isTestingLLM = false
        llmTestMessage = res.ok ? "Antwort in \(Int(res.latencyMs)) ms: „\(res.responseText)“" : res.responseText
    }

    public func selectModel(_ id: String) {
        settings.llmSelectedModel = id
        Task {
            let s = settings
            _ = await CortexLLMService.shared.loadModelInServer(modelID: id, endpointURL: s.llmEndpointURL, apiKey: s.llmApiKey)
            await pingLLMEndpoint()
            if settings.enableAISynthesis && !searchResults.isEmpty { triggerAISynthesis() }
        }
    }

    public func unloadActiveModel() {
        let target = settings.llmSelectedModel
        guard !target.isEmpty else { return }
        Task {
            let s = settings
            let res = await CortexLLMService.shared.unloadModelInServer(modelID: target, endpointURL: s.llmEndpointURL, apiKey: s.llmApiKey)
            await pingLLMEndpoint()
            if res.ok { showToast("„\(target)“ aus dem Speicher entladen") } else { showToast(LocalizedStringKey(res.message)) }
        }
    }

    public func jumpToCitation(_ index: Int) {
        if index >= 1, index <= conversationSources.count {
            let src = conversationSources[index - 1]
            if searchResults.contains(where: { $0.chunkID == src.chunkID }) { highlightedResultID = src.chunkID }
            openReader(result: src)
            return
        }
        guard let cit = synthesisState.citations.first(where: { $0.index == index }) else { return }
        highlightedResultID = cit.chunkID
        // The full hit knows whether it is a figure (framed in the reader) and has the whole passage, not a snippet.
        if let hit = searchResults.first(where: { $0.chunkID == cit.chunkID }) {
            openReader(result: hit)
            return
        }
        openReader(documentID: cit.documentID, path: cit.documentPath, title: cit.documentTitle,
                   page: cit.pageNumber, chunkText: cit.snippet)
    }

    // MARK: - Reader

    public func openReader(documentID: String?, path: String, title: String, page: Int, chunkText: String? = nil) {
        readerTarget = ReaderTarget(
            documentID: documentID, documentPath: path, title: CortexTextSanitizer.displayTitle(title),
            pageNumber: max(1, page), chunkText: chunkText
        )
        openWindowAction?(id: "reader")
    }

    public func openReader(result: SearchResultItem) {
        if let fig = result.figure {
            openReader(figure: fig)
            return
        }
        openReader(documentID: result.documentID, path: result.documentPath, title: result.documentTitle,
                   page: result.pageNumber, chunkText: result.matchedContent)
    }

    public func openReader(document: LibraryDocument, page: Int = 1) {
        openReader(documentID: document.id, path: document.filePath, title: document.title, page: page)
    }

    public func openReader(figure: FigureResultItem) {
        readerTarget = ReaderTarget(
            documentID: figure.documentID, documentPath: figure.documentPath,
            title: CortexTextSanitizer.displayTitle(figure.documentTitle), pageNumber: max(1, figure.pageNumber),
            chunkText: nil, figureBBox: figure.bbox
        )
        openWindowAction?(id: "reader")
    }

    // MARK: - Engine, memory & daemon

    public func syncEngineAndMemory() async {
        let kind = await service.activeEngineKind
        if activeEngine != kind { activeEngine = kind }
        await updateMemoryStats()
    }

    public func updateMemoryStats() async {
        let bytes = await service.currentBackend.currentMemoryBytes()
        memoryUsageMB = (Double(bytes) / 1_048_576 * 10).rounded() / 10
    }

    public func setAgentAccess(_ on: Bool) {
        guard settings.agentAccessEnabled != on else { return }
        settings.agentAccessEnabled = on
    }

    private func startDaemon() {
        do {
            try daemon?.start()
            isDaemonActive = daemon?.isRunning ?? false
        } catch {
            errorBanner = "Agenten-Zugriff konnte nicht gestartet werden: \(error)"
            isDaemonActive = false
        }
    }

    private func stopDaemon() {
        daemon?.stop()
        isDaemonActive = false
    }

    public func switchEngine(to engine: EngineKind) {
        guard !isSwitchingEngine else { return }
        isSwitchingEngine = true
        activeEngine = engine
        if settings.defaultEngine != engine { settings.defaultEngine = engine }
        progressMessage = "Lade \(engine.displayName) …"
        Task {
            do {
                try await service.setEngine(engine)
                await syncEngineAndMemory()
                if !lastSubmittedQuery.isEmpty { performSearch(query: lastSubmittedQuery) }
            } catch {
                errorBanner = "Engine-Wechsel fehlgeschlagen: \(error)"
            }
            progressMessage = ""
            isSwitchingEngine = false
        }
    }

    public func shutdownAndResetOnExit() {
        synthesisTask?.cancel()
        searchTask?.cancel()
        stopDaemon()
        let svc = service
        let sema = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await svc.shutdown()
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 3.0)
    }

    public func showToast(_ text: LocalizedStringKey) {
        withAnimation(Theme.spring) { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            guard self?.toast == text else { return }
            withAnimation(Theme.spring) { self?.toast = nil }
        }
    }

    // MARK: - Library management

    @discardableResult
    public func createModule(name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = modules.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) { return existing.id }
        let mod = LibraryModule(name: trimmed, iconName: "square.stack.3d.up.fill")
        try? service.db.saveModule(mod)
        refreshLibrary()
        return mod.id
    }

    /// Creates a topic; `moduleID` empty = topic without area. Returns the existing topic of that name in the same area.
    @discardableResult
    public func createCollection(moduleID: String, name: String, description: String = "") -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = collections.first(where: { $0.moduleID == moduleID && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing.id
        }
        let col = LibraryCollection(moduleID: moduleID, name: trimmed, description: description)
        try? service.db.saveCollection(col)
        refreshLibrary()
        return col.id
    }

    public func renameModule(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var mod = modules.first(where: { $0.id == id }) else { return }
        mod.name = trimmed
        try? service.db.saveModule(mod)
        refreshLibrary()
    }

    public func renameCollection(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var col = collections.first(where: { $0.id == id }) else { return }
        col.name = trimmed
        try? service.db.saveCollection(col)
        refreshLibrary()
    }

    public func moveCollection(_ id: String, toModule moduleID: String) {
        guard var col = collections.first(where: { $0.id == id }) else { return }
        col.moduleID = moduleID
        try? service.db.saveCollection(col)
        refreshLibrary()
    }

    /// Re-files documents under another topic (no re-indexing).
    public func moveDocuments(_ ids: [String], toTopic topicID: String) {
        for doc in documents where ids.contains(doc.id) {
            // A document leaves its imported folder when it changes topic; the folder belongs to the old topic.
            let folder = watchedFolders.first { $0.id == doc.folderID && $0.collectionID == topicID }
            try? service.db.moveDocument(id: doc.id, collectionID: topicID, folderID: folder?.id)
        }
        refreshLibrary()
        scopeChanged()
    }

    public func deleteModule(_ mod: LibraryModule) {
        try? service.db.deleteModule(id: mod.id)
        selectedModuleIDs.remove(mod.id)
        refreshLibrary()
        scopeChanged()
    }

    public func deleteCollection(_ col: LibraryCollection) {
        try? service.db.deleteCollection(id: col.id)
        selectedCollectionIDs.remove(col.id)
        refreshLibrary()
        scopeChanged()
    }

    public func deleteFolder(_ folder: WatchedFolder) {
        try? service.db.deleteWatchedFolder(id: folder.id, deleteDocuments: true)
        selectedFolderIDs.remove(folder.id)
        selectedSubfolderPaths = selectedSubfolderPaths.filter { !$0.hasPrefix(folder.path + "/") }
        refreshLibrary()
        scopeChanged()
    }

    public func deleteDocument(_ doc: LibraryDocument) {
        deleteDocuments([doc])
    }

    public func deleteDocuments(_ docs: [LibraryDocument]) {
        guard !docs.isEmpty else { return }
        let docIDs = Set(docs.map(\.id))
        for doc in docs {
            try? service.db.deleteDocument(id: doc.id)
            selectedDocumentIDs.remove(doc.id)
        }
        if let current = libraryDocumentID, docIDs.contains(current) {
            libraryDocumentID = nil
        }
        searchResults.removeAll { docIDs.contains($0.documentID) }
        refreshLibrary()
        scopeChanged()
    }

    // MARK: - Import (files are linked, never copied)

    public struct PendingImport: Identifiable {
        public let id = UUID()
        let plan: ImportPlan
        var target: ImportTarget
    }

    public func importViaPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "PDFs oder Ordner importieren")
        panel.prompt = String(localized: "Weiter")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder] + DocumentFormats.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        beginImport(panel.urls)
    }

    /// Opens the target dialog with a suggested area/topic. `preferredModuleID` comes from a drop on an area header.
    public func beginImport(_ urls: [URL], preferredModuleID: String? = nil) {
        let plan = ImportPlan.make(from: urls)
        guard !plan.isEmpty else {
            showToast("Keine PDFs gefunden – nur PDFs und Ordner mit PDFs lassen sich importieren")
            return
        }
        var target = ImportSuggester.suggest(plan: plan, modules: modules, collections: collections)
        if let preferredModuleID {
            if case .existing(let tid) = target.topic, collections.first(where: { $0.id == tid })?.moduleID == preferredModuleID {
                // suggestion already lies in that area
            } else {
                target.area = preferredModuleID.isEmpty ? .none : .existing(preferredModuleID)
                if case .existing = target.topic {
                    let base = plan.folders.count == 1 ? plan.folders[0].url.lastPathComponent : (urls.first?.deletingLastPathComponent().lastPathComponent ?? "")
                    target.topic = .new(ImportSuggester.displayName(forFolder: base))
                }
            }
        }
        pendingImport = PendingImport(plan: plan, target: target)
    }

    /// Drop directly onto a topic row: no dialog.
    public func importDirect(_ urls: [URL], topicID: String) {
        let plan = ImportPlan.make(from: urls)
        guard !plan.isEmpty else {
            showToast("Keine PDFs gefunden – nur PDFs und Ordner mit PDFs lassen sich importieren")
            return
        }
        enqueue(plan, topicID: topicID)
    }

    func confirmImport(_ pending: PendingImport, target: ImportTarget) {
        pendingImport = nil
        let moduleID: String
        switch target.area {
        case .none: moduleID = ""
        case .existing(let id): moduleID = id
        case .new(let name): moduleID = createModule(name: name) ?? ""
        }
        let topicID: String?
        switch target.topic {
        case .existing(let id):
            topicID = id
            // Picking an existing topic in another area moves the topic there.
            if let col = collections.first(where: { $0.id == id }), col.moduleID != moduleID { moveCollection(id, toModule: moduleID) }
        case .new(let name): topicID = createCollection(moduleID: moduleID, name: name)
        }
        guard let topicID else { return }
        enqueue(pending.plan, topicID: topicID)
    }

    /// Registers imported folders (the tree below them is derived from the file paths) and queues all PDFs.
    private func enqueue(_ plan: ImportPlan, topicID: String) {
        var items: [(url: URL, topicID: String, folderID: String?)] = []
        for folder in plan.folders {
            let folderID = registerFolder(folder.url, topicID: topicID)
            items += folder.pdfs.map { ($0, topicID, folderID) }
        }
        for file in plan.looseFiles {
            // A single PDF from inside an already imported folder stays part of that folder.
            let root = watchedFolders.first { $0.collectionID == topicID && file.path.hasPrefix($0.path + "/") }
            items.append((file, topicID, root?.id))
        }
        importer.enqueue(items)
        refreshLibrary()
    }

    private func registerFolder(_ url: URL, topicID: String) -> String {
        let path = url.standardizedFileURL.path
        // Already covered by an imported parent folder of the same topic.
        if let parent = watchedFolders.first(where: { $0.collectionID == topicID && path.hasPrefix($0.path + "/") }) {
            return parent.id
        }
        var record = watchedFolders.first(where: { $0.path == path })
            ?? WatchedFolder(collectionID: topicID, name: url.lastPathComponent, path: path)
        record.collectionID = topicID
        record.lastIndexedAt = Date().timeIntervalSince1970
        try? service.db.saveWatchedFolder(record)
        // Imported subfolders are absorbed by the new parent; their documents are re-filed by the queue.
        for child in watchedFolders where child.path.hasPrefix(path + "/") {
            try? service.db.deleteWatchedFolder(id: child.id, deleteDocuments: false)
        }
        watchedFolders = (try? service.db.listWatchedFolders()) ?? watchedFolders
        return record.id
    }

    /// Re-reads captions of uncaptioned figures from the PDF text layer (no re-indexing).
    public func refreshFigureCaptions() {
        guard !isRefreshingCaptions else { return }
        isRefreshingCaptions = true
        Task {
            defer { isRefreshingCaptions = false; progressMessage = "" }
            do {
                let result = try await service.refreshFigureCaptions { msg in Task { @MainActor in self.progressMessage = msg } }
                showToast("\(result.updated) von \(result.checked) Bildunterschriften verbessert")
            } catch {
                errorBanner = "Bildunterschriften konnten nicht aktualisiert werden: \(error)"
            }
        }
    }

    public func reindex(_ docs: [LibraryDocument]) {
        guard !docs.isEmpty else { return }
        importer.enqueue(docs.map { (URL(fileURLWithPath: $0.filePath), $0.collectionID, $0.folderID) }, force: true)
    }

    public func deduplicateLibrary() {
        let removed = (try? service.db.deduplicateDocuments()) ?? 0
        refreshLibrary()
        scopeChanged()
        if removed > 0 {
            showToast("\(removed) doppelte(s) Dokument(e) bereinigt")
        } else {
            showToast("Keine doppelten Dokumente gefunden")
        }
    }

    // MARK: - Reranker models

    public func downloadReranker(_ model: NeuralRerankerModel) {
        guard rerankerDownloads[model] == nil else { return }
        rerankerDownloads[model] = 0
        rerankerDownloadTasks[model] = Task {
            do {
                try await NeuralRerankerDownloader.download(model) { p in
                    Task { @MainActor in if self.rerankerDownloads[model] != nil { self.rerankerDownloads[model] = p } }
                }
                rerankerDownloads[model] = nil
                showToast("\(model.displayName) geladen – unter „Nachsortierung“ auswählbar")
            } catch {
                rerankerDownloads[model] = nil
                if !(error is CancellationError) { errorBanner = "Download von \(model.displayName) fehlgeschlagen: \(error.localizedDescription)" }
            }
        }
    }

    public func cancelRerankerDownload(_ model: NeuralRerankerModel) {
        rerankerDownloadTasks[model]?.cancel()
        rerankerDownloads[model] = nil
    }

    public func deleteReranker(_ model: NeuralRerankerModel) {
        if settings.neuralReranker == model { settings.neuralReranker = .none }
        Task {
            await service.unloadNeuralReranker()
            NeuralRerankerDownloader.delete(model)
            showToast("\(model.displayName) gelöscht")
        }
    }

    public func runEngineBenchmark() {
        guard !isBenchmarking else { return }
        isBenchmarking = true
        progressMessage = "Benchmark läuft …"
        Task {
            let report = await service.runBenchmarkCleanly { msg in
                Task { @MainActor in self.progressMessage = msg }
            }
            benchmarkReport = report
            isBenchmarking = false
            progressMessage = ""
            await syncEngineAndMemory()
        }
    }
}
