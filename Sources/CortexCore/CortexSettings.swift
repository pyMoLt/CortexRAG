import Foundation

public enum AppAppearanceMode: String, Codable, CaseIterable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    public var displayName: String {
        switch self {
        case .system: return "Systemstandard (Automatisch)"
        case .light: return "Hell (Light Mode)"
        case .dark: return "Dunkel (Dark Mode)"
        }
    }
}

public enum IndexingThrottleMode: String, Codable, CaseIterable, Sendable {
    case turbo = "turbo"
    case balanced = "balanced"
    case ecoSilent = "ecoSilent"

    public var displayName: String {
        switch self {
        case .turbo: return "Turbo (alle Kerne & volle GPU)"
        case .balanced: return "Ausgewogen (GPU ca. ⅔ ausgelastet, leise)"
        case .ecoSilent: return "Minimal (GPU ca. ⅓ ausgelastet, Akku & Lüfter schonen)"
        }
    }

    public var shortName: String {
        switch self {
        case .turbo: return "Turbo"
        case .balanced: return "Ausgewogen"
        case .ecoSilent: return "Minimal"
        }
    }

    /// Pause after each GPU embedding step relative to its compute time (duty cycle): 0 = none, 0.5 ≈ GPU busy 2/3 of
    /// the time, 2.0 ≈ busy 1/3. A fixed delay alone cannot cap power: one image vector already takes ~0.2 s.
    public var dutyFactor: Double {
        switch self {
        case .turbo: return 0
        case .balanced: return 0.5
        case .ecoSilent: return 2.0
        }
    }

    public var delayNanoseconds: UInt64 {
        switch self {
        case .turbo: return 0
        case .balanced: return 50_000_000
        case .ecoSilent: return 180_000_000
        }
    }
}

public enum IdleMemoryMode: String, Codable, CaseIterable, Sendable {
    case standard = "standard"
    case aggressiveUnloadOnIdle = "aggressiveUnloadOnIdle"

    public var displayName: String {
        switch self {
        case .standard: return "Standard (Text-Encoder bleibt für ~10ms Antwortzeit geladen)"
        case .aggressiveUnloadOnIdle: return "Aggressiv (Nach Inaktivität komplett entladen — 0 Watt & minimaler RAM)"
        }
    }
}

/// How visual embeddings are generated when indexing pages with figures.
public enum ImageVectorMode: String, Codable, CaseIterable, Sendable {
    case adaptive = "adaptive"
    case fullPage = "fullPage"
    case cropsOnly = "cropsOnly"
    case disabled = "disabled"

    public var displayName: String {
        switch self {
        case .adaptive: return "Automatisch (Folie komplett · Skript-Bild mit Umfeld)"
        case .fullPage: return "Immer ganze Seite (1 Vektor pro Seite + Freistellungen)"
        case .cropsOnly: return "Einzelne Bildausschnitte (Crops mit Umfeld einbetten)"
        case .disabled: return "Aus (Nur Bildunterschriften / Text-Only)"
        }
    }
}

public enum EmbeddingTaskMode: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case searchResult = "search"
    case questionAnswering = "qa"
    case factChecking = "fact_checking"

    public var displayName: String {
        switch self {
        case .auto: return "Automatisch (QA bei Fragen/KI-Modus, sonst Search Result)"
        case .searchResult: return "Search Result ('task: search result | query: ...')"
        case .questionAnswering: return "Question Answering ('task: question answering | query: ...')"
        case .factChecking: return "Fact Checking ('task: fact checking | query: ...')"
        }
    }

    public func formatQuery(_ rawQuery: String, isAIMode: Bool = false) -> String {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("task:") {
            return trimmed
        }
        switch self {
        case .searchResult:
            return "task: search result | query: \(trimmed)"
        case .questionAnswering:
            return "task: question answering | query: \(trimmed)"
        case .factChecking:
            return "task: fact checking | query: \(trimmed)"
        case .auto:
            let lower = trimmed.lowercased()
            let rules = LanguageRules.current()
            let looksLikeQuestion = isAIMode || lower.contains("?")
                || rules.questionStarts.contains(where: { lower.hasPrefix($0) || lower.contains(" " + $0) })
                || rules.questionCues.contains(where: { lower.contains($0) })
            if looksLikeQuestion {
                return "task: question answering | query: \(trimmed)"
            } else {
                return "task: search result | query: \(trimmed)"
            }
        }
    }

    public static func formatDocument(title: String?, body: String) -> String {
        let cleanTitle = (title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "none"
        return "title: \(cleanTitle) | text: \(body)"
    }
}

