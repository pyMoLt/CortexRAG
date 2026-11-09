import SwiftUI
import AppKit
import CortexCore

// MARK: - Sidebar: area > topic > imported folder tree > documents, with checkbox multi-selection

struct LibrarySidebar: View {
    @Bindable var vm: AppViewModel
    @State private var nameEdit: NameEdit?
    @State private var listTargeted = false
    @State private var topicToRemove: LibraryCollection?
    @State private var deletionTarget: DeletionTarget?

    /// Targets that can be removed from the library with a confirmation dialog.
    enum DeletionTarget: Identifiable {
        case document(LibraryDocument)
        case rootFolder(WatchedFolder)
        case subfolder(name: String, path: String, documents: [LibraryDocument])

        var id: String {
            switch self {
            case .document(let doc): return "doc-\(doc.id)"
            case .rootFolder(let f): return "folder-\(f.id)"
            case .subfolder(_, let path, _): return "subfolder-\(path)"
            }
        }

        var title: String {
            switch self {
            case .document(let doc):
                return "„\(CortexTextSanitizer.displayTitle(doc.title))“ aus der Bibliothek entfernen?"
            case .rootFolder(let f):
                let name = URL(fileURLWithPath: f.path).lastPathComponent
                return "Ordner „\(name)“ aus der Bibliothek entfernen?"
            case .subfolder(let name, _, _):
                return "Unterordner „\(name)“ aus der Bibliothek entfernen?"
            }
        }

        var message: String {
            switch self {
            case .document:
                return "Die PDF-Datei auf der Festplatte bleibt unverändert erhalten. Es werden lediglich die Chunks, Vektoren und Abbildungen aus dem Suchindex gelöscht."
            case .rootFolder:
                return "Die Dateien auf der Festplatte bleiben unverändert erhalten. Alle indizierten Dokumente dieses Ordners werden aus dem Suchindex entfernt."
            case .subfolder(_, _, let docs):
                return "Die Dateien auf der Festplatte bleiben unverändert erhalten. Die \(docs.count) indizierten Dokumente dieses Unterordners werden aus dem Suchindex entfernt."
            }
        }

        var buttonTitle: String {
            switch self {
            case .document: return "Dokument entfernen"
            case .rootFolder: return "Ordner entfernen"
            case .subfolder: return "Unterordner entfernen"
            }
        }
    }

    /// Rename / create dialogs share one sheet.
    enum NameEdit: Identifiable {
        case newArea, newTopic(moduleID: String), renameArea(LibraryModule), renameTopic(LibraryCollection)
        var id: String {
            switch self {
            case .newArea: return "newArea"
            case .newTopic(let m): return "newTopic-\(m)"
            case .renameArea(let m): return "ra-\(m.id)"
            case .renameTopic(let c): return "rt-\(c.id)"
            }
        }
    }

