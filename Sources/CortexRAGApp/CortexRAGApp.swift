import SwiftUI
import AppKit
import CortexCore
import CortexEmbedders
import CortexVision
import CortexIPC

@MainActor
final class CortexAppDelegate: NSObject, NSApplicationDelegate {
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                AppViewModel.shared?.shutdownAndResetOnExit()
                NSApplication.shared.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }

        let settings = CortexSettingsManager.shared.settings
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        AppViewModel.applyAppearance(settings.appearanceMode)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppViewModel.shared?.shutdownAndResetOnExit()
    }
}

@main
struct CortexRAGMainApp: App {
    @NSApplicationDelegateAdaptor(CortexAppDelegate.self) private var appDelegate
    @State private var vm = AppViewModel()

    var body: some Scene {
        WindowGroup("CortexRAG", id: "main") {
            MainWorkspaceView(vm: vm)
                .frame(minWidth: 440, minHeight: 440)
                .tint(Theme.accent)
                .id(vm.settings.accentChoice)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1080, height: 740)
        .commands { CortexCommands(vm: vm) }

        Window("Reader", id: "reader") {
            ReaderWindowView(vm: vm)
                .tint(Theme.accent)
                .id(vm.settings.accentChoice)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 860)

        Settings {
            SettingsView(vm: vm)
                .tint(Theme.accent)
                .id(vm.settings.accentChoice)
        }

        MenuBarExtra(isInserted: Binding(get: { vm.settings.showMenuBarItem }, set: { v in
            // Only write real changes: @Observable notifies on every assignment, which would loop the scene graph.
            if vm.settings.showMenuBarItem != v { vm.settings.showMenuBarItem = v }
        })) {
            MenuBarContent(vm: vm)
        } label: {
            Image(systemName: vm.isDaemonActive ? "circle.hexagongrid.fill" : "circle.hexagongrid")
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Menu commands

struct CortexCommands: Commands {
    @Bindable var vm: AppViewModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("PDFs importieren …") { vm.importViaPanel() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandMenu("Ansicht") {
            Button("Fragen") { vm.activeTab = .ask }.keyboardShortcut("1", modifiers: .command)
            Button("Bibliothek") { vm.activeTab = .library }.keyboardShortcut("2", modifiers: .command)
            Button("Agenten") { vm.activeTab = .agents }.keyboardShortcut("3", modifiers: .command)
            Divider()
            Button(vm.settings.enableAISynthesis ? "KI-Antwort ausschalten" : "KI-Antwort einschalten") {
                vm.setAIEnabled(!vm.settings.enableAISynthesis)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            Button(vm.settings.agentAccessEnabled ? "Agenten-Zugriff sperren" : "Agenten-Zugriff erlauben") {
                vm.setAgentAccess(!vm.settings.agentAccessEnabled)
            }
        }
        CommandGroup(replacing: .help) {
            Button("Ersteinrichtungs-Assistent …") {
                vm.showSetupAssistant = true
            }
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Bindable var vm: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                CortexPrismSymbol(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CortexRAG").font(.system(size: 13, weight: .bold, design: .rounded))
                    Text("\(vm.documents.count) Dokumente · \(Int(vm.memoryUsageMB)) MB")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }

            Toggle(isOn: Binding(get: { vm.settings.agentAccessEnabled }, set: { vm.setAgentAccess($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Agenten-Zugriff").font(.system(size: 12.5, weight: .semibold))
                    Text(vm.isDaemonActive ? "CLI & MCP sind aktiv" : "CLI & MCP sind gesperrt")
                        .font(.system(size: 11)).foregroundStyle(vm.isDaemonActive ? Theme.success : .secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle("KI-Antwort bei Suche", isOn: Binding(get: { vm.settings.enableAISynthesis }, set: { vm.setAIEnabled($0) }))
                .toggleStyle(.switch)
                .font(.system(size: 12))

            if vm.settings.llmProfiles.count > 1 {
                Picker("KI-Server", selection: Binding(get: { vm.settings.activeLLMProfileID }, set: { vm.activateProfile($0) })) {
                    ForEach(vm.settings.llmProfiles) { p in Text(p.name).tag(p.id) }
                }
                .pickerStyle(.segmented)
                .font(.system(size: 12))
            }

            if !vm.settings.llmSelectedModel.isEmpty {
                Button {
                    vm.unloadActiveModel()
                } label: {
                    Label("Sprachmodell aus Speicher entladen", systemImage: "memorychip")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            }

            Divider()
            HStack {
                Button("Fenster öffnen") {
                    NSApp.setActivationPolicy(vm.settings.showDockIcon ? .regular : .accessory)
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                SettingsLink { Text("Einstellungen") }
                Button("Beenden") {
                    vm.shutdownAndResetOnExit()
                    NSApp.terminate(nil)
                }
            }
            .font(.system(size: 12))
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
    }
}

// MARK: - Brand mark

struct CortexPrismSymbol: View {
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(LinearGradient(colors: [Theme.accent2, Theme.accent], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: size * 0.13)
                .frame(width: size * 0.7, height: size * 0.7)
                .offset(x: -size * 0.13)
            Circle()
                .strokeBorder(LinearGradient(colors: [Theme.accent, Theme.thinking], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: size * 0.13)
                .frame(width: size * 0.7, height: size * 0.7)
                .offset(x: size * 0.13)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Main window

struct MainWorkspaceView: View {
    @Bindable var vm: AppViewModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(vm: vm)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            ZStack {
                AmbientBackground()
                Group {
                    switch vm.activeTab {
                    case .ask: AskView(vm: vm)
                    case .library: LibraryView(vm: vm)
                    case .agents: AgentsView(vm: vm)
                    }
                }
                .transition(.opacity)
            }
            .overlay(alignment: .top) { errorBanner }
            .overlay(alignment: .bottom) { toast }
            .animation(Theme.spring, value: vm.activeTab)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Bereich", selection: $vm.activeTab) {
                    ForEach(WorkspaceTab.allCases) { tab in
                        Label(LocalizedStringKey(tab.rawValue), systemImage: tab.icon).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 130, idealWidth: 260, maxWidth: 360)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                AgentAccessToolbarButton(vm: vm)
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Einstellungen (⌘,)")
            }
        }
        .onAppear {
            vm.openWindowAction = openWindow
            vm.openSettingsAction = { openSettings() }
        }
        .sheet(isPresented: $vm.showSetupAssistant) {
            SetupAssistantView(vm: vm)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = vm.errorBanner {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(err).font(.system(size: 12)).lineLimit(3)
                Spacer()
                Button { withAnimation { vm.errorBanner = nil } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassSurface(cornerRadius: 14, tint: Theme.warning)
            .padding(.horizontal, 24)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let text = vm.toast {
            Label(text, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassSurface(cornerRadius: 20)
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

struct AgentAccessToolbarButton: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Button {
            vm.setAgentAccess(!vm.settings.agentAccessEnabled)
            vm.showToast(vm.settings.agentAccessEnabled ? "Agenten-Zugriff aktiviert" : "Agenten-Zugriff gesperrt")
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(vm.isDaemonActive ? Theme.success : Color.secondary.opacity(0.6))
                    .frame(width: 7, height: 7)
                    .shadow(color: vm.isDaemonActive ? Theme.success : .clear, radius: 3)
                ViewThatFits(in: .horizontal) {
                    Text(vm.isDaemonActive ? "Agenten an" : "Agenten aus")
                        .font(.system(size: 11.5, weight: .semibold))
                    Text(vm.isDaemonActive ? "an" : "aus")
                        .font(.system(size: 11.5, weight: .semibold))
                }
            }
            .padding(.horizontal, 3)
        }
        .help("CLI- & MCP-Zugriff für KI-Agenten ein-/ausschalten (\(CortexPaths.socketPath))")
    }
}