public enum RerankerModelKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bgeRerankerV2M3 = "bge-reranker-v2-m3"
    case bgeRerankerV2Gemma = "bge-reranker-v2-gemma"
    case jinaRerankerV2Multilingual = "jina-reranker-v2-base-multilingual"
    case cortexNeuralHybrid = "cortex-neural-hybrid"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bgeRerankerV2M3:
            return "BGE Reranker v2-M3 (Multilingual Cross-Encoder)"
        case .bgeRerankerV2Gemma:
            return "BGE Reranker v2-Gemma (Gemma-2B Cross-Encoder)"
        case .jinaRerankerV2Multilingual:
            return "Jina Reranker v2 Base Multilingual"
        case .cortexNeuralHybrid:
            return "Cortex Neural-Lexical Cross-Scorer (Integriert, 0 MB RAM)"
        }
    }

    public var subtitle: String {
        switch self {
        case .bgeRerankerV2M3:
            return "Exzellent für Deutsch & Englisch (Informatik, Naturwissenschaften, Recht) • ~560 MB"
        case .bgeRerankerV2Gemma:
            return "Google Gemma-2B Architektur für tiefes semantisches Re-Ranking • ~1.1 GB"
        case .jinaRerankerV2Multilingual:
            return "Schneller multilingualer Cross-Encoder für lange Abschnitte • ~280 MB"
        case .cortexNeuralHybrid:
            return "Sofort einsatzbereit ohne Download (< 2 ms Latenz, 0 MB Zusatz-VRAM)"
        }
    }

    public var huggingFaceRepo: String? {
        switch self {
        case .bgeRerankerV2M3: return "BAAI/bge-reranker-v2-m3"
        case .bgeRerankerV2Gemma: return "BAAI/bge-reranker-v2-gemma"
        case .jinaRerankerV2Multilingual: return "jinaai/jina-reranker-v2-base-multilingual"
        case .cortexNeuralHybrid: return nil
        }
    }

    public var requiresDownload: Bool {
        self != .cortexNeuralHybrid
    }

    public var estimatedSizeMB: Int {
        switch self {
        case .bgeRerankerV2M3: return 565
        case .bgeRerankerV2Gemma: return 1120
        case .jinaRerankerV2Multilingual: return 285
        case .cortexNeuralHybrid: return 0
        }
    }
}

public enum LLMProviderPreset: String, Codable, CaseIterable, Sendable {
    case omlx = "omlx"
    case lmStudio = "lmstudio"
    case customOpenAI = "custom"

    public var displayName: String {
        switch self {
        case .omlx: return "oMLX Server (Lokal • Port 8000)"
        case .lmStudio: return "LM Studio (Lokal • Port 1234)"
        case .customOpenAI: return "Custom OpenAI-Kompatibler Endpunkt"
        }
    }

    public var defaultEndpointURL: String {
        switch self {
        case .omlx: return "http://127.0.0.1:8000/v1"
        case .lmStudio: return "http://127.0.0.1:1234/v1"
        case .customOpenAI: return "http://127.0.0.1:8000/v1"
        }
    }

    public var defaultApiKey: String {
        switch self {
        case .omlx: return "admin"
        case .lmStudio: return "lm-studio"
        case .customOpenAI: return ""
        }
    }
}

public enum AISynthesisTriggerMode: String, Codable, CaseIterable, Sendable {
    case automatic = "automatic"
    case onDemand = "onDemand"
    case disabled = "disabled"

    public var displayName: String {
        switch self {
        case .automatic: return "Automatisch bei jeder Suchanfrage (wenn KI-Modus aktiv)"
        case .onDemand: return "Nur auf Klick ('KI-Antwort generieren')"
        case .disabled: return "Deaktiviert (Nur Abschnitte anzeigen)"
        }
    }
}