    private var filter: String { vm.sidebarFilter.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 0) {
            header
            scopeCard
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            if vm.collections.isEmpty {
                emptyLibrary
            } else {
                tree
            }

            ImportQueueBar(vm: vm, queue: vm.importer)
        }
        .sheet(item: $vm.pendingImport) { pending in
            ImportSheet(vm: vm, pending: pending)
        }
        .sheet(item: $nameEdit) { edit in
            nameSheet(for: edit)
        }
        .confirmationDialog(
            "„\(topicToRemove?.name ?? "")“ aus der Bibliothek entfernen?",
            isPresented: Binding(get: { topicToRemove != nil }, set: { if !$0 { topicToRemove = nil } }),
            titleVisibility: .visible
        ) {
            Button("Thema entfernen", role: .destructive) {
                if let t = topicToRemove { vm.deleteCollection(t) }
                topicToRemove = nil
            }
        } message: {
            Text("Der Index des Themas wird gelöscht. Die PDF-Dateien selbst bleiben unverändert an ihrem Ort.")
        }
        .confirmationDialog(
            deletionTarget?.title ?? "",
            isPresented: Binding(get: { deletionTarget != nil }, set: { if !$0 { deletionTarget = nil } }),
            titleVisibility: .visible
        ) {
            if let target = deletionTarget {
                Button(target.buttonTitle, role: .destructive) {
                    switch target {
                    case .document(let doc):
                        vm.deleteDocument(doc)
                    case .rootFolder(let folder):
                        vm.deleteFolder(folder)
                    case .subfolder(_, let path, let docs):
                        vm.selectedSubfolderPaths = vm.selectedSubfolderPaths.filter { !$0.hasPrefix(path) }
                        vm.deleteDocuments(docs)
                    }
                    deletionTarget = nil
                }
            }
        } message: {
            if let target = deletionTarget {
                Text(target.message)
            }
        }
    }

    // MARK: Header: filter + add menu

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Bibliothek filtern", text: $vm.sidebarFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !vm.sidebarFilter.isEmpty {
                    Button { vm.sidebarFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Menu {
                Button("PDFs oder Ordner importieren …", systemImage: "square.and.arrow.down") { vm.importViaPanel() }
                Divider()
                Button("Neues Thema …", systemImage: "folder.badge.plus") { nameEdit = .newTopic(moduleID: "") }
                Button("Neuer Bereich …", systemImage: "square.stack.3d.up.badge.automatic") { nameEdit = .newArea }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Importieren oder Thema/Bereich anlegen")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    // MARK: Scope card

    private var scopeCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: vm.hasSelection ? "scope" : "books.vertical")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(vm.hasSelection ? Theme.accent : .secondary)
                Text(vm.hasSelection || vm.hasPageRange ? LocalizedStringKey(vm.scopeSummary) : "Ganze Bibliothek")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if vm.hasSelection {
                    Button("Alle") { withAnimation(Theme.quick) { vm.clearSelection() } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .semibold))
                        .help("Auswahl aufheben – ganze Bibliothek durchsuchen")
                }
            }
            HStack {
                Text("\(vm.scopedDocuments.count) von \(vm.documents.count) Dokumenten")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $vm.settings.shareSelectionWithAgents) {
                    Text("auch für Agenten").font(.system(size: 10.5))
                }
                .toggleStyle(.checkbox)
                .controlSize(.mini)
                .help("CLI- und MCP-Suchen ohne eigene Filter verwenden diese Auswahl")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .glassSurface(cornerRadius: 12, tint: vm.hasSelection ? Theme.accent : nil)
        .animation(Theme.quick, value: vm.hasSelection)
    }

    // MARK: Tree

    /// Areas in creation order, followed by topics without an area.
    private var areaGroups: [(module: LibraryModule?, topics: [LibraryCollection])] {
        let known = Set(vm.modules.map(\.id))
        var groups: [(LibraryModule?, [LibraryCollection])] = vm.modules.map { m in (m, vm.collections.filter { $0.moduleID == m.id }) }
        let loose = vm.collections.filter { !known.contains($0.moduleID) }
        if !loose.isEmpty { groups.append((nil, loose)) }
        guard !filter.isEmpty else { return groups }
        return groups.compactMap { group in
            if let m = group.0, m.name.localizedCaseInsensitiveContains(filter) { return group }
            let topics = group.1.filter { topicMatches($0) }
            return topics.isEmpty ? nil : (group.0, topics)
        }
    }

    private func topicMatches(_ t: LibraryCollection) -> Bool {
        t.name.localizedCaseInsensitiveContains(filter)
            || folderTrees(of: t).contains { $0.matches(filter) }
            || looseDocuments(of: t).contains { CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(filter) }
    }

    private func folderTrees(of topic: LibraryCollection) -> [FolderTreeNode] {
        vm.watchedFolders.filter { $0.collectionID == topic.id }.map { folder in
            FolderTreeNode.build(root: folder, documents: vm.documents.filter { $0.collectionID == topic.id && $0.folderID == folder.id })
        }
    }

    /// Documents of the topic that do not belong to one of its imported folders.
    private func looseDocuments(of topic: LibraryCollection) -> [LibraryDocument] {
        let folderIDs = Set(vm.watchedFolders.filter { $0.collectionID == topic.id }.map(\.id))
        return vm.documents
            .filter { $0.collectionID == topic.id && !($0.folderID.map(folderIDs.contains) ?? false) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private var tree: some View {
        List {
            ForEach(areaGroups, id: \.module?.id) { group in
                let areaKey = group.module?.id ?? "__loose__"
                let areaExpanded = vm.isAreaExpanded(areaKey) || !filter.isEmpty
                Section {
                    if areaExpanded {
                        ForEach(group.topics) { topic in
                            TopicRow(vm: vm, topic: topic, trees: folderTrees(of: topic), looseDocuments: looseDocuments(of: topic),
                                     filter: filter, onRename: { nameEdit = .renameTopic(topic) }, onRemove: { topicToRemove = topic },
                                     onRequestDelete: { deletionTarget = $0 })
                        }
                    }
                } header: {
                    areaHeader(group.module, areaKey: areaKey, expanded: areaExpanded)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .dropDestination(for: URL.self) { urls, _ in
            vm.beginImport(urls)
            return true
        } isTargeted: { listTargeted = $0 }
        .overlay {
            if listTargeted { dropHint("Loslassen – Ziel im nächsten Schritt wählen") }
        }
        .animation(Theme.quick, value: listTargeted)
    }

    private func areaHeader(_ module: LibraryModule?, areaKey: String, expanded: Bool) -> some View {
        AreaHeader(vm: vm, module: module, areaKey: areaKey, expanded: expanded,
                   onNewTopic: { nameEdit = .newTopic(moduleID: module?.id ?? "") },
                   onRename: { if let module { nameEdit = .renameArea(module) } })
    }

    private func dropHint(_ text: LocalizedStringKey) -> some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(alignment: .bottom) {
                Label(text, systemImage: "arrow.down.doc")
                    .font(.system(size: 11.5, weight: .semibold))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassSurface(cornerRadius: 16, tint: Theme.accent)
                    .padding(.bottom, 14)
            }
            .padding(6)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Empty library

    private var emptyLibrary: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("PDFs oder Ordner hierher ziehen")
                .font(.system(size: 13.5, weight: .semibold))
            Text("Dateien werden nur verlinkt, nicht kopiert. Die Ordnerstruktur wird übernommen.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Importieren …") { vm.importViaPanel() }
                .glassButton(prominent: true)
            Spacer()
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(listTargeted ? Theme.accent : Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(listTargeted ? Theme.accent.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .padding(10)
        .contentShape(Rectangle())
        .dropDestination(for: URL.self) { urls, _ in
            vm.beginImport(urls)
            return true
        } isTargeted: { listTargeted = $0 }
        .animation(Theme.quick, value: listTargeted)
    }

    // MARK: Name dialogs

    @ViewBuilder
    private func nameSheet(for edit: NameEdit) -> some View {
        switch edit {
        case .newArea:
            NameSheet(title: "Neuer Bereich", placeholder: "z. B. Informatik", initial: "") { name in
                vm.createModule(name: name)
            } onClose: { nameEdit = nil }
        case .newTopic(let moduleID):
            NameSheet(title: "Neues Thema", placeholder: "z. B. Verteilte Systeme", initial: "") { name in
                vm.createCollection(moduleID: moduleID, name: name)
            } onClose: { nameEdit = nil }
        case .renameArea(let m):
            NameSheet(title: "Bereich umbenennen", placeholder: "Name", initial: m.name, confirmTitle: "Umbenennen") { name in
                vm.renameModule(m.id, to: name)
            } onClose: { nameEdit = nil }
        case .renameTopic(let c):
            NameSheet(title: "Thema umbenennen", placeholder: "Name", initial: c.name, confirmTitle: "Umbenennen") { name in
                vm.renameCollection(c.id, to: name)
            } onClose: { nameEdit = nil }
        }
    }
}

// MARK: - Area header

private struct AreaHeader: View {
    @Bindable var vm: AppViewModel
    let module: LibraryModule?
    let areaKey: String
    let expanded: Bool
    let onNewTopic: () -> Void
    let onRename: () -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(Theme.quick) { vm.toggleAreaExpansion(areaKey) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Bereich einklappen" : "Bereich ausklappen")

            if let module {
                SelectionCheckbox(on: vm.selectedModuleIDs.contains(module.id)) { vm.toggleModule(module.id) }
                Button {
                    withAnimation(Theme.quick) { vm.toggleAreaExpansion(areaKey) }
                } label: {
                    Text(module.name)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    withAnimation(Theme.quick) { vm.toggleAreaExpansion(areaKey) }
                } label: {
                    Text(vm.modules.isEmpty ? "Themen" : "Ohne Bereich")
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button(action: onNewTopic) { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("Neues Thema")
        }
        .font(.system(size: 11, weight: .bold))
        .padding(.vertical, 2)
        .background(targeted ? Theme.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            if let module {
                Button("Nur diesen Bereich durchsuchen") { vm.selectOnly(moduleID: module.id) }
                Button("Neues Thema …", action: onNewTopic)
                Button("Umbenennen …", action: onRename)
                Divider()
                Button("Bereich auflösen", role: .destructive) {
                    if let m = vm.modules.first(where: { $0.id == module.id }) { vm.deleteModule(m) }
                }
            } else {
                Button("Neues Thema …", action: onNewTopic)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            vm.beginImport(urls, preferredModuleID: module?.id ?? "")
            return true
        } isTargeted: { targeted = $0 }
        .help(module == nil ? "" : "Bereich auflösen behält die Themen – sie stehen dann unter „Ohne Bereich“.")
    }
}

// MARK: - Topic row

private struct TopicRow: View {
    @Bindable var vm: AppViewModel
    let topic: LibraryCollection
    let trees: [FolderTreeNode]
    let looseDocuments: [LibraryDocument]
    let filter: String
    let onRename: () -> Void
    let onRemove: () -> Void
    let onRequestDelete: (LibrarySidebar.DeletionTarget) -> Void
    @State private var targeted = false

    private var count: Int { trees.reduce(0) { $0 + $1.totalDocumentCount } + looseDocuments.count }

    private var inlinedRoot: FolderTreeNode? {
        guard trees.count == 1, ImportSuggester.normalize(trees[0].name) == ImportSuggester.normalize(topic.name) else { return nil }
        return trees[0]
    }

    private var isExpanded: Bool {
        vm.isTopicExpanded(topic.id) || !filter.isEmpty
    }

    var body: some View {
        // 1. Topic Header Row
        HStack(spacing: 6) {
            Button {
                withAnimation(Theme.quick) { vm.toggleTopicExpansion(topic.id) }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Thema einklappen" : "Thema ausklappen")

            SelectionCheckbox(on: vm.selectedCollectionIDs.contains(topic.id)) { vm.toggleCollection(topic.id) }

            Button {
                withAnimation(Theme.quick) { vm.toggleTopicExpansion(topic.id) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "folder.fill" : "folder")
                        .foregroundStyle(Theme.accent)
                        .font(.system(size: 12.5))
                    Text(topic.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Nur „\(topic.name)“ durchsuchen") { vm.selectOnly(collectionID: topic.id) }
            Button("Alle Unterordner ausklappen") { withAnimation(Theme.quick) { vm.expandAllSidebarFolders() } }
            Button("Alle Unterordner einklappen") { withAnimation(Theme.quick) { vm.collapseAllSidebarFolders() } }
            Divider()
            Button("Umbenennen …", action: onRename)
            if !trees.isEmpty {
                Button("Ordner neu einlesen") {
                    let roots = vm.watchedFolders.filter { $0.collectionID == topic.id }
                    vm.importDirect(roots.map { URL(fileURLWithPath: $0.path) }, topicID: topic.id)
                }
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(trees.map { URL(fileURLWithPath: $0.path) })
                }
            }
            Menu("In Bereich verschieben") {
                Button("Ohne Bereich") { vm.moveCollection(topic.id, toModule: "") }
                ForEach(vm.modules) { m in Button(m.name) { vm.moveCollection(topic.id, toModule: m.id) } }
            }
            Divider()
            Button("Thema entfernen …", role: .destructive, action: onRemove)
        }
        .listRowBackground(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(targeted ? Theme.accent.opacity(0.18) : .clear)
                .padding(.horizontal, 4)
        )
        .dropDestination(for: URL.self) { urls, _ in
            vm.importDirect(urls, topicID: topic.id)
            vm.collapsedTopicIDs.remove(topic.id)
            return true
        } isTargeted: { targeted = $0 }
        .animation(Theme.quick, value: targeted)

        // 2. Expanded Children
        if isExpanded {
            if let inline = inlinedRoot {
                // Single imported folder named like the topic: show its content directly (no "Distributed Systems › Distributed Systems").
                ForEach(inline.children.filter { filter.isEmpty || $0.matches(filter) }) { child in
                    FolderNodeRow(vm: vm, node: child, rootFolderID: nil, filter: filter, depth: 1, onRequestDelete: onRequestDelete)
                }
                ForEach(inline.documents.filter { filter.isEmpty || CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(filter) || topic.name.localizedCaseInsensitiveContains(filter) }) { doc in
                    DocumentRow(vm: vm, doc: doc, depth: 1, onRequestDelete: onRequestDelete)
                }
            } else {
                ForEach(trees) { node in
                    FolderNodeRow(vm: vm, node: node, rootFolderID: vm.watchedFolders.first { $0.path == node.path }?.id, filter: filter, depth: 1, onRequestDelete: onRequestDelete)
                }
            }
            ForEach(looseDocuments.filter { filter.isEmpty || CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(filter) || topic.name.localizedCaseInsensitiveContains(filter) }) { doc in
                DocumentRow(vm: vm, doc: doc, depth: 1, onRequestDelete: onRequestDelete)
            }
            if count == 0 {
                Button { vm.importViaPanel() } label: {
                    Label("PDFs oder Ordner hierher ziehen", systemImage: "arrow.down.doc")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 18)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Folder tree rows (mirror of the folder structure on disk, expandable at every depth)

private struct FolderNodeRow: View {
    @Bindable var vm: AppViewModel
    let node: FolderTreeNode
    /// Set for the imported root folder (selection by folder ID); subfolders are selected by path.
    let rootFolderID: String?
    let filter: String
    let depth: Int
    let onRequestDelete: (LibrarySidebar.DeletionTarget) -> Void

    private var defaultExpanded: Bool {
        rootFolderID != nil
    }

    private var isExpanded: Bool {
        vm.isFolderExpanded(node.path, defaultExpanded: defaultExpanded) || !filter.isEmpty
    }

    private var selected: Bool {
        if let rootFolderID { return vm.selectedFolderIDs.contains(rootFolderID) }
        return vm.selectedSubfolderPaths.contains(node.path)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(Theme.quick) { vm.toggleFolderExpansion(node.path, defaultExpanded: defaultExpanded) }
            } label: {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Ordner einklappen" : "Ordner ausklappen")

            SelectionCheckbox(on: selected) {
                if let rootFolderID { vm.toggleFolder(rootFolderID) } else { vm.toggleSubfolder(node.path) }
            }

            Button {
                withAnimation(Theme.quick) { vm.toggleFolderExpansion(node.path, defaultExpanded: defaultExpanded) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: FileManager.default.fileExists(atPath: node.path) ? (isExpanded ? "folder.fill" : "folder") : "questionmark.folder")
                        .foregroundStyle(isExpanded ? AnyShapeStyle(Theme.accent.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .font(.system(size: 12))
                    Text(node.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(node.totalDocumentCount)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, CGFloat(depth * 14))
        .padding(.vertical, 1.5)
        .contextMenu {
            Button(isExpanded ? "Ordner einklappen" : "Ordner ausklappen") {
                withAnimation(Theme.quick) { vm.toggleFolderExpansion(node.path, defaultExpanded: defaultExpanded) }
            }
            if let rootFolderID {
                Button("Nur diesen Ordner durchsuchen") { vm.selectOnly(folderID: rootFolderID) }
            } else {
                Button("Nur diesen Ordner durchsuchen") { vm.selectOnly(subfolderPath: node.path) }
            }
            Button("Im Finder zeigen") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: node.path) }
            if let rootFolderID, let folder = vm.watchedFolders.first(where: { $0.id == rootFolderID }) {
                Button("Ordner neu einlesen") { vm.importDirect([URL(fileURLWithPath: folder.path)], topicID: folder.collectionID) }
                Divider()
                Button("Ordner aus Bibliothek entfernen …", role: .destructive) {
                    onRequestDelete(.rootFolder(folder))
                }
            } else {
                Divider()
                Button("Unterordner aus Bibliothek entfernen …", role: .destructive) {
                    onRequestDelete(.subfolder(name: node.name, path: node.path, documents: node.allDocuments))
                }
            }
        }

        if isExpanded {
            ForEach(node.children.filter { filter.isEmpty || $0.matches(filter) }) { child in
                FolderNodeRow(vm: vm, node: child, rootFolderID: nil, filter: filter, depth: depth + 1, onRequestDelete: onRequestDelete)
            }
            ForEach(node.documents.filter { filter.isEmpty || CortexTextSanitizer.displayTitle($0.title).localizedCaseInsensitiveContains(filter) || node.name.localizedCaseInsensitiveContains(filter) }) { doc in
                DocumentRow(vm: vm, doc: doc, depth: depth + 1, onRequestDelete: onRequestDelete)
            }
        }
    }
}

// MARK: - Document row

struct DocumentRow: View {
    @Bindable var vm: AppViewModel
    let doc: LibraryDocument
    var depth: Int = 1
    let onRequestDelete: (LibrarySidebar.DeletionTarget) -> Void

    private var missing: Bool { !FileManager.default.fileExists(atPath: doc.filePath) }

    var body: some View {
        HStack(spacing: 7) {
            // Spacer matching chevron width for clean alignment with FolderNodeRow
            Color.clear.frame(width: 14, height: 14)
            SelectionCheckbox(on: vm.selectedDocumentIDs.contains(doc.id)) { vm.toggleDocument(doc.id) }
            Image(systemName: missing ? "exclamationmark.triangle.fill" : "doc.richtext")
                .foregroundStyle(missing ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.secondary))
                .font(.system(size: 11.5))
            VStack(alignment: .leading, spacing: 1) {
                Text(CortexTextSanitizer.displayTitle(doc.title))
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(missing ? "Datei nicht gefunden" : "\(doc.pageCount) S. · \(doc.figureCount) Abb.")
                    .font(.system(size: 10))
                    .foregroundStyle(missing ? AnyShapeStyle(Theme.warning) : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.leading, CGFloat(depth * 14))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { vm.openReader(document: doc) }
        .onTapGesture {
            vm.libraryDocumentID = doc.id
            vm.activeTab = .library
        }
        .help(missing ? "Die PDF liegt nicht mehr unter \(doc.filePath)" : "Klick: Details · Doppelklick: im Reader öffnen")
        .contextMenu {
            Button("Im Reader öffnen") { vm.openReader(document: doc) }
            Button("Nur in diesem Dokument suchen") { vm.selectOnly(documentID: doc.id) }
            Button("Details anzeigen") {
                vm.libraryDocumentID = doc.id
                vm.activeTab = .library
            }
            Divider()
            Button("In Vorschau öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: doc.filePath)) }
            Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: doc.filePath)]) }
            Menu("In Thema verschieben") {
                ForEach(vm.collections.filter { $0.id != doc.collectionID }) { t in
                    Button(t.name) { vm.moveDocuments([doc.id], toTopic: t.id) }
                }
            }
            Button("Neu indizieren") { vm.reindex([doc]) }
            Divider()
            Button("Aus Bibliothek entfernen …", role: .destructive) {
                onRequestDelete(.document(doc))
            }
        }
    }
}

struct SelectionCheckbox: View {
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { withAnimation(Theme.quick) { action() } }) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(on ? Theme.accent : Color.secondary.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(on ? "Aus Suchbereich entfernen" : "Zum Suchbereich hinzufügen")
    }
}

// MARK: - Import dialog

struct ImportSheet: View {
    @Bindable var vm: AppViewModel
    let pending: AppViewModel.PendingImport

    private static let noneTag = "__none"
    private static let newTag = "__new"

    @State private var areaTag = ""
    @State private var newAreaName = ""
    @State private var topicTag = ""
    @State private var newTopicName = ""

    private var plan: ImportPlan { pending.plan }

    private var topicsInArea: [LibraryCollection] {
        let known = Set(vm.modules.map(\.id))
        switch areaTag {
        case Self.newTag: return []
        case Self.noneTag: return vm.collections.filter { !known.contains($0.moduleID) }
        default: return vm.collections.filter { $0.moduleID == areaTag }
        }
    }

    private var target: ImportTarget? {
        let area: ImportTarget.Area
        switch areaTag {
        case Self.noneTag: area = .none
        case Self.newTag:
            let n = newAreaName.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            area = .new(n)
        default: area = .existing(areaTag)
        }
        let topic: ImportTarget.Topic
        if topicTag == Self.newTag || topicsInArea.isEmpty {
            let n = newTopicName.trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty else { return nil }
            topic = .new(n)
        } else {
            topic = .existing(topicTag)
        }
        return ImportTarget(area: area, topic: topic)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Importieren").font(.system(size: 16, weight: .semibold))
                    Text(summaryLine).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            itemsPreview

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Bereich").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("", selection: $areaTag) {
                        Text("Ohne Bereich").tag(Self.noneTag)
                        ForEach(vm.modules) { Text($0.name).tag($0.id) }
                        Divider()
                        Text("Neuer Bereich …").tag(Self.newTag)
                    }
                    .labelsHidden()
                }
                if areaTag == Self.newTag {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        TextField("Name des Bereichs", text: $newAreaName, prompt: Text("z. B. Informatik"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                GridRow {
                    Text("Thema").foregroundStyle(.secondary)
                    if topicsInArea.isEmpty {
                        TextField("Neues Thema", text: $newTopicName, prompt: Text("z. B. Verteilte Systeme"))
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $topicTag) {
                            ForEach(topicsInArea) { Text($0.name).tag($0.id) }
                            Divider()
                            Text("Neues Thema …").tag(Self.newTag)
                        }
                        .labelsHidden()
                    }
                }
                if topicTag == Self.newTag && !topicsInArea.isEmpty {
                    GridRow {
                        Color.clear.frame(width: 1, height: 1)
                        TextField("Neues Thema", text: $newTopicName, prompt: Text("z. B. Verteilte Systeme"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 4)

            Label(plan.folders.isEmpty
                  ? "Die Dateien werden nur verlinkt, nicht kopiert."
                  : "Die Dateien werden nur verlinkt, nicht kopiert. Die Ordnerstruktur wird übernommen\(vm.settings.autoWatchFolders ? " und neue PDFs kommen automatisch dazu" : "").",
                  systemImage: "link")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Abbrechen") { vm.pendingImport = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Importieren") {
                    if let target { vm.confirmImport(pending, target: target) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(target == nil)
            }
        }
        .padding(22)
        .frame(width: 460)
        .onAppear(perform: applySuggestion)
        .onChange(of: areaTag) { _, _ in
            if topicTag != Self.newTag, !topicsInArea.contains(where: { $0.id == topicTag }) {
                topicTag = topicsInArea.first?.id ?? Self.newTag
            }
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if !plan.folders.isEmpty { parts.append(plan.folders.count == 1 ? "1 Ordner" : "\(plan.folders.count) Ordner") }
        if !plan.looseFiles.isEmpty { parts.append(plan.looseFiles.count == 1 ? "1 einzelne PDF" : "\(plan.looseFiles.count) einzelne PDFs") }
        parts.append(plan.pdfCount == 1 ? "1 PDF insgesamt" : "\(plan.pdfCount) PDFs insgesamt")
        return parts.joined(separator: " · ")
    }

    private var itemsPreview: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(plan.folders.prefix(4), id: \.url) { f in
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
                    Text(ImportSuggester.displayName(forFolder: f.url.lastPathComponent)).lineLimit(1)
                    Spacer()
                    Text(f.subfolderCount > 0 ? "\(f.pdfs.count) PDFs · \(f.subfolderCount) Unterordner" : "\(f.pdfs.count) PDFs")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(plan.looseFiles.prefix(4), id: \.self) { url in
                HStack(spacing: 7) {
                    Image(systemName: "doc.richtext").foregroundStyle(.secondary)
                    Text(CortexTextSanitizer.displayTitle(url.deletingPathExtension().lastPathComponent)).lineLimit(1)
                }
            }
            let more = max(0, plan.folders.count - 4) + max(0, plan.looseFiles.count - 4)
            if more > 0 { Text("+ \(more) weitere").foregroundStyle(.secondary) }
        }
        .font(.system(size: 12))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func applySuggestion() {
        let t = pending.target
        switch t.area {
        case .none: areaTag = Self.noneTag
        case .existing(let id): areaTag = id
        case .new(let name): areaTag = Self.newTag; newAreaName = name
        }
        switch t.topic {
        case .existing(let id): topicTag = id
        case .new(let name): topicTag = Self.newTag; newTopicName = name
        }
    }
}

// MARK: - Import queue bar (bottom of the sidebar)

struct ImportQueueBar: View {
    @Bindable var vm: AppViewModel
    let queue: ImportQueue
    @State private var showList = false

    var body: some View {
        VStack(spacing: 8) {
            if queue.hasVisibleJobs {
                card.transition(.move(edge: .bottom).combined(with: .opacity))
            } else if vm.isSwitchingEngine || vm.isBenchmarking || !vm.progressMessage.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(vm.progressMessage.isEmpty ? "Arbeite …" : vm.progressMessage)
                        .font(.system(size: 11)).lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .glassSurface(cornerRadius: 12, tint: Theme.accent)
            }
            if !vm.collections.isEmpty {
            HStack {
                Button { vm.importViaPanel() } label: {
                    Label("Importieren", systemImage: "plus")
                }
                .glassButton()
                .help("PDFs oder Ordner importieren (⇧⌘I) – oder einfach in die Seitenleiste ziehen")
                Spacer()
            }
            }
        }
        .padding(10)
        .animation(Theme.spring, value: queue.hasVisibleJobs)
        .task(id: queue.isRunning) {
            // A clean run hides itself after a moment; failures stay until dismissed or retried.
            guard !queue.isRunning, queue.hasVisibleJobs, queue.failedJobs.isEmpty else { return }
            try? await Task.sleep(for: .seconds(6))
            if !queue.isRunning, queue.failedJobs.isEmpty { withAnimation(Theme.spring) { queue.clearFinished() } }
        }
    }

    private var total: Int { queue.jobs.count }

    private var card: some View {
        let paused = queue.isEffectivelyPaused
        let pausedOnBattery = queue.isRunning && (queue.current?.detail.contains("Akku") == true)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                if queue.isRunning {
                    if paused {
                        Image(systemName: "pause.circle.fill")
                            .foregroundStyle(Theme.warning)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Image(systemName: queue.failedJobs.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(queue.failedJobs.isEmpty ? Theme.success : Theme.warning)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if let cur = queue.current {
                        Text(cur.detail.isEmpty ? cur.title : "\(cur.title) · \(cur.detail)")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button { showList.toggle() } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.borderless)
                    .help("Alle Dateien anzeigen")
                    .popover(isPresented: $showList, arrowEdge: .trailing) { jobList }
                if queue.isRunning {
                    Button { queue.togglePause() } label: {
                        Image(systemName: paused ? "play.circle.fill" : "pause.circle")
                            .foregroundStyle(paused ? Theme.accent : .primary)
                    }
                    .buttonStyle(.borderless)
                    .help(paused ? "Indizierung fortsetzen" : "Indizierung pausieren")
                    Button { queue.cancelAll() } label: {
                        Image(systemName: "stop.circle")
                            .foregroundStyle(Theme.warning)
                    }
                    .buttonStyle(.borderless)
                    .help("Indizierung abbrechen")
                } else {
                    Button { queue.clearFinished() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Ausblenden")
                }
            }
            ProgressView(value: Double(queue.finishedCount), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .tint(paused ? Theme.warning : Theme.accent)
            if pausedOnBattery {
                // Label above, chips below: the sidebar is too narrow for one row (words broke mid-word).
                VStack(alignment: .leading, spacing: 5) {
                    Text("Auf Akku weiter:").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    HStack(spacing: 5) {
                        ForEach([IndexingThrottleMode.ecoSilent, .balanced, .turbo], id: \.self) { mode in
                            Button { queue.resumeOnBattery(mode: mode) } label: {
                                Text(LocalizedStringKey(mode.shortName))
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Theme.accent.opacity(0.14), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }
            if !queue.isRunning, !queue.failedJobs.isEmpty {
                Button("Fehlgeschlagene erneut versuchen") { queue.retryFailed() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .padding(10)
        .glassSurface(cornerRadius: 12, tint: queue.isRunning ? (paused ? Theme.warning : Theme.accent) : nil)
    }

    private var headline: String {
        if queue.isRunning {
            if queue.isEffectivelyPaused {
                return "Pausiert · \(min(queue.finishedCount + 1, total))/\(total)"
            }
            return "Indiziere \(min(queue.finishedCount + 1, total)) von \(total)"
        }
        let cancelled = queue.jobs.filter { $0.state == .cancelled }.count
        if cancelled > 0 && queue.failedJobs.isEmpty {
            return "Abgebrochen · \(queue.finishedCount - cancelled) von \(total) fertig"
        }
        let failed = queue.failedJobs.count
        if failed > 0 { return "\(failed) von \(total) fehlgeschlagen" }
        return total == 1 ? "Fertig · 1 Datei" : "Fertig · \(total) Dateien"
    }

    private var jobList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(queue.jobs) { job in
                    HStack(alignment: .top, spacing: 8) {
                        stateIcon(job.state).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(job.title).font(.system(size: 12)).lineLimit(1)
                            switch job.state {
                            case .failed(let msg):
                                Text(msg).font(.system(size: 10.5)).foregroundStyle(Theme.warning).lineLimit(3)
                            case .running where !job.detail.isEmpty:
                                Text(job.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                            case .unchanged:
                                Text("unverändert").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                            default:
                                EmptyView()
                            }
                        }
                        Spacer(minLength: 4)
                        if !job.state.isFinished {
                            Button { queue.cancel(job.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                                .help("Diese Datei abbrechen")
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 340, height: min(420, CGFloat(queue.jobs.count) * 34 + 30))
    }

    @ViewBuilder
    private func stateIcon(_ state: ImportQueue.State) -> some View {
        switch state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.tertiary)
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .unchanged: Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
        case .cancelled: Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
        }
    }
}

// MARK: - Name dialog

struct NameSheet: View {
    let title: LocalizedStringKey
    let placeholder: LocalizedStringKey
    var confirmTitle: LocalizedStringKey = "Anlegen"
    let onConfirm: (String) -> Void
    let onClose: () -> Void
    @State private var text: String

    init(title: LocalizedStringKey, placeholder: LocalizedStringKey, initial: String, confirmTitle: LocalizedStringKey = "Anlegen",
         onConfirm: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.title = title
        self.placeholder = placeholder
        self.confirmTitle = confirmTitle
        self.onConfirm = onConfirm
        self.onClose = onClose
        _text = State(initialValue: initial)
    }

    private var valid: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if valid { onConfirm(text); onClose() } }
            HStack {
                Spacer()
                Button("Abbrechen", action: onClose).keyboardShortcut(.cancelAction)
                Button(confirmTitle) { onConfirm(text); onClose() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
        }
        .padding(22)
        .frame(width: 380)
    }
}
