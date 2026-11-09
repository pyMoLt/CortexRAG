import SwiftUI
import AppKit
import CortexCore

struct AskView: View {
    @Bindable var vm: AppViewModel
    @FocusState private var searchFocused: Bool
    @FocusState private var resultsFocused: Bool
    @Namespace private var heroSpace
    /// Hit shown in the space-bar preview.
    @State private var peekItem: SearchResultItem?
    @State private var suppressNextHighlightScroll = false
    /// Answer round (question + turn) for which the view already jumped up to the answer once.
    @State private var answerJumpDone = ""
    @State private var keyMonitor: Any? = nil

    @State private var followUpOpen = false
    @State private var followUpText = ""
    @FocusState private var followUpFocused: Bool

    private var hasResults: Bool { !vm.lastSubmittedQuery.isEmpty }

    private var canFollowUp: Bool {
        let st = vm.synthesisState
        return vm.settings.enableAISynthesis && !st.isGenerating && !st.answerText.isEmpty && st.errorMessage == nil
    }

    private func sendFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        followUpText = ""
        followUpOpen = false
        followUpFocused = false
        vm.submitFollowUp(text)
    }

    private func closeFollowUp() {
        followUpOpen = false
        followUpText = ""
        followUpFocused = false
        resultsFocused = true
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasResults {
                searchHeader
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                resultsScroll
            } else {
                emptyState
            }
        }
        .animation(Theme.spring, value: hasResults)
        .onAppear {
            searchFocused = true
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    handleKeyDown(event)
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .overlay {
            if let peek = peekItem {
                GeometryReader { geo in
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                            .onTapGesture { closePeek() }
                        let padH: CGFloat = geo.size.width < 900 ? 12 : 24
                        let padV: CGFloat = geo.size.height < 700 ? 12 : 24
                        let targetW = max(420, min(1400, geo.size.width - padH * 2))
                        let targetH = max(360, min(960, geo.size.height - padV * 2))

                        PeekView(vm: vm, item: peek, onClose: closePeek, onStep: stepPeek)
                            .frame(width: targetW, height: targetH)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(Theme.quick, value: peekItem?.id)
        .onChange(of: vm.lastSubmittedQuery) { _, _ in
            peekItem = nil
            vm.highlightedResultID = nil
        }
        .onChange(of: vm.searchResults) { _, results in
            if !results.isEmpty && (vm.highlightedResultID == nil || !results.contains(where: { $0.id == vm.highlightedResultID })) {
                // Default selection for the keyboard (space = preview) must not scroll the list away from the answer.
                if vm.settings.enableAISynthesis { suppressNextHighlightScroll = true }
                vm.highlightedResultID = results.first?.id
            }
        }
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("CortexDebug"))) { note in
            guard let msg = note.object as? String else { return }
            if msg == "peek" || msg.hasPrefix("peek ") {
                let arg = msg == "peek" ? "" : String(msg.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if arg == "close" || arg == "off" {
                    closePeek()
                } else if let idx = Int(arg), idx >= 1, idx <= vm.searchResults.count {
                    let item = vm.searchResults[idx - 1]
                    vm.highlightedResultID = item.id
                    peekItem = item
                } else {
                    togglePeek()
                }
            } else if msg == "followup-open" || msg.hasPrefix("followup-open ") {
                let text = msg == "followup-open" ? "" : String(msg.dropFirst("followup-open ".count))
                followUpOpen = true
                followUpText = text
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { followUpFocused = true }
            } else if msg.hasPrefix("followup-send ") {
                let text = String(msg.dropFirst("followup-send ".count))
                followUpText = text
                sendFollowUp()
            }
        }
    }

    // MARK: Keyboard: selection, space-bar preview

    private var isEditingText: Bool {
        if searchFocused || followUpFocused { return true }
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let tv = responder as? NSTextView {
            return tv.isEditable
        }
        if let tf = responder as? NSTextField {
            return tf.isEditable
        }
        let desc = String(describing: type(of: responder))
        if desc.contains("PDF") { return false }
        if responder is NSText || responder is NSTextInputClient {
            return true
        }
        return desc.contains("Text") || desc.contains("Field") || desc.contains("Editor")
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        // 0. If follow-up text field is currently open:
        if followUpOpen {
            if event.keyCode == 53 { // Escape
                closeFollowUp()
                return nil
            }
            return event
        }

        // 1. If Peek preview is currently open:
        if peekItem != nil {
            // Space (49) or Escape (53): Close preview
            if event.keyCode == 49 || event.keyCode == 53 {
                closePeek()
                return nil
            }
            // Down Arrow (125)
            if event.keyCode == 125 {
                stepPeek(1)
                return nil
            }
            // Up Arrow (126)
            if event.keyCode == 126 {
                stepPeek(-1)
                return nil
            }
            // Return (36) without Cmd/Ctrl: open in Reader
            if event.keyCode == 36 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                if let peek = peekItem {
                    closePeek()
                    if let fig = peek.figure { vm.openReader(figure: fig) } else { vm.openReader(result: peek) }
                }
                return nil
            }
            return event
        }

        // 2. Peek preview is NOT open:
        // If the user is actively typing in a text field, let all keys pass through untouched.
        if isEditingText {
            return event
        }

        // Space (49): Toggle peek preview on current or first hit
        if event.keyCode == 49 {
            guard !vm.searchResults.isEmpty else { return event }
            togglePeek()
            return nil
        }

        // Down Arrow (125)
        if event.keyCode == 125 {
            guard !vm.searchResults.isEmpty else { return event }
            moveSelection(1)
            return nil
        }

        // Up Arrow (126)
        if event.keyCode == 126 {
            guard !vm.searchResults.isEmpty else { return event }
            moveSelection(-1)
            return nil
        }

        // Return (36) without Cmd/Ctrl: open in Reader
        if event.keyCode == 36 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            guard !vm.searchResults.isEmpty, let i = selectedIndex else { return event }
            let item = vm.searchResults[i]
            if let fig = item.figure { vm.openReader(figure: fig) } else { vm.openReader(result: item) }
            return nil
        }

        return event
    }

    private var selectedIndex: Int? {
        vm.searchResults.firstIndex { $0.id == vm.highlightedResultID }
    }

    private func select(_ item: SearchResultItem) {
        searchFocused = false
        vm.highlightedResultID = item.id
        resultsFocused = true
    }

    private func togglePeek() {
        if peekItem != nil { closePeek(); return }
        guard !vm.searchResults.isEmpty else { return }
        let item = selectedIndex.map { vm.searchResults[$0] } ?? vm.searchResults[0]
        vm.highlightedResultID = item.id
        peekItem = item
    }

    private func closePeek() {
        peekItem = nil
        resultsFocused = true
    }

    private func stepPeek(_ delta: Int) {
        moveSelection(delta)
        if peekItem != nil, let i = selectedIndex { peekItem = vm.searchResults[i] }
    }

    private func moveSelection(_ delta: Int) {
        guard !vm.searchResults.isEmpty else { return }
        let next = max(0, min(vm.searchResults.count - 1, (selectedIndex ?? -1) + delta))
        vm.highlightedResultID = vm.searchResults[next].id
    }

    // MARK: Search field + controls

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: vm.settings.enableAISynthesis ? "sparkle.magnifyingglass" : "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .contentTransition(.symbolEffect(.replace))
            TextField(vm.settings.enableAISynthesis ? "Frage stellen – z. B. „Wie funktioniert die Leader-Wahl in Raft?“" : "Begriff oder Thema suchen …",
                      text: $vm.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .focused($searchFocused)
                .onSubmit {
                    searchFocused = false
                    resultsFocused = true
                    vm.submitSearch()
                }
            if vm.isSearching {
                ProgressView().controlSize(.small)
            } else if !vm.searchQuery.isEmpty {
                Button {
                    vm.searchQuery = ""
                    vm.submitSearch()
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Suche leeren")
            }
            Button { vm.submitSearch() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.white)
                    .background(Theme.accentGradient, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(vm.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(vm.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 9)
        .glassSurface(cornerRadius: 26, interactive: true)
        .matchedGeometryEffect(id: "search", in: heroSpace)
    }

    @State private var showAdvancedHeaderControls = false

    private var searchHeaderControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 8) {
                ContentModePicker(vm: vm)
                ScopeBadge(vm: vm)
                if vm.settings.enableAISynthesis {
                    Button {
                        withAnimation(Theme.quick) { showAdvancedHeaderControls.toggle() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 10.5))
                            Text(shortModelName(vm.settings.llmSelectedModel))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: 110)
                            Image(systemName: showAdvancedHeaderControls ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Theme.accent.opacity(0.10), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("KI-Einstellungen ein-/ausblenden")
                }
                SearchOptionsButton(vm: vm)
            }
            if showAdvancedHeaderControls {
                FlowLayout(spacing: 8) {
                    aiToggleChips
                }
                .padding(.top, 2)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyStateControls: some View {
        FlowLayout(spacing: 8) {
            ToggleChip(title: "KI-Antwort", icon: "sparkles", isOn: vm.settings.enableAISynthesis,
                       help: "Antwort aus den Fundstellen über dein lokales Sprachmodell erzeugen") {
                vm.setAIEnabled(!vm.settings.enableAISynthesis)
            }
            if vm.settings.enableAISynthesis {
                ToggleChip(title: "Denken", icon: "brain", isOn: vm.settings.enableThinking, tint: Theme.thinking,
                           help: "Ausführliches Nachdenken des Modells (langsamer, oft gründlicher)") {
                    vm.setThinking(!vm.settings.enableThinking)
                }
                modelMenu
            }
            ContentModePicker(vm: vm)
            ScopeBadge(vm: vm)
            SearchOptionsButton(vm: vm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var aiToggleChips: some View {
        HStack(spacing: 8) {
            ToggleChip(title: "KI-Antwort", icon: "sparkles", isOn: vm.settings.enableAISynthesis,
                       help: "Antwort aus den Fundstellen über dein lokales Sprachmodell erzeugen") {
                vm.setAIEnabled(!vm.settings.enableAISynthesis)
            }
            if vm.settings.enableAISynthesis {
                ToggleChip(title: "Denken", icon: "brain", isOn: vm.settings.enableThinking, tint: Theme.thinking,
                           help: "Ausführliches Nachdenken des Modells (langsamer, oft gründlicher)") {
                    vm.setThinking(!vm.settings.enableThinking)
                }
                modelMenu
            }
        }
    }

    private var modelMenu: some View {
        Menu {
            Section("Server") {
                ForEach(vm.settings.llmProfiles) { p in
                    Button { vm.activateProfile(p.id) } label: {
                        let ok = vm.profilePings[p.id]?.ok
                        Label("\(p.name)\(p.id == vm.settings.activeLLMProfileID ? " ✓" : "")\(ok == false ? " – nicht erreichbar" : "")",
                              systemImage: p.isRemote ? "network" : "desktopcomputer")
                    }
                }
            }
            Divider()
            if let models = vm.llmPingResult?.models, !models.isEmpty {
                ForEach(models) { m in
                    Button {
                        vm.selectModel(m.id)
                    } label: {
                        if m.id == vm.settings.llmSelectedModel {
                            Label(m.displayLabel, systemImage: "checkmark")
                        } else {
                            Text(m.displayLabel)
                        }
                    }
                }
                Divider()
            } else {
                Text(vm.llmPingResult?.message ?? "Server wird geprüft …")
                Divider()
            }
            Button("Verbindung erneut prüfen") { Task { await vm.pingLLMEndpoint() } }
            Button("Modell aus Speicher entladen") { vm.unloadActiveModel() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(vm.llmPingResult?.ok == true ? Theme.success : Theme.warning)
                    .frame(width: 6, height: 6)
                if let p = vm.settings.activeLLMProfile, vm.settings.llmProfiles.count > 1 {
                    Image(systemName: p.isRemote ? "network" : "desktopcomputer")
                        .font(.system(size: 10))
                }
                Text(shortModelName(vm.settings.llmSelectedModel))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .frame(maxWidth: 130)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .help("Server & Sprachmodell · \(vm.settings.activeLLMProfile?.name ?? "") · \(vm.llmPingResult?.message ?? "")")
    }

    private func shortModelName(_ id: String) -> String {
        id.isEmpty ? "Kein Modell" : (id.count > 26 ? String(id.prefix(24)) + "…" : id)
    }

    private var searchHeader: some View {
        VStack(spacing: 8) {
            searchField
            searchHeaderControls
        }
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Spacer()
            VStack(spacing: 10) {
                CortexPrismSymbol(size: 54)
                Text("Was möchtest du wissen?")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(vm.hasSelection ? "Durchsucht deine Auswahl · \(vm.scopedDocuments.count) Dokumente" : "Durchsucht die ganze Bibliothek · \(vm.scopedDocuments.count) Dokumente")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                searchField
                emptyStateControls
            }
            .frame(maxWidth: 720)
            if !recentQueries.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(recentQueries, id: \.self) { q in
                        Button {
                            vm.searchQuery = q
                            vm.submitSearch()
                        } label: {
                            Label(q, systemImage: "clock.arrow.circlepath")
                                .font(.system(size: 11.5))
                                .lineLimit(1)
                        }
                        .glassButton()
                    }
                }
                .frame(maxWidth: 720)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var recentQueries: [String] {
        var seen = Set<String>()
        return vm.agentEvents
            .filter { $0.source == "ui" && $0.operation == "search" }
            .map(\.query)
            .filter { seen.insert($0.lowercased()).inserted }
            .prefix(4)
            .map { $0 }
    }

    // MARK: Results

    private var resultsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if vm.settings.enableAISynthesis {
                        AIAnswerCard(vm: vm)
                            .id("answer")
                    }
                    resultsHeader
                    if vm.searchResults.isEmpty && !vm.isSearching {
                        ContentUnavailableView("Keine Fundstellen", systemImage: "doc.text.magnifyingglass",
                                               description: Text("Versuche andere Begriffe oder erweitere den Suchbereich in der Seitenleiste."))
                            .padding(.top, 30)
                    }
                    ForEach(vm.searchResults) { item in
                        ResultCard(vm: vm, item: item, onPeek: { select(item); togglePeek() })
                            .id(item.id)
                            .simultaneousGesture(TapGesture().onEnded { select(item) })
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, 60)
            }
            .scrollContentBackground(.hidden)
            .focusable()
            .focused($resultsFocused)
            .focusEffectDisabled()
            .overlay(alignment: .bottomTrailing) {
                if canFollowUp {
                    floatingFollowUpWidget
                        .padding(.trailing, 24)
                        .padding(.bottom, 20)
                        .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .animation(Theme.spring, value: canFollowUp)
            .onChange(of: vm.highlightedResultID) { _, id in
                if suppressNextHighlightScroll {
                    suppressNextHighlightScroll = false
                    proxy.scrollTo("answer", anchor: .top)
                    return
                }
                if let id {
                    // When AI answer is enabled and this is the initial default selection, stay at the top answer
                    if vm.settings.enableAISynthesis && id == vm.searchResults.first?.id && !resultsFocused {
                        proxy.scrollTo("answer", anchor: .top)
                    } else {
                        withAnimation(Theme.spring) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
            }
            .onChange(of: vm.lastSubmittedQuery) { _, _ in
                if vm.settings.enableAISynthesis {
                    proxy.scrollTo("answer", anchor: .top)
                }
            }
            // Once per answer: when the actual answer text starts (after the thinking part), bring the answer into
            // view. Only once – scrolling down to the passages while it streams is not undone.
            .onChange(of: vm.synthesisState.answerText.isEmpty) { _, isEmpty in
                let round = "\(vm.lastSubmittedQuery)#\(vm.previousTurns.count)"
                guard !isEmpty, vm.settings.enableAISynthesis, answerJumpDone != round else { return }
                answerJumpDone = round
                withAnimation(Theme.spring) { proxy.scrollTo("answer", anchor: .top) }
            }
        }
    }

    @ViewBuilder
    private var floatingFollowUpWidget: some View {
        Group {
            if followUpOpen {
                GeometryReader { geo in
                    HStack(spacing: 8) {
                        Menu {
                            Picker("Quellen", selection: $vm.followUpSearchMode) {
                                ForEach(FollowUpSearchMode.allCases, id: \.self) { mode in
                                    Label(LocalizedStringKey(mode.label), systemImage: mode.icon).tag(mode)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: vm.followUpSearchMode.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                            }
                            .foregroundStyle(vm.followUpSearchMode == .auto ? Color.secondary : Theme.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                        .menuStyle(.button)
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help(vm.followUpSearchMode.label)

                        TextField("Nachfrage, z. B. „und bei einer Netzwerkpartition?“", text: $followUpText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .focused($followUpFocused)
                            .onSubmit(sendFollowUp)
                            .onExitCommand { closeFollowUp() }
                            .frame(minWidth: 100, maxWidth: .infinity)

                        if !followUpText.isEmpty {
                            Button { followUpText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Eingabe leeren")
                        }

                        Button { closeFollowUp() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .background(Color.primary.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Schließen (Esc)")

                        Button(action: sendFollowUp) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Theme.accentGradient, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(followUpText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(followUpText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    }
                    .padding(.leading, 10)
                    .padding(.trailing, 6)
                    .padding(.vertical, 6)
                    .glassSurface(cornerRadius: 22, interactive: true)
                    .overlay(
                        Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.20), radius: 14, y: 5)
                    .frame(maxWidth: max(220, min(geo.size.width - 48, 460)), alignment: .trailing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .frame(height: 48)
                .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
                .onAppear { followUpFocused = true }
            } else {
                Button {
                    withAnimation(Theme.spring) {
                        followUpOpen = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.text.bubble.right.fill")
                            .font(.system(size: 11))
                        Text("Follow-up")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6.5)
                    .foregroundStyle(.white)
                    .background(Theme.accentGradient, in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.38), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .help("Nachfrage stellen (⇧⌘N)")
                .transition(.scale(scale: 0.8, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: followUpOpen)
    }

    private var resultsHeader: some View {
        HStack(spacing: 8) {
            Text("Fundstellen")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            InfoPill(text: "\(vm.searchResults.count)", tint: Theme.accent)
            if let ms = vm.lastSearchLatencyMs {
                InfoPill(text: "\(Int(ms)) ms", icon: "bolt.fill", tint: .secondary, monospaced: true)
            }
            if vm.settings.neuralReranker != .none && vm.settings.neuralReranker.isDownloaded {
                InfoPill(text: LocalizedStringKey(vm.settings.neuralReranker.displayName), icon: "arrow.up.arrow.down", tint: Theme.figure)
                    .help("Mit Reranker-Modell nachsortiert")
            } else if vm.settings.enableReranker {
                InfoPill(text: "nachsortiert", icon: "arrow.up.arrow.down", tint: Theme.figure)
                    .help("Mit der Wortregel nachsortiert")
            }
            Spacer()
            if !vm.searchResults.isEmpty {
                Menu {
                    Section("Kopieren") {
                        Button("Als Liste (Markdown)") { ExportFormatter.copy(ExportFormatter.resultsMarkdownList(vm), vm: vm, label: "Trefferliste") }
                        Button("Als JSON") { ExportFormatter.copy(ExportFormatter.resultsJSON(vm), vm: vm, label: "JSON") }
                    }
                    Section("Speichern") {
                        Button("Markdown-Datei …") {
                            ExportFormatter.save(ExportFormatter.resultsMarkdownList(vm), suggestedName: ExportFormatter.fileName(vm.lastSubmittedQuery) + "_Treffer.md", type: .init(filenameExtension: "md") ?? .plainText, vm: vm)
                        }
                        Button("JSON-Datei …") {
                            ExportFormatter.save(ExportFormatter.resultsJSON(vm), suggestedName: ExportFormatter.fileName(vm.lastSubmittedQuery) + "_Treffer.json", type: .json, vm: vm)
                        }
                    }
                } label: {
                    Label("Exportieren", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                .help("Fundstellen als Liste oder JSON exportieren")
            }
        }
        .padding(.top, 4)
    }
}

// MARK: - Scope badge & options

struct ScopeBadge: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: vm.hasSelection || vm.hasPageRange ? "scope" : "books.vertical")
                .font(.system(size: 10.5, weight: .semibold))
            Text(vm.hasSelection || vm.hasPageRange ? LocalizedStringKey(vm.scopeSummary) : "Ganze Bibliothek")
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(minWidth: 26, maxWidth: 200)
        .foregroundStyle(vm.hasSelection || vm.hasPageRange ? Theme.accent : .secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background((vm.hasSelection || vm.hasPageRange ? Theme.accent : Color.primary).opacity(0.07), in: Capsule())
        .help("Suchbereich – in der Seitenleiste per Häkchen wählen")
    }
}

struct SearchOptionsButton: View {
    @Bindable var vm: AppViewModel
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12.5, weight: .semibold))
                .frame(width: 28, height: 26)
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .help("Suchoptionen")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            Form {
                Stepper("Treffer: \(vm.settings.maxDisplayedResults)", value: $vm.settings.maxDisplayedResults, in: 3...30)
                Stepper("Kontext: ±\(vm.settings.defaultContextRadius) Abschnitte", value: $vm.settings.defaultContextRadius, in: 0...4)
                if vm.settings.enableAISynthesis {
                    Stepper("Quellen für KI: \(vm.settings.maxChunksForLLM)", value: $vm.settings.maxChunksForLLM, in: 1...12)
                }
                Toggle("Treffer nachsortieren (Präzision)", isOn: $vm.settings.enableReranker)
                LabeledContent("Seiten") {
                    HStack(spacing: 6) {
                        TextField("von", value: $vm.pageStart, format: .number)
                            .frame(width: 52)
                        Text("–").foregroundStyle(.secondary)
                        TextField("bis", value: $vm.pageEnd, format: .number)
                            .frame(width: 52)
                        if vm.hasPageRange {
                            Button { vm.pageStart = nil; vm.pageEnd = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.tertiary)
                                .help("Seitenbereich entfernen")
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                }
                .help("Nur Fundstellen in diesem Seitenbereich (gilt für alle Dokumente im Suchbereich)")
                Picker("Text", selection: $vm.settings.chunkDisplayMode) {
                    Text("Lesetext").tag(ChunkDisplayMode.cleaned)
                    Text("Original").tag(ChunkDisplayMode.raw)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .frame(width: 320)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - AI answer card

struct AIAnswerCard: View {
    @Bindable var vm: AppViewModel
    @State private var thinkingExpanded = false
    @State private var expandedTurns: Set<UUID> = []
    @State private var copied = false

    private var st: AISynthesisStreamState { vm.synthesisState }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if vm.isConversation {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(vm.previousTurns) { turn in
                                previousTurnRow(turn)
                            }
                            currentRound
                                .id("current")
                        }
                        .padding(.trailing, 6)
                        .padding(.bottom, 6)
                    }
                    .frame(maxHeight: 560)
                    .onChange(of: vm.previousTurns.count) { _, _ in
                        withAnimation(Theme.spring) { proxy.scrollTo("current", anchor: .top) }
                    }
                }
            } else {
                currentRound
            }
            if !vm.conversationSources.isEmpty || !st.citations.isEmpty {
                sources
            }
        }
        .padding(18)
        .glassSurface(cornerRadius: Theme.radiusLarge, tint: Theme.accent)
        .animation(Theme.spring, value: st.answerText.isEmpty)
        .animation(Theme.spring, value: thinkingExpanded)
        .animation(Theme.spring, value: vm.previousTurns.count)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            IconTile(systemName: vm.isConversation ? "bubble.left.and.text.bubble.right" : "sparkles", tint: Theme.accent, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.isConversation ? "Antwort · \(vm.previousTurns.count + 1) Runden" : "Antwort")
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(st.modelUsed.isEmpty ? vm.settings.llmSelectedModel : st.modelUsed)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if st.isGenerating || vm.isFollowUpSearching {
                ProgressView().controlSize(.small)
                if vm.isFollowUpSearching {
                    Text("Sucht …").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                smallIcon("stop.fill", help: "Stoppen") { vm.cancelAISynthesis() }
            } else {
                if st.latencyMs > 0 {
                    Text(String(format: "%.1f s", st.latencyMs / 1000))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                if !st.answerText.isEmpty {
                    smallIcon(copied ? "checkmark" : "doc.on.doc", help: "Antwort mit Quellen kopieren") {
                        NSPasteboard.copy(ExportFormatter.conversationMarkdown(vm))
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
                    }
                    exportMenu
                }
                if vm.isConversation {
                    smallIcon("arrow.uturn.backward", help: "Nachfragen verwerfen – zurück zur ersten Antwort") { vm.resetToFirstAnswer() }
                }
                if st.answerText.isEmpty && !vm.searchResults.isEmpty {
                    Button { vm.triggerAISynthesis() } label: { Label("Antworten", systemImage: "sparkles") }
                        .glassButton(prominent: true)
                        .controlSize(.small)
                } else {
                    smallIcon("arrow.clockwise", help: "Antwort neu erzeugen") { vm.triggerAISynthesis() }
                        .disabled(vm.searchResults.isEmpty)
                }
            }
        }
    }

    private func smallIcon(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .contentTransition(.symbolEffect(.replace))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .background(Color.primary.opacity(0.05), in: Circle())
        .help(help)
    }

    private var exportMenu: some View {
        Menu {
            Section("Kopieren") {
                Button("Als Markdown") { ExportFormatter.copy(ExportFormatter.conversationMarkdown(vm), vm: vm, label: "Markdown") }
                Button("Als LaTeX") { ExportFormatter.copy(ExportFormatter.conversationLaTeX(vm), vm: vm, label: "LaTeX") }
                Button("Für Lernskript (mit Belegstellen & Abbildungen)") {
                    ExportFormatter.copy(ExportFormatter.studyScriptMarkdown(vm), vm: vm, label: "Lernskript-Markdown")
                }
            }
            Section("Speichern") {
                Button("Markdown-Datei …") {
                    ExportFormatter.save(ExportFormatter.studyScriptMarkdown(vm), suggestedName: ExportFormatter.fileName(vm.lastSubmittedQuery) + ".md", type: .init(filenameExtension: "md") ?? .plainText, vm: vm)
                }
                Button("LaTeX-Datei …") {
                    ExportFormatter.save(ExportFormatter.conversationLaTeX(vm), suggestedName: ExportFormatter.fileName(vm.lastSubmittedQuery) + ".tex", type: .init(filenameExtension: "tex") ?? .plainText, vm: vm)
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 11.5, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.05), in: Circle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Exportieren")
    }

    // MARK: Rounds

    @ViewBuilder
    private var currentRound: some View {
        VStack(alignment: .leading, spacing: 12) {
            if vm.isConversation {
                questionBubble(vm.currentQuestion, added: vm.currentAddedSources, note: vm.currentStrategyNote)
            }
            if !st.thinkingText.isEmpty {
                thinkingSection(st)
            }
            if let err = st.errorMessage {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(err).font(.system(size: 12.5))
                        SettingsLink { Text("KI-Einstellungen öffnen") }
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .padding(12)
                .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if !st.answerText.isEmpty {
                MarkdownView(text: st.answerText, baseSize: 13.5) { idx in vm.jumpToCitation(idx) }
            } else if st.isGenerating && st.thinkingText.isEmpty {
                ShimmerLines()
            } else if !st.isGenerating && st.errorMessage == nil {
                Text(vm.settings.aiSynthesisTrigger == .onDemand ? "Antwort auf Klick erzeugen." : "Noch keine Antwort.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func questionBubble(_ q: String, added: Int?, note: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.accent)
            Text(q).font(.system(size: 13, weight: .semibold)).textSelection(.enabled)
            Spacer(minLength: 6)
            if let added {
                Group {
                    if note == "aus bisherigen Quellen" {
                        Text("aus bisherigen Quellen")
                    } else {
                        Text(LocalizedStringKey(note ?? "")) + Text(verbatim: " · ") + (added > 0 ? Text("+\(added) neue Quellen") : Text("keine neuen Quellen"))
                    }
                }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .help("Automatik: reine Anweisungen nutzen die bisherigen Quellen, kurze Ergänzungen werden an die erste Frage angehängt, eigenständige Fragen bekommen eine eigene Suche.")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func previousTurnRow(_ turn: ConversationTurn) -> some View {
        let expanded = expandedTurns.contains(turn.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if expanded { expandedTurns.remove(turn.id) } else { expandedTurns.insert(turn.id) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(turn.question).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        if !expanded {
                            Text(turn.state.answerText
                                .replacingOccurrences(of: #"[*#_`>|]+"#, with: "", options: .regularExpression)
                                .replacingOccurrences(of: "\n", with: " "))
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                MarkdownView(text: turn.state.answerText, baseSize: 12.5) { idx in vm.jumpToCitation(idx) }
                    .padding(.leading, 17)
                    .transition(.opacity)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func thinkingSection(_ st: AISynthesisStreamState) -> some View {
        let isLive = st.isGenerating && st.answerText.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            Button { thinkingExpanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9.5, weight: .bold))
                        .rotationEffect(.degrees(thinkingExpanded ? 90 : 0))
                    Image(systemName: "brain")
                        .symbolEffect(.pulse, isActive: isLive)
                    Text(isLive ? "Denkt nach …" : "Gedankengang")
                        .font(.system(size: 12, weight: .semibold))
                    Text("\(st.thinkingText.split(whereSeparator: { $0.isWhitespace }).count) Wörter")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .foregroundStyle(Theme.thinking)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if thinkingExpanded {
                ScrollView {
                    MarkdownView(text: st.thinkingText, baseSize: 12)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }
                .frame(maxHeight: 280)
                .background(Theme.thinking.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Sources

    private var sources: some View {
        let list = vm.conversationSources
        let firstCount = vm.isConversation ? max(1, vm.settings.maxChunksForLLM) : list.count
        return VStack(alignment: .leading, spacing: 8) {
            Text("Quellen")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6) {
                ForEach(Array(list.enumerated()), id: \.element.chunkID) { i, src in
                    Button { vm.jumpToCitation(i + 1) } label: {
                        HStack(spacing: 6) {
                            Text("\(i + 1)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 17, height: 17)
                                .background(i >= firstCount ? Theme.figure : Theme.accent, in: Circle())
                            Text(CortexTextSanitizer.displayTitle(src.documentTitle)).font(.system(size: 11.5)).lineLimit(1).frame(maxWidth: 200, alignment: .leading)
                            Text("S. \(src.pageNumber)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, 10)
                        .padding(.vertical, 4)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(i >= firstCount ? "Durch Nachfrage hinzugekommen – im Reader öffnen" : "Im Reader an der Fundstelle öffnen")
                }
            }
        }
    }
}

struct ShimmerLines: View {
    @State private var phase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([1.0, 0.92, 0.75], id: \.self) { w in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.primary.opacity(phase ? 0.10 : 0.04))
                        .frame(width: geo.size.width * w, height: 11)
                }
                .frame(height: 11)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever()) { phase = true } }
    }
}

/// Simple wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

// MARK: - Result card

struct ResultCard: View {
    @Bindable var vm: AppViewModel
    let item: SearchResultItem
    var onPeek: (() -> Void)? = nil
    @State private var showContext = false
    @State private var showPage = false
    @State private var figureDetail: FigureResultItem?

    private var citationIndex: Int? {
        vm.synthesisState.citations.first(where: { $0.chunkID == item.chunkID })?.index
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 9) {
                Text(citationIndex.map { "\($0)" } ?? "#\(item.rank)")
                    .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(citationIndex != nil ? .white : Theme.accent)
                    .frame(minWidth: 22, minHeight: 22)
                    .padding(.horizontal, citationIndex != nil ? 0 : 3)
                    .background(citationIndex != nil ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.12)), in: Capsule())
                    .help(citationIndex != nil ? "Quelle [\(citationIndex!)] der KI-Antwort" : "Rang")
                VStack(alignment: .leading, spacing: 1) {
                    Text(CortexTextSanitizer.displayTitle(item.documentTitle))
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    Text(sectionPath)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if let merged = item.mergedNeighborCount, merged > 0 {
                    InfoPill(text: "+\(merged)", icon: "square.stack", tint: .secondary)
                        .help("\(merged) angrenzende Fundstelle(n) dieses Dokuments zusammengefasst – im Kontext enthalten")
                }
                InfoPill(text: "S. \(item.pageNumber)", icon: "book.pages", tint: Theme.accent)
                RelevanceMeter(score: item.score)
            }

            if let fig = item.figure {
                figureContent(fig)
            } else {
            if showContext && !item.contextBefore.isEmpty {
                contextBlock(vm.displayText(item.contextBefore, documentID: item.documentID), edge: .top)
            }

            Text(vm.displayText(item.matchedContent, documentID: item.documentID, page: item.pageNumber))
                .font(.system(size: 13.2))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if showContext && !item.contextAfter.isEmpty {
                contextBlock(vm.displayText(item.contextAfter, documentID: item.documentID), edge: .bottom)
            }

            if !item.figuresOnPage.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(item.figuresOnPage) { fig in
                            Button { vm.openReader(figure: fig) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    AssetImage(path: fig.croppedImagePath, maxHeight: 96, cornerRadius: 8)
                                        .frame(maxWidth: 170)
                                    Text(fig.label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.figure)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(fig.caption.isEmpty ? fig.label : fig.caption)
                        }
                    }
                }
            }
            }

            if showPage {
                AssetImage(path: item.fullPageImagePath, maxHeight: 460, cornerRadius: 12, documentPath: item.documentPath, pageNumber: item.pageNumber)
                    .frame(maxWidth: .infinity)
                    .onTapGesture { vm.openReader(result: item) }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }

            HStack(spacing: 8) {
                Button {
                    if let fig = item.figure { vm.openReader(figure: fig) } else { vm.openReader(result: item) }
                } label: {
                    Label("An Fundstelle öffnen", systemImage: "text.viewfinder")
                }
                .glassButton(prominent: true)

                if item.figure == nil && (!item.contextBefore.isEmpty || !item.contextAfter.isEmpty) {
                    Button { withAnimation(Theme.spring) { showContext.toggle() } } label: {
                        Label(showContext ? "Weniger" : "Kontext", systemImage: showContext ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                    }
                    .glassButton()
                }
                Button { withAnimation(Theme.spring) { showPage.toggle() } } label: {
                    Label(showPage ? "Seite ausblenden" : "Seite", systemImage: "doc.richtext")
                }
                .glassButton()
                if let onPeek {
                    Button(action: onPeek) { Label("Vorschau", systemImage: "eye") }
                        .glassButton()
                        .help("Vorschau mit Dokument und Kontext (Leertaste)")
                }

                Spacer()
                Menu {
                    Button("Text mit Quelle kopieren") {
                        NSPasteboard.copy("\(vm.displayText(item.matchedContent, documentID: item.documentID, page: item.pageNumber))\n— \(CortexTextSanitizer.displayTitle(item.documentTitle)), S. \(item.pageNumber)")
                    }
                    Button("chunk_id kopieren") { NSPasteboard.copy(item.chunkID) }
                    Divider()
                    Button("Nur in diesem Dokument suchen") { vm.selectOnly(documentID: item.documentID) }
                    Button("In Vorschau öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: item.documentPath)) }
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.documentPath)]) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(.borderless)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(16)
        .contentCard(highlighted: vm.highlightedResultID == item.id)
        .onAppear { showContext = vm.settings.showSurroundingContextExpanded && vm.settings.defaultContextRadius > 0 }
    }

    /// A figure hit: the image is the content, caption and slide text below it.
    private func figureContent(_ fig: FigureResultItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { figureDetail = fig } label: {
                AssetImage(path: fig.croppedImagePath, maxHeight: 280, cornerRadius: 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .help("Abbildung groß anzeigen")
            .sheet(item: $figureDetail) { f in
                FigureDetailSheet(vm: vm, fig: f) { figureDetail = nil }
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Label(fig.label, systemImage: "photo")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.figure)
                if !fig.caption.isEmpty && fig.caption != fig.label {
                    Text(fig.caption)
                        .font(.system(size: 12.5))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            if showContext, !fig.surroundingContext.isEmpty {
                contextBlock(vm.displayText(fig.surroundingContext, documentID: item.documentID), edge: .bottom)
            }
        }
    }

    private var sectionPath: String {
        let parts = CortexTextSanitizer.displayTitle(item.breadcrumb).components(separatedBy: " > ")
        let inner = parts.count > 1 ? parts.dropFirst().joined(separator: " › ") : ""
        return [item.collectionName, inner].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func contextBlock(_ content: String, edge: VerticalEdge) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 3)
            Text(content)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .lineLimit(5, reservesSpace: false)
                .truncationMode(edge == .top ? .head : .tail)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .transition(.opacity.combined(with: .move(edge: edge == .top ? .top : .bottom)))
    }
}

/// Alles · Text · Bilder – what the search returns.
struct ContentModePicker: View {
    @Bindable var vm: AppViewModel

    var body: some View {
        Picker("", selection: $vm.settings.searchContentMode) {
            ForEach(SearchContentMode.allCases, id: \.self) { mode in
                Image(systemName: mode.icon)
                    .help(LocalizedStringKey(mode.displayName))
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .controlSize(.small)
        .help("Suchen in: Alles (Text und Bilder), nur Text oder nur Bilder")
    }
}

struct RelevanceMeter: View {
    let score: Double

    var body: some View {
        let clamped = max(0, min(1, score))
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Capsule()
                    .fill(Double(i) < clamped * 5 - 0.2 ? Theme.accent : Color.primary.opacity(0.12))
                    .frame(width: 4, height: 6 + CGFloat(i) * 2)
            }
        }
        .frame(height: 14, alignment: .bottom)
        .help(String(format: "Relevanz %.0f %%", clamped * 100))
    }
}
