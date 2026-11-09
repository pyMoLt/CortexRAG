import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct DiscoveredLLMModel: Codable, Equatable, Identifiable, Hashable, Sendable {
    public var id: String
    public var ownedBy: String
    public var isLoaded: Bool
    public var contextLength: Int?
    public var estimatedSizeGB: Double?

    public init(
        id: String,
        ownedBy: String = "local",
        isLoaded: Bool = false,
        contextLength: Int? = nil,
        estimatedSizeGB: Double? = nil
    ) {
        self.id = id
        self.ownedBy = ownedBy
        self.isLoaded = isLoaded
        self.contextLength = contextLength
        self.estimatedSizeGB = estimatedSizeGB
    }

    /// True for models that cannot answer chat requests (rerankers, embeddings, speech, tokenizers).
    public var isChatModel: Bool {
        let n = id.lowercased()
        return !["rerank", "embed", "tts", "voice", "whisper", "chatterbox", "tokenizer", "voxcpm", "omnivoice", "asr", "stt"].contains { n.contains($0) }
    }

    /// Best default chat model: loaded ones first, then the largest Qwen/Gemma/Llama by name.
    public static func preferredChatModel(in models: [DiscoveredLLMModel]) -> DiscoveredLLMModel? {
        let chat = models.filter(\.isChatModel)
        if let loaded = chat.first(where: \.isLoaded) { return loaded }
        func size(_ m: DiscoveredLLMModel) -> Double {
            let n = m.id.lowercased()
            guard let r = n.range(of: #"(\d+(\.\d+)?)b"#, options: .regularExpression) else { return 0 }
            return Double(n[r].dropLast()) ?? 0
        }
        return chat.max { size($0) < size($1) } ?? chat.first
    }

    public var displayLabel: String {
        var parts = [id]
        if let gb = estimatedSizeGB, gb > 0 {
            parts.append(String(format: "%.1f GB", gb))
        }
        if isLoaded {
            parts.append("Geladen")
        }
        return parts.joined(separator: " • ")
    }
}

public struct LLMPingResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var latencyMs: Double
    public var endpointURL: String
    public var models: [DiscoveredLLMModel]
    public var message: String
    /// Set when the configured endpoint fails but a corrected one (e.g. http instead of https) answers.
    public var suggestedEndpointURL: String?

    public init(
        ok: Bool,
        latencyMs: Double,
        endpointURL: String,
        models: [DiscoveredLLMModel] = [],
        message: String,
        suggestedEndpointURL: String? = nil
    ) {
        self.suggestedEndpointURL = suggestedEndpointURL
        self.ok = ok
        self.latencyMs = latencyMs
        self.endpointURL = endpointURL
        self.models = models
        self.message = message
    }
}

public struct AISynthesisCitation: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { index }
    public var index: Int
    public var chunkID: String
    public var documentID: String
    public var documentTitle: String
    public var documentPath: String
    public var pageNumber: Int
    public var breadcrumb: String
    public var snippet: String

    public init(
        index: Int,
        chunkID: String,
        documentID: String,
        documentTitle: String,
        documentPath: String,
        pageNumber: Int,
        breadcrumb: String,
        snippet: String
    ) {
        self.index = index
        self.chunkID = chunkID
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.documentPath = documentPath
        self.pageNumber = pageNumber
        self.breadcrumb = breadcrumb
        self.snippet = snippet
    }
}

public struct AISynthesisStreamState: Codable, Equatable, Sendable {
    public var isGenerating: Bool
    public var rawText: String
    public var thinkingText: String
    public var answerText: String
    public var modelUsed: String
    public var latencyMs: Double
    public var citations: [AISynthesisCitation]
    public var errorMessage: String?
    public var fullPrompt: String?
    /// Images sent with this round's question; replayed identically in follow-ups so the server can reuse its cache.
    public var promptImages: [CortexLLMService.PromptImage]
    /// Server-reported prompt size, the part served from the server's prompt cache, and time to the first token.
    public var promptTokens: Int?
    public var cachedPromptTokens: Int?
    public var firstTokenMs: Double?