public enum ChunkDisplayMode: String, Codable, CaseIterable, Sendable {
    case cleaned = "cleaned"
    case raw = "raw"

    public var displayName: String {
        switch self {
        case .cleaned: return "Bereinigter Lesetext (Silbentrennung & Umbrüche gefixt)"
        case .raw: return "Originaler Roh-Extrakt"
        }
    }
}

/// Language of the indexed material: steers the rule-based parts (question detection, stop words,
/// follow-up rules, caption patterns). Embeddings themselves are multilingual.
public enum ContentLanguage: String, Codable, CaseIterable, Sendable {
    case mixed = "mixed"
    case german = "de"
    case english = "en"

    public var displayName: String {
        switch self {
        case .mixed: return "Deutsch & Englisch gemischt"
        case .german: return "Überwiegend Deutsch"
        case .english: return "Überwiegend Englisch"
        }
    }
}

public enum AnswerLanguage: String, Codable, CaseIterable, Sendable {
    case auto = "auto"
    case german = "de"
    case english = "en"

    public var displayName: String {
        switch self {
        case .auto: return "Wie die Frage"
        case .german: return "Immer Deutsch"
        case .english: return "Immer Englisch"
        }
    }

    /// Instruction appended to the system prompt.
    public var instruction: String {
        switch self {
        case .auto: return "Antworte in der Sprache, in der die Frage gestellt wurde (Deutsch oder Englisch), auch wenn die Quellen eine andere Sprache haben. Fachbegriffe aus den Quellen darfst du beibehalten."
        case .german: return "Antworte immer auf Deutsch, auch wenn Frage oder Quellen englisch sind. Englische Fachbegriffe darfst du in Klammern ergänzen."
        case .english: return "Always answer in English, even if the question or the sources are in German. You may add German terms in parentheses."
        }
    }
}

/// User-selectable accent colour (the only visual customisation besides light/dark).
public enum AccentChoice: String, Codable, CaseIterable, Sendable {
    case indigo, blue, teal, green, orange, pink, purple, graphite

    public var displayName: String {
        switch self {
        case .indigo: return "Indigo"
        case .blue: return "Blau"
        case .teal: return "Petrol"
        case .green: return "Grün"
        case .orange: return "Orange"
        case .pink: return "Rosa"
        case .purple: return "Violett"
        case .graphite: return "Graphit"
        }
    }

    /// Primary and secondary RGB components (0…1) for gradients.
    public var rgb: (primary: (Double, Double, Double), secondary: (Double, Double, Double)) {
        switch self {
        case .indigo: return ((0.38, 0.40, 0.98), (0.20, 0.70, 0.95))
        case .blue: return ((0.10, 0.48, 0.98), (0.25, 0.78, 0.98))
        case .teal: return ((0.05, 0.60, 0.62), (0.20, 0.80, 0.70))
        case .green: return ((0.18, 0.66, 0.36), (0.55, 0.82, 0.30))
        case .orange: return ((0.96, 0.52, 0.12), (0.98, 0.74, 0.20))
        case .pink: return ((0.92, 0.30, 0.55), (0.98, 0.52, 0.48))
        case .purple: return ((0.60, 0.36, 0.94), (0.86, 0.42, 0.90))
        case .graphite: return ((0.40, 0.43, 0.48), (0.58, 0.62, 0.68))
        }
    }
}

/// Language of the app interface (labels, menus). Takes effect after a restart.
public enum InterfaceLanguage: String, Codable, CaseIterable, Sendable {
    case system, german = "de", english = "en"

    public var displayName: String {
        switch self {
        case .system: return "Systemsprache"
        case .german: return "Deutsch"
        case .english: return "English"
        }
    }
}

