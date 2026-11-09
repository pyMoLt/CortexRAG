import SwiftUI
import AppKit
import CortexCore
import CortexEmbedders

public struct SetupAssistantView: View {
    @Bindable var vm: AppViewModel
    @State private var currentStep: Int = 0

    // Temporary states for Step 3 & 4
    @State private var selectedReranker: NeuralRerankerModel = .none
    @State private var selectedPreset: LLMProviderPreset = .omlx
    @State private var endpointURL: String = "http://remote-host.local:8072/v1"
    @State private var apiKey: String = "admin"
    @State private var testStatus: String?
    @State private var isTestingConnection: Bool = false

    public init(vm: AppViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 20) {
                    switch currentStep {
                    case 0:
                        stepDirectories
                    case 1:
                        stepEmbeddingModel
                    case 2:
                        stepReranker
                    case 3:
                        stepLLM
                    default:
                        stepCompletion
                    }
                }
                .padding(28)
                .frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 680, height: 560)
        .background(.regularMaterial)
        .onAppear {
            try? CortexPaths.ensureDirectories()
            vm.refreshEmbeddingModelStatus()
            selectedReranker = vm.settings.neuralReranker
            if let active = vm.settings.activeLLMProfile {
                selectedPreset = active.preset
                endpointURL = active.endpointURL
                apiKey = active.apiKey
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            CortexPrismSymbol(size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("CortexRAG Ersteinrichtung")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text(stepSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stepIndicators
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var stepSubtitle: String {
        switch currentStep {
        case 0: return "Schritt 1 von 5: Verzeichnisse & Speicherorte"
        case 1: return "Schritt 2 von 5: Multimodales Embedding-Modell"
        case 2: return "Schritt 3 von 5: Neuronaler Reranker (Optional)"
        case 3: return "Schritt 4 von 5: KI-Sprachmodell / LLM (Optional)"
        default: return "Schritt 5 von 5: Fertigstellen"
        }
    }

    private var stepIndicators: some View {
        HStack(spacing: 6) {
            ForEach(0..<5) { step in
                Circle()
                    .fill(step == currentStep ? Theme.accent : (step < currentStep ? Theme.success : Color.primary.opacity(0.18)))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Step 0: Directories

    private var stepDirectories: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Willkommen bei CortexRAG")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("CortexRAG speichert deine SQLite-Wissensdatenbank, extrahierte Bildausschnitte und lokale KI-Modelle vollständig auf deinem Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Speicherort", systemImage: "folder.badge.gearshape")
                    .font(.system(size: 13, weight: .semibold))

                VStack(alignment: .leading, spacing: 6) {
                    Text(CortexPaths.appSupport.path)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

                    HStack {
                        Button("Im Finder zeigen") {
                            NSWorkspace.shared.open(CortexPaths.appSupport)
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))

                        Spacer()

                        Button("Verzeichnisse anlegen") {
                            try? CortexPaths.ensureDirectories()
                        }
                        .glassButton(prominent: false)
                        .controlSize(.small)
                    }
                }
            }
            .padding(16)
            .glassSurface(cornerRadius: 14)

            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
                Text("Verzeichnisse für Datenbank, Assets und Modelle sind initialisiert.")
                    .font(.system(size: 12.5))
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Step 1: Embedding Model

    private var stepEmbeddingModel: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Multimodales Embedding-Modell")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("Google EmbeddingGemma 2 (Q8_0) ist das Herzstück von CortexRAG. Es wandelt Lehrbuchtexte und Abbildungen in 768-dimensionale Vektoren direkt auf deiner Metal-GPU um.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Google EmbeddingGemma 2")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Text-Backbone (~310 MB) + Vision-Projektor (~555 MB)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.embeddingGemmaStatus.isReady {
                        InfoPill(text: "Installiert", icon: "checkmark", tint: Theme.success)
                    } else {
                        InfoPill(text: "Download erforderlich", icon: "arrow.down.circle", tint: Theme.warning)
                    }
                }

                if vm.embeddingGemmaStatus.isReady {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(Theme.success)
                        Text("Modell-Dateien sind vorhanden und sofort einsatzbereit.")
                            .font(.system(size: 12))
                    }
                    .padding(.top, 4)
                } else {
                    if vm.isDownloadingEmbeddingModel {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: vm.embeddingDownloadProgress)
                                .progressViewStyle(.linear)
                            HStack {
                                Text(vm.embeddingDownloadStatusText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(vm.embeddingDownloadProgress * 100)) %")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            }
                        }
                    } else {
                        Button {
                            vm.startEmbeddingModelDownload()
                        } label: {
                            Label("EmbeddingGemma 2 herunterladen (~865 MB)", systemImage: "arrow.down.circle.fill")
                        }
                        .glassButton(prominent: true)
                        .controlSize(.regular)
                    }
                }
            }
            .padding(16)
            .glassSurface(cornerRadius: 14)
        }
    }

    // MARK: - Step 2: Reranker

    private var stepReranker: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Neuronaler Reranker (Optional)")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("Ein Cross-Encoder sortiert die relevantesten Vektortreffer nach der Suche per Cross-Attention nochmals präzise nach. Besonders empfohlen für dicke Lehrbücher mit vielen ähnlichen Abschnitten.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            VStack(spacing: 10) {
                rerankerOption(.none, title: "Kein Reranker (Standard)", desc: "Blitzschneller Start, minimaler RAM- und Akkuverbrauch (0 MB Zusatzdownload).")
                rerankerOption(.bgeM3, title: "BGE-Reranker v2 M3 (~635 MB)", desc: "Hervorragend für Fachbegriffe in Wissenschaft & Technik. Q8_0 quantisiert.")
                rerankerOption(.qwen3, title: "Qwen3 Reranker 0.6B (~639 MB)", desc: "Extrem schnell und präzise auf Apple Silicon Metal. Q8_0 quantisiert.")
            }
        }
    }

    private func rerankerOption(_ model: NeuralRerankerModel, title: String, desc: String) -> some View {
        Button {
            selectedReranker = model
            vm.settings.neuralReranker = model
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selectedReranker == model ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selectedReranker == model ? Theme.accent : .secondary)
                    .font(.system(size: 16))
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(title).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if model != .none {
                            if model.isDownloaded {
                                InfoPill(text: "Geladen", icon: "checkmark", tint: Theme.success)
                            } else if vm.rerankerDownloads[model] != nil {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    Text(desc).font(.system(size: 11.5)).foregroundStyle(.secondary)

                    if model != .none && !model.isDownloaded && selectedReranker == model {
                        HStack {
                            Button("Reranker jetzt herunterladen") {
                                vm.downloadReranker(model)
                            }
                            .glassButton(prominent: false)
                            .controlSize(.small)
                            .padding(.top, 4)
                            Spacer()
                        }
                    }
                }
            }
            .padding(14)
            .contentCard(highlighted: selectedReranker == model)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 3: LLM Endpoint

    private var stepLLM: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("KI-Sprachmodell / LLM (Optional)")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Text("Für zusammenfassende Antworten mit Quellenangaben („KI-Synthese“). Du kannst lokale Tools wie Ollama oder LM Studio nutzen oder entfernte Server wie oMLX über Tailscale.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }

            VStack(alignment: .leading, spacing: 14) {
                Picker("Voreinstellung", selection: $selectedPreset) {
                    Text("oMLX Server (Tailscale / LAN)").tag(LLMProviderPreset.omlx)
                    Text("LM Studio (Lokal)").tag(LLMProviderPreset.lmStudio)
                    Text("Benutzerdefiniert / Ollama").tag(LLMProviderPreset.customOpenAI)
                }
                .pickerStyle(.menu)
                .onChange(of: selectedPreset) { newPreset in
                    switch newPreset {
                    case .omlx:
                        endpointURL = "http://remote-host.local:8072/v1"
                        apiKey = "admin"
                    case .lmStudio:
                        endpointURL = "http://localhost:1234/v1"
                        apiKey = ""
                    case .customOpenAI:
                        endpointURL = "http://localhost:11434/v1"
                        apiKey = ""
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Endpunkt-URL").font(.system(size: 11.5, weight: .medium))
                    TextField("http://...", text: $endpointURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API-Schlüssel (optional)").font(.system(size: 11.5, weight: .medium))
                    SecureField("admin", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                HStack {
                    Button {
                        testConnection()
                    } label: {
                        if isTestingConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("Verbindung testen", systemImage: "network")
                        }
                    }
                    .glassButton(prominent: false)
                    .controlSize(.small)
                    .disabled(isTestingConnection || endpointURL.isEmpty)

                    if let status = testStatus {
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(status.contains("✓") ? Theme.success : Theme.warning)
                    }
                }
            }
            .padding(16)
            .glassSurface(cornerRadius: 14)
        }
    }

    private func testConnection() {
        isTestingConnection = true
        testStatus = "Verbinde ..."
        Task {
            // Apply fields temporarily to settings
            vm.settings.llmEndpointURL = endpointURL
            vm.settings.llmApiKey = apiKey
            vm.settings.llmProviderPreset = selectedPreset
            await vm.pingLLMEndpoint()
            isTestingConnection = false
            if let ping = vm.llmPingResult, ping.ok {
                testStatus = "✓ Erreichbar (\(ping.models.count) Modell(e) gefunden)"
                if let first = ping.models.first, vm.settings.llmSelectedModel.isEmpty {
                    vm.selectModel(first.id)
                }
            } else {
                testStatus = "Nicht erreichbar (kann später eingerichtet werden)"
            }
        }
    }

    // MARK: - Step 4: Completion

    private var stepCompletion: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.success)
                .padding(.top, 10)

            VStack(spacing: 6) {
                Text("CortexRAG ist startklar!")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Deine Bibliothek und Embedding-Pipeline sind bereit. Ziehe einfach PDFs in die Seitenleiste oder importiere Ordner.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            VStack(alignment: .leading, spacing: 10) {
                summaryRow("Speicherort", CortexPaths.appSupport.lastPathComponent, ok: true)
                summaryRow("Embedding-Engine", vm.embeddingGemmaStatus.isReady ? "EmbeddingGemma 2 bereit" : "Manuell / ausstehend", ok: vm.embeddingGemmaStatus.isReady)
                summaryRow("Reranker", selectedReranker == .none ? "Deaktiviert (Schnell)" : selectedReranker.displayName, ok: true)
                summaryRow("Sprachmodell", endpointURL.isEmpty ? "Später" : selectedPreset.rawValue, ok: true)
            }
            .padding(16)
            .glassSurface(cornerRadius: 14)
            .frame(maxWidth: 420)

            Button {
                vm.completeOnboarding()
            } label: {
                Text("CortexRAG starten")
                    .frame(minWidth: 180)
            }
            .glassButton(prominent: true)
            .controlSize(.large)
            .padding(.top, 10)
        }
    }

    private func summaryRow(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 12)).foregroundStyle(.secondary)
            Image(systemName: ok ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(ok ? Theme.success : .secondary)
                .font(.system(size: 12))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if currentStep > 0 {
                Button("Zurück") {
                    withAnimation(Theme.quick) { currentStep -= 1 }
                }
                .buttonStyle(.borderless)
            }

            Spacer()

            if currentStep < 4 {
                Button("Weiter") {
                    withAnimation(Theme.quick) { currentStep += 1 }
                }
                .glassButton(prominent: true)
                .controlSize(.regular)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }
}