    public init(
        isGenerating: Bool = false,
        rawText: String = "",
        thinkingText: String = "",
        answerText: String = "",
        modelUsed: String = "",
        latencyMs: Double = 0,
        citations: [AISynthesisCitation] = [],
        errorMessage: String? = nil,
        fullPrompt: String? = nil,
        promptImages: [CortexLLMService.PromptImage] = [],
        promptTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        firstTokenMs: Double? = nil
    ) {
        self.promptImages = promptImages
        self.promptTokens = promptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.firstTokenMs = firstTokenMs
        self.isGenerating = isGenerating
        self.rawText = rawText
        self.thinkingText = thinkingText
        self.answerText = answerText
        self.modelUsed = modelUsed
        self.latencyMs = latencyMs
        self.citations = citations
        self.errorMessage = errorMessage
        self.fullPrompt = fullPrompt
    }
}

/// One earlier question/answer pair of a follow-up conversation (answer without thinking).
public struct ConversationExchange: Codable, Equatable, Sendable {
    public var question: String
    public var answer: String
    public var fullPrompt: String?
    /// Exactly what was sent and generated in that round – replaying them unchanged keeps the conversation prefix
    /// identical, so the local server answers follow-ups from its prompt cache (0.25 s instead of ~1 s per 3 000 tokens).
    public var promptImages: [CortexLLMService.PromptImage]
    public var rawAnswer: String?
    public init(question: String, answer: String, fullPrompt: String? = nil,
                promptImages: [CortexLLMService.PromptImage] = [], rawAnswer: String? = nil) {
        self.question = question
        self.answer = answer
        self.fullPrompt = fullPrompt
        self.promptImages = promptImages
        self.rawAnswer = rawAnswer
    }
}

public final class CortexLLMService: @unchecked Sendable {
    public static let shared = CortexLLMService()

    private init() {}