/// One OpenAI-compatible server (local oMLX/LM Studio or a remote machine, e.g. via Tailscale).
public struct LLMServerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var preset: LLMProviderPreset
    public var endpointURL: String
    public var apiKey: String
    public var model: String
    public var isRemote: Bool

    public init(id: String = UUID().uuidString, name: String, preset: LLMProviderPreset = .omlx, endpointURL: String,
                apiKey: String = "", model: String = "", isRemote: Bool = false) {
        self.id = id
        self.name = name
        self.preset = preset
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.model = model
        self.isRemote = isRemote
    }

    public static func defaultLocal(model: String = "") -> LLMServerProfile {
        LLMServerProfile(id: "local", name: "Lokal", preset: .omlx, endpointURL: "http://127.0.0.1:8000/v1", apiKey: "admin", model: model)
    }

    public static func defaultRemote(model: String = "Qwen3.6-35B-A3B-oQ6e-fp16-mtp") -> LLMServerProfile {
        LLMServerProfile(id: "remote", name: "Remote", preset: .omlx, endpointURL: "http://remote-host.local:8072/v1",
                         apiKey: "admin", model: model.isEmpty ? "Qwen3.6-35B-A3B-oQ6e-fp16-mtp" : model, isRemote: true)
    }
}

public struct CortexSettings: Codable, Equatable, Sendable {
    // 1. Erscheinungsbild & Systemintegration
    public var appearanceMode: AppAppearanceMode = .system
    public var accentChoice: AccentChoice = .indigo
    public var interfaceLanguage: InterfaceLanguage = .system
    public var showMenuBarItem: Bool = true
    public var showDockIcon: Bool = true
    public var autoOpenMainWindowOnLaunch: Bool = true

    // 2. Speicherpfade
    public var customStorageDirectory: String = ""

    // 3. Energie & Akku-Management (Smart Indexing wie DigUp)
    public var indexOnlyOnACPower: Bool = false
    public var pauseOnLowPowerMode: Bool = true
    public var throttlingMode: IndexingThrottleMode = .balanced
    public var batteryThrottlingMode: IndexingThrottleMode = .ecoSilent
    public var idleMemoryMode: IdleMemoryMode = .aggressiveUnloadOnIdle
    public var idleTimeoutMinutes: Int = 5

    // 4. Chunking & Textextraktion
    public var targetChunkSize: Int = 850
    public var chunkOverlap: Int = 150
    public var minChunkLength: Int = 60

    // 5. EmbeddingGemma 2 & Suche (MRL Dimensionen, Text-Only, Task-Prompts)
    public var defaultEngine: EngineKind = .llamaMetal
    public var embeddingDimension: MatryoshkaDimension = .d768
    /// How visual vectors are computed for figures during indexing: adaptive (full slide for lectures, contextual crop for scripts/books), full page, crops only, or disabled.
    public var imageVectorMode: ImageVectorMode = .adaptive {
        didSet {
            let enabled = (imageVectorMode != .disabled)
            if imageVectorsEnabled != enabled { imageVectorsEnabled = enabled }
        }
    }
    /// Image vectors for figures (vision tower of EmbeddingGemma). Synchronized with `imageVectorMode`.
    public var imageVectorsEnabled: Bool = true {
        didSet {
            if !imageVectorsEnabled && imageVectorMode != .disabled {
                imageVectorMode = .disabled
            } else if imageVectorsEnabled && imageVectorMode == .disabled {
                imageVectorMode = .adaptive
            }
        }
    }
    public var embeddingTaskMode: EmbeddingTaskMode = .auto
    /// What the ask view searches: text and figures together (default), only text, or only figures.
    public var searchContentMode: SearchContentMode = .all
    /// Figures need at least this similarity to appear among mixed results (text-to-image scores run lower).
    public var minFigureScore: Double = 0.25
    /// At most this many figures go to a vision-capable AI model with the question.
    public var maxImagesForLLM: Int = 4

    // 6. Ergebnis-Anzeige & Retrieval-Umfang
    public var chunkDisplayMode: ChunkDisplayMode = .cleaned
    public var retrievalTopKPool: Int = 20
    public var maxDisplayedResults: Int = 8
    public var defaultTopK: Int = 8
    public var defaultContextRadius: Int = 1
    public var showSurroundingContextExpanded: Bool = true
    public var hybridDenseWeight: Double = 0.65
    public var hybridBM25Weight: Double = 0.35
    public var minCosineScore: Double = 0.32

