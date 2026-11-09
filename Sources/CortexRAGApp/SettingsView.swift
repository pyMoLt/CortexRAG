import SwiftUI
import AppKit
import Charts
import CortexCore

/// Settings window (⌘,). All values bind directly to `AppViewModel.settings`, which persists every change.
struct SettingsView: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        TabView(selection: $vm.settingsTab) {
            Tab("Allgemein", systemImage: "gearshape", value: 0) { GeneralSettings(vm: vm) }
            Tab("KI-Antworten", systemImage: "sparkles", value: 1) { AISettings(vm: vm) }
            Tab("Suche", systemImage: "magnifyingglass", value: 2) { SearchSettings(vm: vm) }
            Tab("Indizierung", systemImage: "doc.viewfinder", value: 3) { IndexingSettings(vm: vm) }
            Tab("Energie", systemImage: "bolt.badge.clock", value: 4) { EnergySettings(vm: vm) }
            Tab("Engine-Test", systemImage: "gauge.with.dots.needle.67percent", value: 5) { BenchmarkSettings(vm: vm) }
        }
        .frame(width: 640, height: 600)
    }
}

private struct Hint: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }
    init(verbatim: String) { self.text = LocalizedStringKey(verbatim) }
    var body: some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var vm: AppViewModel
    @State private var storageSize = "…"

    private var languageNeedsRestart: Bool {
        let active = vm.activeInterfaceLanguageCode.hasPrefix("en") ? "en" : "de"
        switch vm.settings.interfaceLanguage {
        case .system:
            let system = (Locale.preferredLanguages.first ?? "de").hasPrefix("en") ? "en" : "de"
            return system != active
        case .german: return active != "de"
        case .english: return active != "en"
        }
    }

    var body: some View {
        Form {
            Section("Darstellung") {
                Picker("Sprache der Oberfläche", selection: $vm.settings.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                .pickerStyle(.segmented)
                if languageNeedsRestart {
                    HStack {
                        Label("Wird nach einem Neustart übernommen", systemImage: "arrow.clockwise.circle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Jetzt neu starten") { vm.relaunch() }
                    }
                }
                Picker("Erscheinungsbild", selection: $vm.settings.appearanceMode) {
                    Text("System").tag(AppAppearanceMode.system)
                    Text("Hell").tag(AppAppearanceMode.light)
                    Text("Dunkel").tag(AppAppearanceMode.dark)
                }
                .pickerStyle(.segmented)
                LabeledContent("Akzentfarbe") {
                    HStack(spacing: 8) {
                        ForEach(AccentChoice.allCases, id: \.self) { choice in
                            let c = choice.rgb
                            Button { vm.settings.accentChoice = choice } label: {
                                Circle()
                                    .fill(LinearGradient(colors: [Color(red: c.primary.0, green: c.primary.1, blue: c.primary.2),
                                                                  Color(red: c.secondary.0, green: c.secondary.1, blue: c.secondary.2)],
                                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(vm.settings.accentChoice == choice ? 0.75 : 0), lineWidth: 2).padding(-3))
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help(LocalizedStringKey(choice.displayName))
                        }
                    }
                }
                Toggle("Symbol im Dock", isOn: $vm.settings.showDockIcon)
                    .disabled(!vm.settings.showMenuBarItem)
                Toggle("Symbol in der Menüleiste", isOn: $vm.settings.showMenuBarItem)
                    .disabled(!vm.settings.showDockIcon)
                Hint("Mindestens eines der beiden Symbole bleibt sichtbar, damit die App erreichbar ist.")
            }

            Section {
                Picker("Sprache der Dokumente", selection: $vm.settings.contentLanguage) {
                    ForEach(ContentLanguage.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                Picker("Sprache der KI-Antworten", selection: $vm.settings.answerLanguage) {
                    ForEach(AnswerLanguage.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
            } header: {
                Text("Sprache")
            } footer: {
                Hint("Die Suche ist mehrsprachig: Eine deutsche Frage findet auch englische Textstellen und umgekehrt. Die Dokumentsprache steuert die Regeln drumherum – Fragen-Erkennung, Nachsortierung, Folgefragen und Abbildungsbeschriftungen. Bei gemischten Bibliotheken „gemischt“ wählen. Tipp: Stellst du oft Fragen in einer anderen Sprache als die Dokumente, verbessert der BGE-Reranker (Suche → Nachsortierung) die Reihenfolge deutlich.")
            }

            Section("KI-Agenten (CLI & MCP)") {
                Toggle("Agenten-Zugriff aktiv", isOn: Binding(get: { vm.settings.agentAccessEnabled }, set: { vm.setAgentAccess($0) }))
                Toggle("Auswahl der Seitenleiste für Agenten verwenden", isOn: $vm.settings.shareSelectionWithAgents)
                Hint("CLI und MCP funktionieren nur, solange CortexRAG läuft und der Zugriff aktiv ist. Beenden der App sperrt den Zugriff vollständig.")
            }

            Section("Speicherort") {
                LabeledContent("Ordner") {
                    Text(CortexPaths.appSupport.path)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                LabeledContent("Belegt", value: storageSize)
                HStack {
                    Button("Anderen Ordner wählen …") { chooseDirectory() }
                    if !vm.settings.customStorageDirectory.isEmpty {
                        Button("Standard verwenden") { vm.settings.customStorageDirectory = "" }
                    }
                    Spacer()
                    Button("Im Finder zeigen") { NSWorkspace.shared.open(CortexPaths.appSupport) }
                }
                if vm.settings.customStorageDirectory != "" && vm.settings.customStorageDirectory != CortexPaths.appSupport.path
                    || (vm.settings.customStorageDirectory.isEmpty && CortexPaths.appSupport.path.contains("Application Support") == false) {
                    Hint("Der neue Speicherort wird nach einem Neustart von CortexRAG verwendet. Vorhandene Daten werden nicht verschoben.")
                }
                HStack {
                    Button("Ersteinrichtungs-Assistent öffnen …") {
                        vm.showSetupAssistant = true
                    }
                    Spacer()
                }
                .padding(.top, 4)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: measure)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Verwenden"
        if panel.runModal() == .OK, let url = panel.url {
            vm.settings.customStorageDirectory = url.path
        }
    }

    private func measure() {
        let url = CortexPaths.appSupport
        Task.detached(priority: .utility) {
            let text = ByteCountFormatter.string(fromByteCount: Self.folderSize(url), countStyle: .file)
            await MainActor.run { storageSize = text }
        }
    }

    nonisolated private static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        while let f = e.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}

// MARK: - AI

private struct AISettings: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Form {
            Section {
                Toggle("KI-Antwort zu Suchergebnissen", isOn: Binding(get: { vm.settings.enableAISynthesis }, set: { vm.setAIEnabled($0) }))
                Picker("Erzeugen", selection: $vm.settings.aiSynthesisTrigger) {
                    Text("Automatisch bei jeder Suche").tag(AISynthesisTriggerMode.automatic)
                    Text("Nur auf Klick").tag(AISynthesisTriggerMode.onDemand)
                }
                .disabled(!vm.settings.enableAISynthesis)
            }

            Section {
                Picker("Aktives Server-Profil", selection: Binding(get: { vm.settings.activeLLMProfileID }, set: { vm.activateProfile($0) })) {
                    ForEach(vm.settings.llmProfiles) { p in
                        Label(p.name, systemImage: p.isRemote ? "network" : "desktopcomputer").tag(p.id)
                    }
                }
                Picker("Fallback bei Nichterreichbarkeit", selection: $vm.settings.fallbackLLMProfileID) {
                    Text("Kein Fallback").tag("")
                    ForEach(vm.settings.llmProfiles.filter { $0.id != vm.settings.activeLLMProfileID }) { p in
                        Text(p.name).tag(p.id)
                    }
                }
            } header: {
                Text("Aktives Profil & Fallback")
            } footer: {
                Hint("Das aktive Profil beantwortet alle KI-Anfragen. Antwortet es nicht, springt das Fallback-Profil einmalig ein. Suche, Embeddings und Reranker laufen immer lokal.")
            }

            ForEach($vm.settings.llmProfiles) { $profile in
                ServerProfileCard(vm: vm, profile: $profile)
            }

            Section {
                HStack {
                    Button { vm.addProfile(remote: false) } label: { Label("Lokales Profil", systemImage: "desktopcomputer") }
                    Button { vm.addProfile(remote: true) } label: { Label("Remote-Profil", systemImage: "network") }
                    Spacer()
                    Button { Task { await vm.pingAllProfiles() } } label: { Label("Alle pingen", systemImage: "dot.radiowaves.left.and.right") }
                }
            } header: {
                Text("Profil hinzufügen")
            } footer: {
                Hint("Remote: z. B. ein anderer Mac im Tailnet (Tailscale), etwa http://100.x.y.z:8000/v1. Die meisten lokalen Server sprechen http://, nicht https://.")
            }

            Section {
                HStack {
                    Button {
                        Task { await vm.testLLMGeneration() }
                    } label: {
                        if vm.isTestingLLM { ProgressView().controlSize(.small) } else { Text("Testantwort anfordern") }
                    }
                    Button("Aus Speicher entladen") { vm.unloadActiveModel() }
                    Spacer()
                }
                if let msg = vm.llmTestMessage {
                    Hint(verbatim: msg)
                }
            } header: {
                Text("Aktives Profil testen")
            }

            Section("Antwort") {
                Toggle("Denkprozess (Reasoning) erlauben", isOn: $vm.settings.enableThinking)
                Hint("Aus: direkte Antworten in wenigen Sekunden. An: gründlicher, aber deutlich langsamer. Der Gedankengang erscheint einklappbar über der Antwort.")
                Stepper("Quellen an das Modell: \(vm.settings.maxChunksForLLM)", value: $vm.settings.maxChunksForLLM, in: 1...12)
                Stepper(vm.settings.maxImagesForLLM == 0 ? "Bilder an das Modell: keine" : "Bilder an das Modell: höchstens \(vm.settings.maxImagesForLLM)",
                        value: $vm.settings.maxImagesForLLM, in: 0...8)
                Hint("Abbildungen unter den Quellen gehen als Bild mit (mit ihrer Quellennummer), wenn das Modell Bilder versteht – etwa Qwen 3.5/3.6. Modelle ohne Bildverständnis erhalten automatisch nur den Text. Jedes Bild kostet etwa so viel wie zwei bis drei Textabschnitte.")
                LabeledContent("Temperatur") {
                    Slider(value: $vm.settings.llmTemperature, in: 0...1, step: 0.05) { EmptyView() }
                        .frame(width: 220)
                    Text(String(format: "%.2f", vm.settings.llmTemperature)).monospacedDigit().frame(width: 36)
                }
                Stepper("Max. Länge: \(vm.settings.llmMaxTokens) Tokens", value: $vm.settings.llmMaxTokens, in: 256...8192, step: 256)
            }

            Section {
                TextEditor(text: $vm.settings.llmSystemPrompt)
                    .font(.system(size: 12))
                    .frame(minHeight: 110)
                Button("Standard-Prompt wiederherstellen") {
                    vm.settings.llmSystemPrompt = CortexSettings().llmSystemPrompt
                }
            } header: {
                Text("System-Prompt")
            } footer: {
                Hint("Die KI wird angewiesen, Markdown zu verwenden und Quellen als [1], [2] zu zitieren – diese werden in der Antwort anklickbar.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Editable card for one server profile (inside the AI settings form).
private struct ServerProfileCard: View {
    @Bindable var vm: AppViewModel
    @Binding var profile: LLMServerProfile

    private var ping: LLMPingResult? { vm.profilePings[profile.id] }
    private var isActive: Bool { vm.settings.activeLLMProfileID == profile.id }

    var body: some View {
        Section {
            HStack(spacing: 10) {
                Button { vm.activateProfile(profile.id) } label: {
                    Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isActive ? Theme.success : .secondary)
                }
                .buttonStyle(.plain)
                .help("Als aktives Profil verwenden")
                TextField("", text: $profile.name, prompt: Text("Name"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .frame(maxWidth: 170, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                if isActive {
                    Text("AKTIV")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.success)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.success.opacity(0.15), in: Capsule())
                } else if vm.settings.fallbackLLMProfileID == profile.id {
                    Text("FALLBACK")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.warning)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Theme.warning.opacity(0.15), in: Capsule())
                }
                Spacer(minLength: 12)
                Text("Remote").font(.system(size: 11.5)).foregroundStyle(.secondary)
                Toggle("Remote", isOn: $profile.isRemote)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Button {
                    Task { await vm.pingProfile(profile) }
                } label: {
                    HStack(spacing: 5) {
                        if vm.pingingProfiles.contains(profile.id) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Circle().fill(ping == nil ? Color.secondary : (ping!.ok ? Theme.success : Color.red)).frame(width: 7, height: 7)
                        }
                        Text(ping?.ok == true ? "\(Int(ping!.latencyMs)) ms" : "Ping")
                    }
                }
                .help(ping?.message ?? "Verbindung prüfen")
                Button(role: .destructive) { vm.deleteProfile(profile.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(vm.settings.llmProfiles.count <= 1)
                    .help("Profil löschen")
            }
            Picker("Anbieter", selection: $profile.preset) {
                Text("oMLX").tag(LLMProviderPreset.omlx)
                Text("LM Studio").tag(LLMProviderPreset.lmStudio)
                Text("Eigener").tag(LLMProviderPreset.customOpenAI)
            }
            .onChange(of: profile.preset) { _, preset in
                guard preset != .customOpenAI, !profile.isRemote else { return }
                profile.endpointURL = preset.defaultEndpointURL
                profile.apiKey = preset.defaultApiKey
            }
            TextField("Server-URL", text: $profile.endpointURL, prompt: Text(profile.isRemote ? "http://100.x.y.z:8000/v1" : "http://127.0.0.1:8000/v1"))
                .font(.system(size: 12, design: .monospaced))
            SecureField("API-Key", text: $profile.apiKey)
            HStack {
                TextField("Modell", text: $profile.model)
                    .font(.system(size: 12, design: .monospaced))
                if let models = ping?.models, !models.isEmpty {
                    Menu("\(models.filter(\.isChatModel).count)") {
                        ForEach(models.filter(\.isChatModel)) { m in
                            Button(m.displayLabel) { profile.model = m.id }
                        }
                    }
                    .fixedSize()
                    .help("Modelle des Servers")
                }
            }
            if let ping, !ping.ok {
                HStack {
                    Label(ping.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                    Spacer()
                    if let fix = ping.suggestedEndpointURL {
                        Button("Auf \(fix) umstellen") {
                            profile.endpointURL = fix
                            Task { await vm.pingProfile(profile) }
                        }
                    }
                }
            }
        } header: {
            Label(profile.isRemote ? "Remote-Server" : "Lokaler Server", systemImage: profile.isRemote ? "network" : "desktopcomputer")
        }
    }
}

// MARK: - Search

private struct SearchSettings: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Form {
            Section("Ergebnisse") {
                Stepper("Angezeigte Treffer: \(vm.settings.maxDisplayedResults)", value: $vm.settings.maxDisplayedResults, in: 3...30)
                Stepper("Kontext ringsum: ±\(vm.settings.defaultContextRadius) Abschnitte", value: $vm.settings.defaultContextRadius, in: 0...4)
                Toggle("Kontext in Trefferkarten aufgeklappt zeigen", isOn: $vm.settings.showSurroundingContextExpanded)
                Picker("Textdarstellung", selection: $vm.settings.chunkDisplayMode) {
                    Text("Lesetext (bereinigt)").tag(ChunkDisplayMode.cleaned)
                    Text("Original").tag(ChunkDisplayMode.raw)
                }
            }

            Section {
                Picker("Nachsortierung", selection: Binding(
                    get: { vm.settings.neuralReranker != .none ? 2 : (vm.settings.enableReranker ? 1 : 0) },
                    set: { mode in
                        switch mode {
                        case 0: vm.settings.enableReranker = false; vm.settings.neuralReranker = .none
                        case 1: vm.settings.enableReranker = true; vm.settings.neuralReranker = .none
                        default:
                            if let first = NeuralRerankerModel.allCases.first(where: { $0 != .none && $0.isDownloaded }) {
                                vm.settings.neuralReranker = first
                            }
                        }
                    }
                )) {
                    Text("Aus").tag(0)
                    Text("Wortregel").tag(1)
                    Text("Modell").tag(2)
                        .disabled(!NeuralRerankerModel.allCases.contains { $0 != .none && $0.isDownloaded })
                }
                .pickerStyle(.segmented)
                Stepper("Kandidaten: \(vm.settings.rerankCandidatePoolSize)",
                        value: Binding(get: { vm.settings.rerankCandidatePoolSize },
                                       set: { vm.settings.rerankCandidatePoolSize = $0; vm.settings.retrievalTopKPool = $0 }),
                        in: 10...40, step: 2)
                    .disabled(!vm.settings.enableReranker && vm.settings.neuralReranker == .none)
            } header: {
                Text("Nachsortierung")
            } footer: {
                Hint("Wortregel: bewertet die besten Kandidaten nach Begriffsabdeckung, Wortnähe, Kapitel und Zahlenangaben – ohne Zusatzspeicher. Modell: ein Cross-Encoder liest Frage und Abschnitt gemeinsam und sortiert genauer, kostet aber Zeit und Arbeitsspeicher. Gilt auch für CLI und MCP.")
            }

            Section {
                ForEach(NeuralRerankerModel.allCases.filter { $0 != .none }) { model in
                    rerankerRow(model)
                }
            } header: {
                Text("Reranker-Modelle")
            } footer: {
                Hint("Im Test mit 60 Fragen aus deiner Bibliothek war der erste Treffer bei BGE in 93 % der Fälle relevant (Wortregel 90 %, ohne 88 %). Modelle werden erst bei der ersten Suche geladen und nach dem Leerlauf-Timeout wieder entladen. Standardmäßig aus.")
            }

            Section {
                LabeledContent("Gewichtung") {
                    Text("Stichwort").font(.system(size: 11)).foregroundStyle(.secondary)
                    Slider(value: Binding(get: { vm.settings.hybridDenseWeight },
                                          set: { vm.settings.hybridDenseWeight = $0; vm.settings.hybridBM25Weight = 1 - $0 }),
                           in: 0.1...0.9, step: 0.05) { EmptyView() }
                        .frame(width: 200)
                    Text("Bedeutung").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                LabeledContent("Mindest-Relevanz") {
                    Slider(value: $vm.settings.minCosineScore, in: 0.1...0.8, step: 0.02) { EmptyView() }
                        .frame(width: 220)
                    Text(String(format: "%.2f", vm.settings.minCosineScore)).monospacedDigit().frame(width: 36)
                }
                Picker("Suchen in", selection: $vm.settings.searchContentMode) {
                    ForEach(SearchContentMode.allCases, id: \.self) { Label(LocalizedStringKey($0.displayName), systemImage: $0.icon).tag($0) }
                }
                LabeledContent("Mindest-Passung für Bilder") {
                    Slider(value: $vm.settings.minFigureScore, in: 0.1...0.6, step: 0.01) { EmptyView() }
                        .frame(width: 220)
                    Text(String(format: "%.2f", vm.settings.minFigureScore)).monospacedDigit().frame(width: 36)
                }
            } header: {
                Text("Hybride Suche")
            } footer: {
                Hint("Bedeutung = semantische Vektorsuche (findet Synonyme), Stichwort = exakte Begriffe (BM25). Treffer unter der Mindest-Relevanz werden ausgeblendet, sofern es bessere gibt. Text und Bilder liegen im selben Vektorraum und werden nach Rang gemischt; Bilder erscheinen erst ab der Mindest-Passung.")
            }

            Section {
                Button("Alle Sucheinstellungen zurücksetzen") {
                    let d = CortexSettings()
                    vm.settings.maxDisplayedResults = d.maxDisplayedResults
                    vm.settings.defaultContextRadius = d.defaultContextRadius
                    vm.settings.enableReranker = d.enableReranker
                    vm.settings.rerankCandidatePoolSize = d.rerankCandidatePoolSize
                    vm.settings.retrievalTopKPool = d.retrievalTopKPool
                    vm.settings.hybridDenseWeight = d.hybridDenseWeight
                    vm.settings.hybridBM25Weight = d.hybridBM25Weight
                    vm.settings.minCosineScore = d.minCosineScore
                    vm.settings.minFigureScore = d.minFigureScore
                    vm.settings.searchContentMode = d.searchContentMode
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension SearchSettings {
    @ViewBuilder
    func rerankerRow(_ model: NeuralRerankerModel) -> some View {
        let active = vm.settings.neuralReranker == model
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: active ? "checkmark.circle.fill" : (model.isDownloaded ? "circle" : "arrow.down.circle"))
                .font(.system(size: 16))
                .foregroundStyle(active ? Theme.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName).font(.system(size: 12.5, weight: .semibold))
                Text(LocalizedStringKey(model.subtitle)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = vm.rerankerDownloads[model] {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100)) %").font(.system(size: 11).monospacedDigit()).frame(width: 36)
                Button { vm.cancelRerankerDownload(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
            } else if model.isDownloaded {
                if active {
                    Button("Deaktivieren") { vm.settings.neuralReranker = .none }
                } else {
                    Button("Verwenden") { vm.settings.neuralReranker = model }
                }
                Button(role: .destructive) { vm.deleteReranker(model) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Modelldatei löschen")
            } else {
                Button("Laden (~\(model.approximateSizeMB) MB)") { vm.downloadReranker(model) }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Indexing

private struct IndexingSettings: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: Binding(get: { vm.activeEngine }, set: { vm.switchEngine(to: $0) })) {
                    ForEach(EngineKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .disabled(vm.isSwitchingEngine || vm.isIndexing)
                Picker("Vektorgröße", selection: $vm.settings.embeddingDimension) {
                    ForEach(MatryoshkaDimension.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                Picker("Anfrage-Präfix", selection: $vm.settings.embeddingTaskMode) {
                    ForEach(EmbeddingTaskMode.allCases, id: \.self) { Text(LocalizedStringKey($0.displayName)).tag($0) }
                }
                Picker("Bild-Vektoren", selection: $vm.settings.imageVectorMode) {
                    ForEach(ImageVectorMode.allCases, id: \.self) { mode in
                        Text(LocalizedStringKey(mode.displayName)).tag(mode)
                    }
                }
                LabeledContent("Arbeitsspeicher", value: "\(Int(vm.memoryUsageMB)) MB")
            } header: {
                Text("Embedding (EmbeddingGemma)")
            } footer: {
                Hint("Automatisch (empfohlen) bettet bei Vorlesungsfolien die ganze Folie ein (52 % Top-1) und bei Textskripten/Büchern jedes Inline-Bild samt direktem Umfeld & Beschriftung. Die ausgeschnittenen Einzelbilder können von KI & MCP-Agenten jederzeit gezielt oder on-the-fly abgerufen werden.")
            }

            Section {
                Stepper("Abschnittsgröße: \(vm.settings.targetChunkSize) Zeichen", value: $vm.settings.targetChunkSize, in: 300...2000, step: 50)
                Stepper("Überlappung: \(vm.settings.chunkOverlap) Zeichen", value: $vm.settings.chunkOverlap, in: 0...500, step: 25)
                Stepper("Mindestlänge: \(vm.settings.minChunkLength) Zeichen", value: $vm.settings.minChunkLength, in: 20...200, step: 10)
                Toggle("Abbildungen per Apple Vision ausschneiden", isOn: $vm.settings.enableFigureCropping)
                Stepper("Render-Auflösung: \(vm.settings.renderDPI) DPI", value: $vm.settings.renderDPI, in: 96...300, step: 12)
            } header: {
                Text("Zerlegung")
            } footer: {
                Hint("Gilt für neu indizierte Dokumente. Bestehende Dokumente über „Neu indizieren“ aktualisieren.")
            }

            Section {
                Toggle("Importierte Ordner überwachen", isOn: $vm.settings.autoWatchFolders)
                Button("Ordner jetzt synchronisieren") { vm.syncFolders() }
                    .disabled(!vm.settings.autoWatchFolders || vm.isIndexing || vm.watchedFolders.isEmpty)
            } header: {
                Text("Ordner")
            } footer: {
                Hint("Neue oder geänderte PDFs in importierten Ordnern werden automatisch indiziert (nur am Netzteil, wenn so eingestellt). Unveränderte Dateien werden übersprungen. Gelöschte Dateien bleiben in der Bibliothek, bis du sie entfernst.")
            }

            Section {
                Button("Ganze Bibliothek neu indizieren (\(vm.documents.count) Dokumente)") { vm.reindex(vm.documents) }
                    .disabled(vm.isIndexing || vm.documents.isEmpty)
                if vm.hasSelection {
                    Button("Nur Auswahl neu indizieren (\(vm.scopedDocuments.count))") { vm.reindex(vm.scopedDocuments) }
                        .disabled(vm.isIndexing)
                }
                Button("Doppelte Dokumente bereinigen") { vm.deduplicateLibrary() }
                    .disabled(vm.isIndexing || vm.documents.count < 2)
                Button(vm.isRefreshingCaptions ? "Bildunterschriften werden aktualisiert …" : "Bildunterschriften aus dem PDF-Text aktualisieren") {
                    vm.refreshFigureCaptions()
                }
                .disabled(vm.isIndexing || vm.isRefreshingCaptions || vm.documents.isEmpty)
                Hint("Liest die Unterschriften unbeschrifteter Abbildungen neu aus der Textebene der PDF (statt aus der Bilderkennung) und aktualisiert ihre Suchdaten – ohne Neuindizierung. Neu importierte Dokumente erhalten sie automatisch.")
                if vm.isIndexing {
                    HStack(spacing: 8) {
                        if vm.importer.isEffectivelyPaused {
                            Image(systemName: "pause.circle.fill").foregroundStyle(Theme.warning)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        Text(vm.importer.current.map { "\($0.title)\($0.detail.isEmpty ? "" : " · \($0.detail)")" } ?? vm.progressMessage)
                            .font(.system(size: 11.5)).lineLimit(1)
                        Spacer()
                        Button(vm.importer.isEffectivelyPaused ? "Fortsetzen" : "Pausieren") {
                            vm.importer.togglePause()
                        }
                        Button("Abbrechen", role: .destructive) {
                            vm.importer.cancelAll()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Energy

private struct EnergySettings: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Stromquelle", value: PowerManager.shared.isOnBattery() ? "Akku" : "Netzteil")
                Picker("Tempo am Netzteil", selection: $vm.settings.throttlingMode) {
                    Text("Turbo (Maximal)").tag(IndexingThrottleMode.turbo)
                    Text("Ausgewogen").tag(IndexingThrottleMode.balanced)
                    Text("Minimal").tag(IndexingThrottleMode.ecoSilent)
                }
                .pickerStyle(.segmented)
                Picker("Auf Akku", selection: $vm.settings.indexOnlyOnACPower) {
                    Text("Pausieren").tag(true)
                    Text("Weiter indizieren").tag(false)
                }
                .pickerStyle(.segmented)
                Picker("Tempo auf Akku", selection: $vm.settings.batteryThrottlingMode) {
                    Text("Minimal").tag(IndexingThrottleMode.ecoSilent)
                    Text("Ausgewogen").tag(IndexingThrottleMode.balanced)
                    Text("Turbo").tag(IndexingThrottleMode.turbo)
                }
                .pickerStyle(.segmented)
                .disabled(vm.settings.indexOnlyOnACPower)
                Toggle("Im Stromsparmodus pausieren", isOn: $vm.settings.pauseOnLowPowerMode)
            } header: {
                Text("Indizierung")
            } footer: {
                Hint("„Turbo“ nutzt alle Kerne und die volle GPU (gemessen: Lernskript mit 156 Seiten in 40 s). „Ausgewogen“ lässt die GPU nach jedem Rechenschritt halb so lange ruhen (ca. ⅔ Auslastung, 60 s), „Minimal“ doppelt so lange (ca. ⅓ Auslastung, 150 s, leise und akkuschonend). Änderungen wirken sofort, auch während einer laufenden Indizierung. Auf Akku kannst du pausieren oder mit eigenem Tempo weiter indizieren.")
            }

            Section {
                Picker("Im Leerlauf", selection: $vm.settings.idleMemoryMode) {
                    Text("Modell geladen lassen").tag(IdleMemoryMode.standard)
                    Text("Modell entladen").tag(IdleMemoryMode.aggressiveUnloadOnIdle)
                }
                if vm.settings.idleMemoryMode == .aggressiveUnloadOnIdle {
                    Stepper("Nach \(vm.settings.idleTimeoutMinutes) Min. Inaktivität", value: $vm.settings.idleTimeoutMinutes, in: 1...60)
                }
            } header: {
                Text("Embedding-Modell")
            } footer: {
                Hint("Entladen gibt GPU- und Arbeitsspeicher frei; die nächste Suche lädt das Modell in unter einer Sekunde neu.")
            }

            Section {
                Button("„\(vm.settings.llmSelectedModel)“ jetzt entladen") { vm.unloadActiveModel() }
                    .disabled(vm.settings.llmSelectedModel.isEmpty)
            } header: {
                Text("Sprachmodell (oMLX)")
            } footer: {
                Hint("Große lokale Modelle belegen viele GB Arbeitsspeicher. Beim nächsten Antwortwunsch werden sie automatisch wieder geladen.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Benchmark

private struct BenchmarkSettings: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Hint("Vergleicht llama.cpp (Metal) und MLX Swift auf diesem Mac: Ladezeit, Latenz, Durchsatz und ob beide Engines dieselben Vektoren liefern. Dauert etwa eine Minute.")
                    Spacer()
                    Button(vm.isBenchmarking ? "Läuft …" : "Test starten") { vm.runEngineBenchmark() }
                        .disabled(vm.isBenchmarking)
                }
                if vm.isBenchmarking {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(vm.progressMessage).font(.system(size: 11.5))
                    }
                }
            }

            if let r = vm.benchmarkReport {
                Section("Ergebnis · \(r.hardwareModel)") {
                    Text(r.recommendation).font(.system(size: 12))
                    LabeledContent("Vektor-Übereinstimmung", value: String(format: "%.4f", r.meanTextCosineSimilarity ?? 0))
                    LabeledContent("Gleicher Top-Treffer", value: String(format: "%.0f %%", r.topKAgreementRate ?? 0))
                    if let l = r.llamaMetrics, let m = r.mlxMetrics {
                        Chart {
                            ForEach([("Anfrage p50", l.queryLatencyP50Ms, m.queryLatencyP50Ms),
                                     ("Anfrage p95", l.queryLatencyP95Ms, m.queryLatencyP95Ms)], id: \.0) { row in
                                BarMark(x: .value("Metrik", row.0), y: .value("ms", row.1))
                                    .foregroundStyle(by: .value("Engine", "llama.cpp"))
                                    .position(by: .value("Engine", "llama.cpp"))
                                BarMark(x: .value("Metrik", row.0), y: .value("ms", row.2))
                                    .foregroundStyle(by: .value("Engine", "MLX"))
                                    .position(by: .value("Engine", "MLX"))
                            }
                        }
                        .chartForegroundStyleScale(["llama.cpp": Theme.accent, "MLX": Theme.figure])
                        .chartYAxisLabel("ms")
                        .frame(height: 160)
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                            GridRow {
                                Text("")
                                Text("llama.cpp").bold()
                                Text("MLX").bold()
                            }
                            row("Laden Text-Encoder", l.textLoadMs, m.textLoadMs, "ms")
                            row("Durchsatz", l.batchTextThroughputChunksPerSec, m.batchTextThroughputChunksPerSec, "Abschn./s")
                            row("Speicher-Spitze", l.peakMemoryMB, m.peakMemoryMB, "MB")
                        }
                        .font(.system(size: 11.5))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ label: String, _ a: Double, _ b: Double, _ unit: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(String(format: "%.0f %@", a, unit)).monospacedDigit()
            Text(String(format: "%.0f %@", b, unit)).monospacedDigit()
        }
    }
}