    /// Normalizes a base URL to always point to the `/v1` root (e.g. `http://127.0.0.1:8000/v1`)
    public static func normalizedV1BaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/v1/chat/completions") {
            trimmed = String(trimmed.dropLast("/chat/completions".count))
        } else if trimmed.hasSuffix("/chat/completions") {
            trimmed = String(trimmed.dropLast("/chat/completions".count))
            if !trimmed.hasSuffix("/v1") {
                trimmed += "/v1"
            }
        } else if !trimmed.hasSuffix("/v1") {
            trimmed += "/v1"
        }
        return trimmed
    }

    private static func makeRequest(url: URL, method: String = "GET", apiKey: String, timeout: TimeInterval = 30) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanKey.isEmpty {
            req.setValue("Bearer \(cleanKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Pings the OpenAI-compatible / oMLX endpoint, measures latency, and lists available models
    public func pingAndDiscoverModels(endpointURL: String, apiKey: String) async -> LLMPingResult {
        let base = Self.normalizedV1BaseURL(endpointURL)
        guard let modelsURL = URL(string: "\(base)/models") else {
            return LLMPingResult(ok: false, latencyMs: 0, endpointURL: base, message: "Ungültige Endpunkt-URL: \(base)")
        }

        let start = DispatchTime.now()
        let req = Self.makeRequest(url: modelsURL, method: "GET", apiKey: apiKey, timeout: 8)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            let roundedMs = (ms * 10).rounded() / 10

            guard let http = response as? HTTPURLResponse else {
                return LLMPingResult(ok: false, latencyMs: roundedMs, endpointURL: base, message: "Keine gültige HTTP-Antwort erhalten.")
            }

            if http.statusCode == 401 || http.statusCode == 403 {
                return LLMPingResult(
                    ok: false,
                    latencyMs: roundedMs,
                    endpointURL: base,
                    message: "Authentifizierung fehlgeschlagen (HTTP \(http.statusCode)). Bitte API-Key prüfen (bei oMLX meist 'admin')."
                )
            }

            guard (200...299).contains(http.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? ""
                return LLMPingResult(
                    ok: false,
                    latencyMs: roundedMs,
                    endpointURL: base,
                    message: "HTTP Fehler \(http.statusCode): \(errBody.prefix(160))"
                )
            }

            var discovered: [DiscoveredLLMModel] = []
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let arr = json["data"] as? [[String: Any]] {
                for item in arr {
                    if let id = item["id"] as? String {
                        let owner = (item["owned_by"] as? String) ?? "local"
                        let ctx = item["max_model_len"] as? Int
                        discovered.append(DiscoveredLLMModel(id: id, ownedBy: owner, contextLength: ctx))
                    }
                }
            }

            // Enrich with oMLX `/v1/models/status` if available
            if let statusURL = URL(string: "\(base)/models/status") {
                let statusReq = Self.makeRequest(url: statusURL, method: "GET", apiKey: apiKey, timeout: 4)
                if let (stData, stResp) = try? await URLSession.shared.data(for: statusReq),
                   let stHttp = stResp as? HTTPURLResponse, stHttp.statusCode == 200,
                   let stJSON = try? JSONSerialization.jsonObject(with: stData) as? [String: Any],
                   let stModels = stJSON["models"] as? [[String: Any]] {
                    var statusMap: [String: (loaded: Bool, sizeGB: Double?)] = [:]
                    for m in stModels {
                        if let mid = m["id"] as? String {
                            let loaded = (m["loaded"] as? Bool) ?? false
                            let bytes = (m["estimated_size"] as? Double) ?? 0
                            let gb = bytes > 0 ? bytes / (1024 * 1024 * 1024) : nil
                            statusMap[mid] = (loaded, gb)
                        }
                    }
                    discovered = discovered.map { d in
                        var copy = d
                        if let extra = statusMap[d.id] {
                            copy.isLoaded = extra.loaded
                            copy.estimatedSizeGB = extra.sizeGB
                        }
                        return copy
                    }
                }
            }

            let countStr = discovered.isEmpty ? "Keine Modelle gelistet" : "\(discovered.count) Modell(e) bereit"
            return LLMPingResult(
                ok: true,
                latencyMs: roundedMs,
                endpointURL: base,
                models: discovered,
                message: "Verbunden (\(roundedMs) ms) • \(countStr)"
            )
        } catch {
            // Common misconfiguration: "https://" for a server that only speaks plain HTTP (TLS handshake fails).
            if base.hasPrefix("https://"), Self.isTLSFailure(error) {
                let httpBase = "http://" + base.dropFirst("https://".count)
                if let url = URL(string: "\(httpBase)/models"),
                   let (_, resp) = try? await URLSession.shared.data(for: Self.makeRequest(url: url, method: "GET", apiKey: apiKey, timeout: 5)),
                   let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    return LLMPingResult(
                        ok: false, latencyMs: 0, endpointURL: base,
                        message: "Der Server antwortet nur über HTTP, nicht HTTPS. Endpunkt auf http:// umstellen.",
                        suggestedEndpointURL: httpBase
                    )
                }
            }
            return LLMPingResult(
                ok: false,
                latencyMs: 0,
                endpointURL: base,
                message: "Verbindung fehlgeschlagen: \(error.localizedDescription)"
            )
        }
    }

    static func isTLSFailure(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected].contains(e.code)
    }

    /// Sends a short test prompt to verify generation capability
    public func testGeneration(endpointURL: String, apiKey: String, model: String) async -> (ok: Bool, responseText: String, latencyMs: Double) {
        let base = Self.normalizedV1BaseURL(endpointURL)
        guard let url = URL(string: "\(base)/chat/completions") else {
            return (false, "Ungültige URL", 0)
        }
        let start = DispatchTime.now()
        var req = Self.makeRequest(url: url, method: "POST", apiKey: apiKey, timeout: 60)
        let payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": "Antworte bitte in einem einzigen kurzen deutschen Satz: Bestätige, dass die Verbindung zu CortexRAG aktiv ist."]
            ],
            "max_tokens": 80,
            "temperature": 0.1,
            "stream": false
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            let roundedMs = (ms * 10).rounded() / 10
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let errStr = String(data: data, encoding: .utf8) ?? "Unbekannter Fehler"
                return (false, "HTTP Fehler: \(errStr.prefix(200))", roundedMs)
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let first = choices.first,
               let msg = first["message"] as? [String: Any],
               let content = msg["content"] as? String {
                let parsed = Self.splitThinkingAndAnswer(content)
                let finalAnswer = parsed.answer.isEmpty ? content : parsed.answer
                return (true, finalAnswer.trimmingCharacters(in: .whitespacesAndNewlines), roundedMs)
            }
            return (false, "Antwort konnte nicht gelesen werden.", roundedMs)
        } catch {
            return (false, "Fehler: \(error.localizedDescription)", 0)
        }
    }

    /// Streams a grounded RAG synthesis answer from the configured OpenAI-compatible / oMLX endpoint
    public func streamRAGSynthesis(
        query: String,
        chunks: [SearchResultItem],
        settings: CortexSettings,
        history: [ConversationExchange] = [],
        newSourcesStartIndex: Int = 0,
        useAllChunks: Bool = false,
        allowImages: Bool = true,
        onUpdate: @escaping @Sendable (AISynthesisStreamState) -> Void
    ) async {
        // Follow-ups pass a fixed, already numbered source list so that [n] stays stable across turns.
        let topChunks = useAllChunks ? chunks : Array(chunks.prefix(max(1, settings.maxChunksForLLM)))
        let citations: [AISynthesisCitation] = topChunks.enumerated().map { idx, ch in
            AISynthesisCitation(
                index: idx + 1,
                chunkID: ch.chunkID,
                documentID: ch.documentID,
                documentTitle: Self.sanitizeTitle(ch.documentTitle),
                documentPath: ch.documentPath,
                pageNumber: ch.pageNumber,
                breadcrumb: Self.sanitizeTitle(ch.breadcrumb),
                snippet: String(CortexTextSanitizer.cleanText(ch.matchedContent).prefix(220))
            )
        }

        let modelName = settings.llmSelectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelName.isEmpty else {
            onUpdate(AISynthesisStreamState(
                isGenerating: false,
                modelUsed: "Kein Modell gewählt",
                citations: citations,
                errorMessage: "Bitte in den Einstellungen unter 'KI-Synthese & Endpunkt' ein Modell auswählen."
            ))
            return
        }

        guard !topChunks.isEmpty else {
            onUpdate(AISynthesisStreamState(
                isGenerating: false,
                modelUsed: modelName,
                citations: [],
                errorMessage: "Keine passenden Textabschnitte für die Zusammenfassung gefunden."
            ))
            return
        }

        // Figures go along as images when the model can see (vision models such as Qwen3.5/3.6).
        // For follow-ups, only attach newly added figures so we don't duplicate previous turns' vision tokens.
        // A follow-up that adds no sources ("kürzer", "als Tabelle") sends no source block and no images at all; resending
        // everything grew the prompt by thousands of tokens and the images by ~0.3 s each.
        let deltaChunks = history.isEmpty
            ? topChunks
            : Array(topChunks.dropFirst(min(max(0, newSourcesStartIndex), topChunks.count)))
        let images = (allowImages && !Self.isTextOnlyModel(modelName))
            ? Self.imagesForPrompt(history.isEmpty ? topChunks : deltaChunks, max: settings.maxImagesForLLM)
            : []

        // Explicit, last-position language instruction: a general rule in the system prompt is easily
        // overridden by German sources and instructions.
        let target: ContentLanguage? = {
            switch settings.answerLanguage {
            case .german: return .german
            case .english: return .english
            case .auto: return LanguageRules.detectLanguage(query)
            }
        }()
        let languageLine: String
        switch target {
        case .english: languageLine = "\n\nAnswer in English (the sources may be German; translate the facts accurately)."
        case .german: languageLine = "\n\nAntworte auf Deutsch."
        default: languageLine = ""
        }

        let userPrompt: String
        if history.isEmpty {
            // Turn 1: Initial RAG synthesis with all primary sources
            var contextBlocks: [String] = []
            for (idx, ch) in topChunks.enumerated() {
                if let fig = ch.figure {
                    var block = "[\(idx + 1)] Abbildung: \(fig.label) – \(fig.caption) | Dokument: \(Self.sanitizeTitle(ch.documentTitle)) | Seite \(ch.pageNumber)\n"
                    if images.contains(where: { $0.index == idx + 1 }) { block += "(Das Bild ist unten als „Bild zu Quelle [\(idx + 1)]“ beigefügt.)\n" }
                    let context = CortexTextSanitizer.cleanText(fig.surroundingContext)
                    if !context.isEmpty { block += "Text auf der Seite: \(context.prefix(500))\n" }
                    contextBlocks.append(block)
                    continue
                }
                var block = "[\(idx + 1)] Dokument: \(Self.sanitizeTitle(ch.documentTitle)) | Seite \(ch.pageNumber) | Kapitel: \(Self.sanitizeTitle(ch.breadcrumb))\n"
                if images.contains(where: { $0.index == idx + 1 }) { block += "(Eine Abbildung dieser Seite ist als „Bild zu Quelle [\(idx + 1)]“ beigefügt.)\n" }
                let cleanBefore = CortexTextSanitizer.cleanText(ch.contextBefore)
                if !cleanBefore.isEmpty { block += "Kontext davor: \(cleanBefore.prefix(350))\n" }
                block += "Hauptabschnitt:\n\(CortexTextSanitizer.cleanText(ch.matchedContent))\n"
                let cleanAfter = CortexTextSanitizer.cleanText(ch.contextAfter)
                if !cleanAfter.isEmpty { block += "Kontext danach: \(cleanAfter.prefix(350))\n" }
                contextBlocks.append(block)
            }

            userPrompt = """
Frage / Suchbegriff: \(query)

Verfügbare Quellen aus der indizierten Fachbibliothek:
\(contextBlocks.joined(separator: "\n---\n"))

Aufgabe:
Beantworte die Frage präzise, übersichtlich und fachlich fundiert anhand der obigen Quellen. \
Hebe wichtige Angaben (wie Dosierungen, Kriterien, Wirkmechanismen oder Definitionen) strukturiert hervor und verweise mit [1], [2] etc. auf die jeweilige Quelle.
\(images.isEmpty ? "" : "Einige Quellen sind als Bild beigefügt (Diagramme, Tabellen, Schemata): lies Werte, Beschriftungen und Zusammenhänge daraus ab und zitiere sie mit ihrer Quellennummer.\n")Formatiere die Antwort in Markdown: kurze Einleitung, bei Bedarf Zwischenüberschriften (###), Aufzählungen und – für Vergleiche – Tabellen. Fett (**…**) nur für Schlüsselbegriffe.\(languageLine)
"""
        } else {
            // Follow-up: Append-only delta prompt structure preserving the KV cache of earlier turns!
            if !deltaChunks.isEmpty {
                var deltaBlocks: [String] = []
                for (offset, ch) in deltaChunks.enumerated() {
                    let idx = newSourcesStartIndex + offset
                    if let fig = ch.figure {
                        var block = "[\(idx + 1)] Abbildung: \(fig.label) – \(fig.caption) | Dokument: \(Self.sanitizeTitle(ch.documentTitle)) | Seite \(ch.pageNumber)\n"
                        if images.contains(where: { $0.index == idx + 1 }) { block += "(Das Bild ist unten als „Bild zu Quelle [\(idx + 1)]“ beigefügt.)\n" }
                        let context = CortexTextSanitizer.cleanText(fig.surroundingContext)
                        if !context.isEmpty { block += "Text auf der Seite: \(context.prefix(500))\n" }
                        deltaBlocks.append(block)
                        continue
                    }
                    var block = "[\(idx + 1)] Dokument: \(Self.sanitizeTitle(ch.documentTitle)) | Seite \(ch.pageNumber) | Kapitel: \(Self.sanitizeTitle(ch.breadcrumb))\n"
                    if images.contains(where: { $0.index == idx + 1 }) { block += "(Eine Abbildung dieser Seite ist als „Bild zu Quelle [\(idx + 1)]“ beigefügt.)\n" }
                    let cleanBefore = CortexTextSanitizer.cleanText(ch.contextBefore)
                    if !cleanBefore.isEmpty { block += "Kontext davor: \(cleanBefore.prefix(350))\n" }
                    block += "Hauptabschnitt:\n\(CortexTextSanitizer.cleanText(ch.matchedContent))\n"
                    let cleanAfter = CortexTextSanitizer.cleanText(ch.contextAfter)
                    if !cleanAfter.isEmpty { block += "Kontext danach: \(cleanAfter.prefix(350))\n" }
                    deltaBlocks.append(block)
                }

                userPrompt = """
Frage / Nachfrage: \(query)

Ergänzende Quellen für diese Nachfrage:
\(deltaBlocks.joined(separator: "\n---\n"))

Aufgabe:
Dies ist eine Nachfrage im laufenden Gespräch. Beantworte die Nachfrage präzise und fachlich fundiert anhand der bisherigen Quellen sowie der oben genannten ergänzenden Quellen. \
Wiederhole bereits beantwortete Aspekte nicht unnötig und nutze bei Belegen dieselbe Quellennummerierung [1], [2], [3]...
\(images.isEmpty ? "" : "Neue Quellen sind teilweise als Bild beigefügt: lies relevante Details direkt daraus ab.\n")Formatiere die Antwort in Markdown: prägnant, bei Bedarf Aufzählungen oder Tabellen. Fett (**…**) nur für Schlüsselbegriffe.\(languageLine)
"""
            } else {
                userPrompt = """
Frage / Nachfrage: \(query)

Aufgabe:
Dies ist eine Nachfrage im laufenden Gespräch. Beantworte die Nachfrage präzise und knapp anhand der bereits vorliegenden Quellen und des bisherigen Gesprächsverlaufs. \
Wiederhole bereits beantwortete Aspekte nicht unnötig und nutze dieselbe Quellennummerierung [1], [2]... für Belege.\(languageLine)
"""
            }
        }

        let base = Self.normalizedV1BaseURL(settings.llmEndpointURL)
        guard let url = URL(string: "\(base)/chat/completions") else {
            onUpdate(AISynthesisStreamState(
                isGenerating: false,
                modelUsed: modelName,
                citations: citations,
                errorMessage: "Ungültige Endpunkt-URL: \(base)",
                fullPrompt: userPrompt,
                promptImages: images
            ))
            return
        }

        let start = DispatchTime.now()
        onUpdate(AISynthesisStreamState(
            isGenerating: true,
            rawText: "",
            thinkingText: "",
            answerText: "",
            modelUsed: modelName,
            latencyMs: 0,
            citations: citations,
            errorMessage: nil,
            fullPrompt: userPrompt,
                promptImages: images
        ))

        var systemPrompt = settings.llmSystemPrompt + "\n\n" + settings.answerLanguage.instruction
        if !settings.enableThinking {
            systemPrompt += "\n\nWICHTIG: Antworte direkt und ohne jegliche Denkschritte oder <think>-Tags. Starte unmittelbar mit der sachlichen Antwort."
        }

        var messages: [[String: Any]] = [
            ["role": "system", "content": systemPrompt]
        ]
        // Replay historical turns with their exact original prompt to maximize KV cache hits on local servers.
        for ex in history {
            messages.append(["role": "user", "content": Self.userContent(ex.fullPrompt ?? ex.question, images: ex.promptImages)])
            // The unparsed model output is what the server generated; the cleaned answer would differ in details.
            messages.append(["role": "assistant", "content": ex.rawAnswer.flatMap { $0.contains("<think>") ? nil : $0 } ?? ex.answer])
        }
        messages.append(["role": "user", "content": Self.userContent(userPrompt, images: images)])

        var req = Self.makeRequest(url: url, method: "POST", apiKey: settings.llmApiKey, timeout: 120)
        var payload: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": settings.llmTemperature,
            "max_tokens": settings.enableThinking ? max(settings.llmMaxTokens, 3500) : settings.llmMaxTokens,
            "stream": true,
            "enable_thinking": settings.enableThinking,
            "keep_alive": "15m",
            "cache_prompt": true,
            "stream_options": ["include_usage": true]
        ]
        if !settings.enableThinking {
            payload["chat_template_kwargs"] = ["thinking": false]
            payload["reasoning_effort"] = "none"
        }

        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                // A model without vision rejects image parts: remember it and answer from text only.
                if !images.isEmpty {
                    Self.markTextOnly(modelName)
                    await streamRAGSynthesis(query: query, chunks: chunks, settings: settings, history: history,
                                             newSourcesStartIndex: newSourcesStartIndex,
                                             useAllChunks: useAllChunks, allowImages: false, onUpdate: onUpdate)
                    return
                }
                var errorLines = ""
                for try await line in bytes.lines {
                    errorLines += line
                    if errorLines.count > 300 { break }
                }
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
                onUpdate(AISynthesisStreamState(
                    isGenerating: false,
                    modelUsed: modelName,
                    latencyMs: (ms * 10).rounded() / 10,
                    citations: citations,
                    errorMessage: "Endpunkt-Fehler (HTTP \(http.statusCode)): \(errorLines)",
                    fullPrompt: userPrompt,
                promptImages: images
                ))
                return
            }

            var accumulatedRaw = ""
            var accumulatedReasoning = ""
            var promptTokens: Int?
            var cachedTokens: Int?
            var firstTokenMs: Double?

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let dataStr = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if dataStr == "[DONE]" { break }

                guard let jsonData = dataStr.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }
                if let usage = obj["usage"] as? [String: Any] {
                    promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                    cachedTokens = (usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int ?? cachedTokens
                }
                guard let choices = obj["choices"] as? [[String: Any]], let first = choices.first else { continue }

                if let delta = first["delta"] as? [String: Any] {
                    if let rChunk = (delta["reasoning_content"] as? String) ?? (delta["reasoning"] as? String) {
                        accumulatedReasoning += rChunk
                    }
                    if let cChunk = delta["content"] as? String {
                        accumulatedRaw += cChunk
                    }
                    if firstTokenMs == nil, !accumulatedRaw.isEmpty || !accumulatedReasoning.isEmpty {
                        firstTokenMs = (Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0).rounded()
                    }
                } else if let msg = first["message"] as? [String: Any],
                          let fullContent = msg["content"] as? String {
                    accumulatedRaw = fullContent
                }

                let parsed = Self.splitThinkingAndAnswer(accumulatedRaw)
                let combinedThinking = [accumulatedReasoning, parsed.thinking]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

                onUpdate(AISynthesisStreamState(
                    isGenerating: true,
                    rawText: accumulatedRaw,
                    thinkingText: combinedThinking,
                    answerText: parsed.answer,
                    modelUsed: modelName,
                    latencyMs: (ms * 10).rounded() / 10,
                    citations: citations,
                    errorMessage: nil,
                    fullPrompt: userPrompt,
                    promptImages: images,
                    firstTokenMs: firstTokenMs
                ))
            }

            let finalParsed = Self.splitThinkingAndAnswer(accumulatedRaw)
            let finalThinking = [accumulatedReasoning, finalParsed.thinking]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

            var finalAnswer = finalParsed.answer
            if finalAnswer.isEmpty {
                // If model stopped inside thinking before closing, extract or fallback to raw
                finalAnswer = accumulatedRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            onUpdate(AISynthesisStreamState(
                isGenerating: false,
                rawText: accumulatedRaw,
                thinkingText: finalThinking,
                answerText: finalAnswer,
                modelUsed: modelName,
                latencyMs: (totalMs * 10).rounded() / 10,
                citations: citations,
                errorMessage: nil,
                fullPrompt: userPrompt,
                promptImages: images,
                promptTokens: promptTokens,
                cachedPromptTokens: cachedTokens,
                firstTokenMs: firstTokenMs
            ))
        } catch {
            if Task.isCancelled { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            onUpdate(AISynthesisStreamState(
                isGenerating: false,
                modelUsed: modelName,
                latencyMs: (ms * 10).rounded() / 10,
                citations: citations,
                errorMessage: Self.isTLSFailure(error) && base.hasPrefix("https://")
                    ? "TLS-Verbindung zu \(base) fehlgeschlagen. Spricht der Server nur HTTP? Dann in den Einstellungen „http://“ verwenden."
                    : "KI-Endpunkt nicht erreichbar (\(error.localizedDescription)). Läuft oMLX / LM Studio?",
                fullPrompt: userPrompt,
                promptImages: images
            ))
        }
    }

    // MARK: Images for vision models

    public struct PromptImage: Codable, Sendable, Equatable {
        public let index: Int
        public let path: String
    }

    /// Figure hits first (in rank order), then one figure of each text hit's page, at most `max`, no duplicates.
    public static func imagesForPrompt(_ chunks: [SearchResultItem], max: Int) -> [PromptImage] {
        guard max > 0 else { return [] }
        var out: [PromptImage] = []
        for (i, ch) in chunks.enumerated() where out.count < max {
            if let fig = ch.figure, FileManager.default.fileExists(atPath: fig.croppedImagePath) {
                out.append(PromptImage(index: i + 1, path: fig.croppedImagePath))
            }
        }
        for (i, ch) in chunks.enumerated() where out.count < max && ch.figure == nil {
            if let fig = ch.figuresOnPage.first, FileManager.default.fileExists(atPath: fig.croppedImagePath),
               !out.contains(where: { $0.path == fig.croppedImagePath }) {
                out.append(PromptImage(index: i + 1, path: fig.croppedImagePath))
            }
        }
        return out
    }

    /// OpenAI-style content: text, then each image labelled with its source number.
    static func userContent(_ text: String, images: [PromptImage]) -> Any {
        guard !images.isEmpty else { return text }
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for img in images {
            guard let url = jpegDataURL(img.path) else { continue }
            parts.append(["type": "text", "text": "Bild zu Quelle [\(img.index)]:"])
            parts.append(["type": "image_url", "image_url": ["url": url]])
        }
        return parts
    }

    /// Downscaled JPEG (max. 1024 px) as data URL – crops are rendered at print resolution.
    static func jpegDataURL(_ path: String, maxPixel: Int = 1024) -> String? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }

    private static let textOnlyLock = NSLock()
    nonisolated(unsafe) private static var textOnlyModels: Set<String> = []

    static func isTextOnlyModel(_ model: String) -> Bool {
        textOnlyLock.withLock { textOnlyModels.contains(model) }
    }

    static func markTextOnly(_ model: String) {
        _ = textOnlyLock.withLock { textOnlyModels.insert(model) }
    }

    /// Loads a model into the local oMLX server via `POST /v1/models/{model_id}/load`
    public func loadModelInServer(modelID: String, endpointURL: String, apiKey: String) async -> (ok: Bool, message: String) {
        let base = Self.normalizedV1BaseURL(endpointURL)
        let cleanID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        guard let url = URL(string: "\(base)/models/\(cleanID)/load") else {
            return (false, "Ungültige URL")
        }
        var req = Self.makeRequest(url: url, method: "POST", apiKey: apiKey, timeout: 60)
        req.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let err = String(data: data, encoding: .utf8) ?? "Fehler"
                return (false, "Laden fehlgeschlagen: \(err)")
            }
            return (true, "Modell '\(modelID)' erfolgreich geladen")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Unloads a model from the local oMLX server via `POST /v1/models/{model_id}/unload` to completely free unified memory / VRAM
    public func unloadModelInServer(modelID: String, endpointURL: String, apiKey: String) async -> (ok: Bool, message: String) {
        let base = Self.normalizedV1BaseURL(endpointURL)
        let cleanID = modelID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelID
        guard let url = URL(string: "\(base)/models/\(cleanID)/unload") else {
            return (false, "Ungültige URL")
        }
        var req = Self.makeRequest(url: url, method: "POST", apiKey: apiKey, timeout: 20)
        req.httpBody = Data("{}".utf8)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let err = String(data: data, encoding: .utf8) ?? "Fehler"
                return (false, "Entladen fehlgeschlagen: \(err)")
            }
            return (true, "Modell '\(modelID)' erfolgreich aus VRAM entladen")
        } catch {
            return (false, error.localizedDescription)
        }
    }

    /// Cleans up double-encoded UTF-8 artifacts in PDF titles for display
    public static func sanitizeTitle(_ raw: String) -> String {
        CortexTextSanitizer.displayTitle(raw)
    }

    /// Separates `<think>...</think>` or `Thinking Process:` blocks from the visible answer
    public static func splitThinkingAndAnswer(_ text: String) -> (thinking: String, answer: String) {
        // Some chat templates (Qwen 3.x) put the opening <think> into the prompt, so only </think> is streamed.
        if !text.contains("<think>"), let endRange = text.range(of: "</think>") {
            let thinkContent = String(text[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let answerContent = String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return (thinkContent, answerContent)
        }
        if text.contains("<think>") {
            if let startRange = text.range(of: "<think>") {
                if let endRange = text.range(of: "</think>") {
                    let thinkContent = String(text[startRange.upperBound..<endRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let before = String(text[..<startRange.lowerBound])
                    let after = String(text[endRange.upperBound...])
                    let answerContent = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)
                    return (thinkContent, answerContent)
                } else {
                    let thinkContent = String(text[startRange.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let before = String(text[..<startRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return (thinkContent, before)
                }
            }
        }

        if text.hasPrefix("Thinking Process:\n") || text.hasPrefix("Thinking Process:") {
            let lines = text.components(separatedBy: "\n")
            var thinkingLines: [String] = []
            var answerLines: [String] = []
            var isAnswer = false

            for line in lines {
                if !isAnswer && (line.starts(with: "## Antwort") || line.starts(with: "Antwort:") || line.starts(with: "Final Answer:") || line.starts(with: "Conclusion:")) {
                    isAnswer = true
                    continue
                }
                if isAnswer {
                    answerLines.append(line)
                } else {
                    thinkingLines.append(line)
                }
            }
            if !answerLines.isEmpty {
                return (thinkingLines.joined(separator: "\n"), answerLines.joined(separator: "\n"))
            }
        }

        return ("", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