    // 7. Re-Ranker Einstellungen
    public var enableReranker: Bool = true
    public var selectedRerankerModel: RerankerModelKind = .bgeRerankerV2M3
    public var rerankCandidatePoolSize: Int = 18
    /// Optional cross-encoder model (off by default). When set and downloaded it replaces the lexical rule.
    public var neuralReranker: NeuralRerankerModel = .none

    // Sprache
    public var contentLanguage: ContentLanguage = .mixed
    public var answerLanguage: AnswerLanguage = .auto

    // 8. Lokale KI-Synthese (oMLX / LM Studio / OpenAI Endpoint)
    public var enableAISynthesis: Bool = true
    public var enableThinking: Bool = false
    public var aiSynthesisTrigger: AISynthesisTriggerMode = .automatic
    /// Server profiles for AI answers; the active one is mirrored into the llm* fields below.
    public var llmProfiles: [LLMServerProfile] = []
    public var activeLLMProfileID: String = ""
    /// Profile used once when the active server does not answer ("" = no fallback).
    public var fallbackLLMProfileID: String = ""
    public var llmProviderPreset: LLMProviderPreset = .omlx
    public var llmEndpointURL: String = "http://127.0.0.1:8000/v1"
    public var llmApiKey: String = "admin"
    public var llmSelectedModel: String = "Qwen3.5-4B-MLX-4bit"
    public var llmTemperature: Double = 0.2
    public var llmMaxTokens: Int = 1024
    public var maxChunksForLLM: Int = 5
    public var llmSystemPrompt: String = """
Du bist ein präziser wissenschaftlicher und technischer Fachassistent in CortexRAG. \
Beantworte die gestellte Frage direkt, strukturiert und ausschließlich auf Basis der übergebenen Dokumentabschnitte. \
Nenne konkrete Fakten (z. B. genaue Parameter, Grenzwerte, Algorithmen, Definitionen) und zitiere deine Quellen im Text immer mit der Nummer des jeweiligen Abschnitts in eckigen Klammern wie [1], [2]. \
Wenn die Antwort nicht in den Quellen enthalten ist, weise klar darauf hin.
"""

    // 9. Apple Vision Figure-Cropping
    public var enableFigureCropping: Bool = true
    public var minFigureAreaRatio: Double = 0.08
    public var renderDPI: Int = 150

    // 10. Agenten-Zugriff (CLI & MCP über den App-Daemon)
    public var agentAccessEnabled: Bool = true
    public var shareSelectionWithAgents: Bool = true

    // 11. Ordner-Synchronisation (noch nicht implementiert, nur für Rückwärtskompatibilität)
    public var autoWatchFolders: Bool = true
    public var watchIntervalMinutes: Int = 30

    // 12. Ersteinrichtung / Onboarding
    public var hasCompletedOnboarding: Bool = false

    public var shouldShowOnboarding: Bool {
        if !hasCompletedOnboarding {
            let status = CortexModelDownloader.checkEmbeddingGemmaStatus()
            let hasDB = FileManager.default.fileExists(atPath: CortexPaths.databaseURL.path)
            if status.isReady && hasDB {
                return false
            }
            return true
        }
        return false
    }

    public init() { ensureProfiles() }

    // MARK: Server profiles

    public var activeLLMProfile: LLMServerProfile? { llmProfiles.first { $0.id == activeLLMProfileID } }
    public var fallbackLLMProfile: LLMServerProfile? {
        fallbackLLMProfileID.isEmpty || fallbackLLMProfileID == activeLLMProfileID ? nil : llmProfiles.first { $0.id == fallbackLLMProfileID }
    }

