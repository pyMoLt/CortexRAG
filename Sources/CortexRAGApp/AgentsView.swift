import SwiftUI
import AppKit
import CortexCore
import CortexIPC

struct AgentsView: View {
    @Bindable var vm: AppViewModel
    @State private var pingText: String?
    @State private var isTesting = false
    @State private var copied: String?
    @State private var showUIEvents = false

    /// The CLI inside this app bundle (wherever the app lives, e.g. /Applications). Copying the app to another Mac is
    /// enough: the commands below then point to that copy, no project folder or extra install needed.
    private var cliPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/cortexrag-cli").path
    }

    /// macOS runs quarantined apps from Downloads under a random read-only path (App Translocation).
    private var isTranslocated: Bool { cliPath.contains("/AppTranslocation/") }

    private var mcpRegisterCommand: String { "mcp-client add cortexrag -- \"\(cliPath)\" mcp" }
    private var desktopJSON: String {
        """
        {
          "mcpServers": {
            "cortexrag": {
              "command": "\(cliPath)",
              "args": ["mcp"]
            }
          }
        }
        """
    }

    private var events: [AgentActivityEvent] {
        showUIEvents ? vm.agentEvents : vm.agentEvents.filter { $0.source != "ui" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                accessCard
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        setupCard
                        toolsCard
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        setupCard
                        toolsCard
                    }
                }
                activityCard
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }

    // MARK: Access switch

    private var accessCard: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill((vm.isDaemonActive ? Theme.success : Color.secondary).opacity(0.15))
                    .frame(width: 58, height: 58)
                Image(systemName: vm.isDaemonActive ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(vm.isDaemonActive ? Theme.success : .secondary)
                    .symbolEffect(.variableColor.iterative, isActive: vm.isDaemonActive)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(vm.isDaemonActive ? "KI-Agenten haben Zugriff" : "Agenten-Zugriff gesperrt")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Text(vm.isDaemonActive
                     ? "CLI und MCP beantworten Anfragen über \(CortexPaths.socketPath). Beende die App oder schalte hier ab, um den Zugriff zu sperren."
                     : "CLI- und MCP-Aufrufe werden abgelehnt. Es läuft nichts im Hintergrund.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 14) {
                    Toggle("Auswahl der Seitenleiste für Agenten verwenden", isOn: $vm.settings.shareSelectionWithAgents)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    if vm.isDaemonActive {
                        Button {
                            testConnection()
                        } label: {
                            if isTesting { ProgressView().controlSize(.small) } else { Label("Verbindung testen", systemImage: "bolt.horizontal") }
                        }
                        .glassButton()
                        .controlSize(.small)
                        if let pingText { InfoPill(text: LocalizedStringKey(pingText), tint: Theme.success, monospaced: true) }
                    }
                }
                .padding(.top, 4)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { vm.settings.agentAccessEnabled }, set: { vm.setAgentAccess($0) }))
                .toggleStyle(.switch)
                .controlSize(.large)
                .labelsHidden()
        }
        .padding(20)
        .glassSurface(cornerRadius: Theme.radiusLarge, tint: vm.isDaemonActive ? Theme.success : nil)
        .animation(Theme.spring, value: vm.isDaemonActive)
    }

    // MARK: Setup

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Einrichtung", subtitle: "Einmalig im jeweiligen Tool eintragen", icon: "link", tint: Theme.accent)
            snippet(title: "MCP Agent CLI", text: mcpRegisterCommand, hint: "Im Terminal ausführen")
            snippet(title: "Cursor · Windsurf · MCP Desktop", text: desktopJSON, hint: "In die MCP-Konfiguration einfügen")
            snippet(title: "CLI", text: "\"\(cliPath)\" search \"Raft Consensus\" --collection \"Distributed Systems\"", hint: "„help“ statt „search …“ zeigt alle Befehle")
            if isTranslocated {
                Label("Die App läuft aus einem temporären Ort (z. B. direkt aus „Downloads“ gestartet). Verschiebe CortexRAG in den Programme-Ordner und starte sie neu – sonst stimmt der Pfad oben nach dem nächsten Start nicht mehr.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassSurface(cornerRadius: Theme.radiusLarge)
    }

    private func snippet(title: String, text: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringKey(title)).font(.system(size: 12.5, weight: .semibold))
                Text(LocalizedStringKey(hint)).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.copy(text)
                    copied = title
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { if copied == title { copied = nil } }
                } label: {
                    Label(copied == title ? "Kopiert" : "Kopieren", systemImage: copied == title ? "checkmark" : "doc.on.doc")
                        .contentTransition(.symbolEffect(.replace))
                }
                .glassButton()
                .controlSize(.small)
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: Tools

    private var toolsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "MCP-Werkzeuge", subtitle: "Was ein Agent aufrufen kann", icon: "wrench.and.screwdriver", tint: Theme.thinking)
            ForEach([
                ("cortex_list_library", "Bibliothek, IDs & aktuelle Auswahl"),
                ("cortex_search_knowledge", "Textstellen & Bilder mit Seite & Kontext"),
                ("cortex_search_figures", "Abbildungen & Tabellen (PNG)"),
                ("cortex_get_page_figures", "Bilder einer Seite freistellen & abrufen"),
                ("cortex_expand_context", "Abschnitte um einen Treffer"),
                ("cortex_read_pages", "Seitenbereich im Volltext lesen"),
                ("cortex_get_document_overview", "Inhaltsverzeichnis einer PDF"),
                ("cortex_switch_engine", "Embedding-Engine wechseln")
            ], id: \.0) { tool in
                VStack(alignment: .leading, spacing: 1) {
                    Text(tool.0).font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    Text(LocalizedStringKey(tool.1)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(18)
        .frame(width: 300, alignment: .topLeading)
        .glassSurface(cornerRadius: Theme.radiusLarge)
    }

    // MARK: Activity

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Aktivität", subtitle: "Letzte Anfragen von Agenten und CLI", icon: "waveform.path.ecg", tint: Theme.figure)
                Toggle("Eigene Suchen zeigen", isOn: $showUIEvents)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                Button("Leeren") { vm.clearAgentEvents() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11.5))
                    .disabled(vm.agentEvents.isEmpty)
            }
            if events.isEmpty {
                Text("Noch keine Anfragen.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(events.prefix(60)) { ev in
                        HStack(spacing: 10) {
                            Text(ev.source.uppercased())
                                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(sourceTint(ev.source))
                                .frame(width: 34)
                                .padding(.vertical, 2)
                                .background(sourceTint(ev.source).opacity(0.12), in: Capsule())
                            VStack(alignment: .leading, spacing: 1) {
                                (Text(LocalizedStringKey(operationName(ev.operation))) + Text(verbatim: " · " + ev.query))
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(ev.scopeSummary)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(Date(timeIntervalSince1970: ev.timestamp).formatted(.dateTime.day().month(.twoDigits).hour().minute()))
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Text("\(ev.resultCount) Treffer · \(Int(ev.latencyMs)) ms")
                                    .font(.system(size: 10.5).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 7)
                        Divider().opacity(0.5)
                    }
                }
            }
        }
        .padding(18)
        .glassSurface(cornerRadius: Theme.radiusLarge)
    }

    private func sourceTint(_ s: String) -> Color {
        switch s {
        case "mcp": return Theme.thinking
        case "cli": return Theme.accent
        default: return .secondary
        }
    }

    private func operationName(_ op: String) -> String {
        switch op {
        case "search": return "Suche"
        case "figures": return "Abbildungen"
        case "expand": return "Kontext"
        case "toc_overview": return "Inhalt"
        case "read_pages": return "Seiten lesen"
        default: return op
        }
    }

    private func testConnection() {
        isTesting = true
        Task.detached {
            let start = DispatchTime.now()
            let ok = (try? CortexSocketClient.send(IPCRequest(action: .status, source: "ui-test")))?.ok == true
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            await MainActor.run {
                isTesting = false
                pingText = ok ? String(format: "OK · %.1f ms", ms) : "keine Antwort"
            }
        }
    }
}