    /// Creates profiles from older single-endpoint settings: a local profile plus the remote oMLX profile (:8072).
    public mutating func ensureProfiles() {
        if llmProfiles.isEmpty {
            let isLocal = llmEndpointURL.contains("127.0.0.1") || llmEndpointURL.contains("localhost")
            if isLocal {
                var local = LLMServerProfile.defaultLocal(model: llmSelectedModel)
                local.endpointURL = llmEndpointURL
                local.apiKey = llmApiKey
                local.preset = llmProviderPreset
                let remote = LLMServerProfile.defaultRemote()
                llmProfiles = [local, remote]
                activeLLMProfileID = local.id
                if fallbackLLMProfileID.isEmpty { fallbackLLMProfileID = remote.id }
            } else {
                let remote = LLMServerProfile(id: "remote", name: "Remote", preset: llmProviderPreset, endpointURL: llmEndpointURL,
                                              apiKey: llmApiKey, model: llmSelectedModel, isRemote: true)
                llmProfiles = [LLMServerProfile.defaultLocal(model: llmSelectedModel), remote]
                activeLLMProfileID = remote.id
                fallbackLLMProfileID = "local"
            }
            return
        }
        if !llmProfiles.contains(where: { $0.isRemote || $0.endpointURL.contains(":8072") }) {
            let remote = LLMServerProfile.defaultRemote()
            llmProfiles.append(remote)
            if fallbackLLMProfileID.isEmpty { fallbackLLMProfileID = remote.id }
        }
        if activeLLMProfile == nil, let first = llmProfiles.first {
            activeLLMProfileID = first.id
            applyActiveProfile()
        }
    }

    /// Copies the active profile into the llm* fields that the rest of the app reads.
    public mutating func applyActiveProfile() {
        guard let p = activeLLMProfile else { return }
        llmEndpointURL = p.endpointURL
        llmApiKey = p.apiKey
        llmSelectedModel = p.model
        llmProviderPreset = p.preset
    }

    /// Writes edits of the llm* fields back into the active profile.
    public mutating func storeFieldsIntoActiveProfile() {
        guard let i = llmProfiles.firstIndex(where: { $0.id == activeLLMProfileID }) else { return }
        llmProfiles[i].endpointURL = llmEndpointURL
        llmProfiles[i].apiKey = llmApiKey
        llmProfiles[i].model = llmSelectedModel
        llmProfiles[i].preset = llmProviderPreset
    }

    /// Settings copy that talks to another profile (used for the fallback).
    public func using(profile p: LLMServerProfile) -> CortexSettings {
        var c = self
        c.llmEndpointURL = p.endpointURL
        c.llmApiKey = p.apiKey
        c.llmSelectedModel = p.model
        c.llmProviderPreset = p.preset
        return c
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CortexSettings()
        appearanceMode = try c.decodeIfPresent(AppAppearanceMode.self, forKey: .appearanceMode) ?? d.appearanceMode
        accentChoice = try c.decodeIfPresent(AccentChoice.self, forKey: .accentChoice) ?? d.accentChoice
        interfaceLanguage = try c.decodeIfPresent(InterfaceLanguage.self, forKey: .interfaceLanguage) ?? d.interfaceLanguage
        showMenuBarItem = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarItem) ?? d.showMenuBarItem
        showDockIcon = try c.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? d.showDockIcon
        autoOpenMainWindowOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .autoOpenMainWindowOnLaunch) ?? d.autoOpenMainWindowOnLaunch
        customStorageDirectory = try c.decodeIfPresent(String.self, forKey: .customStorageDirectory) ?? d.customStorageDirectory
        indexOnlyOnACPower = try c.decodeIfPresent(Bool.self, forKey: .indexOnlyOnACPower) ?? d.indexOnlyOnACPower
        pauseOnLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseOnLowPowerMode) ?? d.pauseOnLowPowerMode
        throttlingMode = try c.decodeIfPresent(IndexingThrottleMode.self, forKey: .throttlingMode) ?? d.throttlingMode
        batteryThrottlingMode = try c.decodeIfPresent(IndexingThrottleMode.self, forKey: .batteryThrottlingMode) ?? d.batteryThrottlingMode
        idleMemoryMode = try c.decodeIfPresent(IdleMemoryMode.self, forKey: .idleMemoryMode) ?? d.idleMemoryMode
        idleTimeoutMinutes = try c.decodeIfPresent(Int.self, forKey: .idleTimeoutMinutes) ?? d.idleTimeoutMinutes
        targetChunkSize = try c.decodeIfPresent(Int.self, forKey: .targetChunkSize) ?? d.targetChunkSize
        chunkOverlap = try c.decodeIfPresent(Int.self, forKey: .chunkOverlap) ?? d.chunkOverlap
        minChunkLength = try c.decodeIfPresent(Int.self, forKey: .minChunkLength) ?? d.minChunkLength
        defaultEngine = try c.decodeIfPresent(EngineKind.self, forKey: .defaultEngine) ?? d.defaultEngine
        embeddingDimension = try c.decodeIfPresent(MatryoshkaDimension.self, forKey: .embeddingDimension) ?? d.embeddingDimension
        if let mode = try c.decodeIfPresent(ImageVectorMode.self, forKey: .imageVectorMode) {
            imageVectorMode = mode
            imageVectorsEnabled = (mode != .disabled)
        } else {
            let enabled = try c.decodeIfPresent(Bool.self, forKey: .imageVectorsEnabled) ?? d.imageVectorsEnabled
            imageVectorsEnabled = enabled
            imageVectorMode = enabled ? .adaptive : .disabled
        }
        embeddingTaskMode = try c.decodeIfPresent(EmbeddingTaskMode.self, forKey: .embeddingTaskMode) ?? d.embeddingTaskMode
        chunkDisplayMode = try c.decodeIfPresent(ChunkDisplayMode.self, forKey: .chunkDisplayMode) ?? d.chunkDisplayMode
        retrievalTopKPool = try c.decodeIfPresent(Int.self, forKey: .retrievalTopKPool) ?? d.retrievalTopKPool
        maxDisplayedResults = try c.decodeIfPresent(Int.self, forKey: .maxDisplayedResults) ?? d.maxDisplayedResults
        defaultTopK = try c.decodeIfPresent(Int.self, forKey: .defaultTopK) ?? d.defaultTopK
        defaultContextRadius = try c.decodeIfPresent(Int.self, forKey: .defaultContextRadius) ?? d.defaultContextRadius
        showSurroundingContextExpanded = try c.decodeIfPresent(Bool.self, forKey: .showSurroundingContextExpanded) ?? d.showSurroundingContextExpanded
        hybridDenseWeight = try c.decodeIfPresent(Double.self, forKey: .hybridDenseWeight) ?? d.hybridDenseWeight
        hybridBM25Weight = try c.decodeIfPresent(Double.self, forKey: .hybridBM25Weight) ?? d.hybridBM25Weight
        minCosineScore = try c.decodeIfPresent(Double.self, forKey: .minCosineScore) ?? d.minCosineScore
        enableReranker = try c.decodeIfPresent(Bool.self, forKey: .enableReranker) ?? d.enableReranker
        selectedRerankerModel = try c.decodeIfPresent(RerankerModelKind.self, forKey: .selectedRerankerModel) ?? d.selectedRerankerModel
        rerankCandidatePoolSize = try c.decodeIfPresent(Int.self, forKey: .rerankCandidatePoolSize) ?? d.rerankCandidatePoolSize
        neuralReranker = try c.decodeIfPresent(NeuralRerankerModel.self, forKey: .neuralReranker) ?? d.neuralReranker
        contentLanguage = try c.decodeIfPresent(ContentLanguage.self, forKey: .contentLanguage) ?? d.contentLanguage
        answerLanguage = try c.decodeIfPresent(AnswerLanguage.self, forKey: .answerLanguage) ?? d.answerLanguage
        enableAISynthesis = try c.decodeIfPresent(Bool.self, forKey: .enableAISynthesis) ?? d.enableAISynthesis
        enableThinking = try c.decodeIfPresent(Bool.self, forKey: .enableThinking) ?? d.enableThinking
        aiSynthesisTrigger = try c.decodeIfPresent(AISynthesisTriggerMode.self, forKey: .aiSynthesisTrigger) ?? d.aiSynthesisTrigger
        // Not the defaults of `CortexSettings()` (which already holds a local profile): missing keys mean "migrate".
        llmProfiles = try c.decodeIfPresent([LLMServerProfile].self, forKey: .llmProfiles) ?? []
        activeLLMProfileID = try c.decodeIfPresent(String.self, forKey: .activeLLMProfileID) ?? ""
        fallbackLLMProfileID = try c.decodeIfPresent(String.self, forKey: .fallbackLLMProfileID) ?? d.fallbackLLMProfileID
        llmProviderPreset = try c.decodeIfPresent(LLMProviderPreset.self, forKey: .llmProviderPreset) ?? d.llmProviderPreset
        llmEndpointURL = try c.decodeIfPresent(String.self, forKey: .llmEndpointURL) ?? d.llmEndpointURL
        llmApiKey = try c.decodeIfPresent(String.self, forKey: .llmApiKey) ?? d.llmApiKey
        llmSelectedModel = try c.decodeIfPresent(String.self, forKey: .llmSelectedModel) ?? d.llmSelectedModel
        llmTemperature = try c.decodeIfPresent(Double.self, forKey: .llmTemperature) ?? d.llmTemperature
        llmMaxTokens = try c.decodeIfPresent(Int.self, forKey: .llmMaxTokens) ?? d.llmMaxTokens
        maxChunksForLLM = try c.decodeIfPresent(Int.self, forKey: .maxChunksForLLM) ?? d.maxChunksForLLM
        searchContentMode = try c.decodeIfPresent(SearchContentMode.self, forKey: .searchContentMode) ?? d.searchContentMode
        minFigureScore = try c.decodeIfPresent(Double.self, forKey: .minFigureScore) ?? d.minFigureScore
        maxImagesForLLM = try c.decodeIfPresent(Int.self, forKey: .maxImagesForLLM) ?? d.maxImagesForLLM
        llmSystemPrompt = try c.decodeIfPresent(String.self, forKey: .llmSystemPrompt) ?? d.llmSystemPrompt
        enableFigureCropping = try c.decodeIfPresent(Bool.self, forKey: .enableFigureCropping) ?? d.enableFigureCropping
        minFigureAreaRatio = try c.decodeIfPresent(Double.self, forKey: .minFigureAreaRatio) ?? d.minFigureAreaRatio
        renderDPI = try c.decodeIfPresent(Int.self, forKey: .renderDPI) ?? d.renderDPI
        agentAccessEnabled = try c.decodeIfPresent(Bool.self, forKey: .agentAccessEnabled) ?? d.agentAccessEnabled
        shareSelectionWithAgents = try c.decodeIfPresent(Bool.self, forKey: .shareSelectionWithAgents) ?? d.shareSelectionWithAgents
        autoWatchFolders = try c.decodeIfPresent(Bool.self, forKey: .autoWatchFolders) ?? d.autoWatchFolders
        watchIntervalMinutes = try c.decodeIfPresent(Int.self, forKey: .watchIntervalMinutes) ?? d.watchIntervalMinutes
        ensureProfiles()
    }
}

public final class CortexSettingsManager: @unchecked Sendable {
    public static let shared = CortexSettingsManager()

    private let lock = NSLock()
    private var _settings: CortexSettings

    private static var settingsFileURL: URL {
        // Isolated instances (benchmarks, tests) keep their settings next to their data.
        if let home = ProcessInfo.processInfo.environment["CORTEXRAG_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home).appendingPathComponent("settings.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CortexRAG", isDirectory: true)
        return base.appendingPathComponent("settings.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.settingsFileURL),
           let decoded = try? JSONDecoder().decode(CortexSettings.self, from: data) {
            self._settings = decoded
        } else {
            self._settings = CortexSettings()
        }
    }

    public var settings: CortexSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _settings
        }
        set {
            lock.lock()
            _settings = newValue
            lock.unlock()
            save()
        }
    }

    public func update(_ block: (inout CortexSettings) -> Void) {
        lock.lock()
        block(&_settings)
        lock.unlock()
        save()
    }

    public func save() {
        lock.lock()
        let toSave = _settings
        let url = Self.settingsFileURL
        lock.unlock()

        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(toSave)
            try data.write(to: url, options: .atomic)
        } catch {
            fputs("Warning: Could not save CortexSettings: \(error)\n", stderr)
        }
    }

    public func resetToDefaults() {
        lock.lock()
        _settings = CortexSettings()
        lock.unlock()
        save()
    }
}
