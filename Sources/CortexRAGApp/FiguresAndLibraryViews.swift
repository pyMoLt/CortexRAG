import SwiftUI
import AppKit
import CortexCore

// MARK: - Figures

struct FigureDetailSheet: View {
    @Bindable var vm: AppViewModel
    let fig: FigureResultItem
    let onClose: () -> Void

    static func latex(_ fig: FigureResultItem) -> String {
        """
        \\begin{figure}[htbp]
          \\centering
          \\includegraphics[width=0.85\\textwidth]{\(fig.croppedImagePath)}
          \\caption{\(fig.caption.isEmpty ? fig.label : fig.caption) (Quelle: \(CortexTextSanitizer.displayTitle(fig.documentTitle)), S.~\(fig.pageNumber))}
        \\end{figure}
        """
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fig.label).font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("\(CortexTextSanitizer.displayTitle(fig.documentTitle)) · Seite \(fig.pageNumber)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Schließen", action: onClose).keyboardShortcut(.cancelAction)
            }
            AssetImage(path: fig.croppedImagePath, maxHeight: 520, cornerRadius: 14)
                .frame(maxWidth: .infinity)
            if !fig.caption.isEmpty {
                Text(fig.caption).font(.system(size: 13)).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Button {
                    onClose()
                    vm.openReader(figure: fig)
                } label: { Label("Im Reader zeigen", systemImage: "text.viewfinder") }
                .glassButton(prominent: true)
                Button { NSPasteboard.copy(fig.croppedImagePath); vm.showToast("Pfad kopiert") } label: { Label("Pfad", systemImage: "doc.on.doc") }
                    .glassButton()
                Button { NSPasteboard.copy(Self.latex(fig)); vm.showToast("LaTeX kopiert") } label: { Label("LaTeX", systemImage: "curlybraces") }
                    .glassButton()
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: fig.croppedImagePath)]) } label: { Label("Finder", systemImage: "folder") }
                    .glassButton()
                Spacer()
            }
        }
        .padding(22)
        .frame(width: 760)
    }
}

// MARK: - Library

struct LibraryView: View {
    @Bindable var vm: AppViewModel
    @State private var filter = ""
    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 12)]

    private var filteredDocs: [LibraryDocument] {
        let base = vm.hasSelection ? vm.scopedDocuments : vm.documents
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return base }
        return base.filter { CortexTextSanitizer.displayTitle($0.title).lowercased().contains(f) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bibliothek").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text("\(vm.documents.count) Dokumente · \(vm.documents.reduce(0) { $0 + $1.pageCount }) Seiten · \(vm.documents.reduce(0) { $0 + $1.figureCount }) Abb.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                        TextField("Filtern", text: $filter).textFieldStyle(.plain)
                    }
                    .frame(minWidth: 80, maxWidth: 180)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .glassSurface(cornerRadius: 16)
                    Button { vm.importViaPanel() } label: { Image(systemName: "plus") }
                        .glassButton(prominent: true)
                        .help("PDFs oder Ordner importieren")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

                if filteredDocs.isEmpty {
                    ContentUnavailableView("Keine Dokumente", systemImage: "books.vertical",
                                           description: Text("Ziehe PDFs oder Ordner auf eine Sammlung in der Seitenleiste."))
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(vm.collections.filter { col in filteredDocs.contains { $0.collectionID == col.id } }) { col in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(col.name.uppercased())
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.secondary)
                                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                                        ForEach(filteredDocs.filter { $0.collectionID == col.id }) { doc in
                                            DocumentCard(doc: doc, selected: vm.libraryDocumentID == doc.id,
                                                         inScope: vm.selectedDocumentIDs.contains(doc.id))
                                                .onTapGesture { withAnimation(Theme.spring) { vm.libraryDocumentID = doc.id } }
                                                .simultaneousGesture(TapGesture(count: 2).onEnded { vm.openReader(document: doc) })
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.bottom, 24)
                    }
                }
            }

            if let doc = vm.document(id: vm.libraryDocumentID) {
                DocumentInspector(vm: vm, doc: doc)
                    .frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
                    .padding([.top, .bottom, .trailing], 14)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Theme.spring, value: vm.libraryDocumentID)
    }
}

struct DocumentCard: View {
    let doc: LibraryDocument
    let selected: Bool
    let inScope: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Theme.accent.opacity(0.12))
                Image(systemName: "doc.richtext.fill").foregroundStyle(Theme.accent)
            }
            .frame(width: 36, height: 44)
            VStack(alignment: .leading, spacing: 5) {
                Text(CortexTextSanitizer.displayTitle(doc.title))
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Label("\(doc.pageCount)", systemImage: "book.pages")
                    Label("\(doc.chunkCount)", systemImage: "text.alignleft")
                    Label("\(doc.figureCount)", systemImage: "photo")
                }
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 0)
            if !FileManager.default.fileExists(atPath: doc.filePath) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
                    .help("PDF-Datei nicht gefunden – verschoben oder gelöscht. Suche funktioniert weiter, der Reader nicht.")
            } else if inScope {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            }
        }
        .padding(12)
        .contentCard(cornerRadius: 14, highlighted: selected || hovering)
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help("Doppelklick öffnet den Reader")
    }
}

struct DocumentInspector: View {
    @Bindable var vm: AppViewModel
    let doc: LibraryDocument
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CortexTextSanitizer.displayTitle(doc.title))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .lineLimit(3)
                    Text(vm.collectionName(doc.collectionID))
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { vm.libraryDocumentID = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                stat("\(doc.pageCount)", "Seiten")
                stat("\(doc.chunkCount)", "Abschnitte")
                stat("\(doc.figureCount)", "Abb.")
            }

            VStack(spacing: 8) {
                Button { vm.openReader(document: doc) } label: {
                    Label("Im Reader öffnen", systemImage: "book.pages").frame(maxWidth: .infinity)
                }
                .glassButton(prominent: true)
                HStack(spacing: 8) {
                    Button {
                        vm.selectOnly(documentID: doc.id)
                        vm.activeTab = .ask
                    } label: { Label("Hier suchen", systemImage: "scope").frame(maxWidth: .infinity) }
                    .glassButton()
                    Button {
                        vm.toggleDocument(doc.id)
                    } label: {
                        Label(vm.selectedDocumentIDs.contains(doc.id) ? "Abwählen" : "Auswählen",
                              systemImage: vm.selectedDocumentIDs.contains(doc.id) ? "minus.circle" : "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .glassButton()
                }
            }
            .controlSize(.regular)

            Divider()

            Text("INHALT").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.secondary)
            if doc.toc.isEmpty {
                Text("Keine Gliederung erkannt.").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(doc.toc) { item in
                            Button { vm.openReader(document: doc, page: item.pageNumber) } label: {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(item.title)
                                        .font(.system(size: 12, weight: item.level <= 1 ? .semibold : .regular))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                        .padding(.leading, CGFloat(max(0, item.level - 1)) * 12)
                                    Spacer(minLength: 6)
                                    Text("\(item.pageNumber)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Spacer(minLength: 0)
            Divider()
            HStack {
                Menu {
                    Button("In Vorschau öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: doc.filePath)) }
                    Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: doc.filePath)]) }
                    Button("Dokument-ID kopieren") { NSPasteboard.copy(doc.id) }
                    Button("Neu indizieren") { vm.reindex([doc]) }
                    Divider()
                    Button("Aus Bibliothek entfernen …", role: .destructive) { confirmDelete = true }
                } label: { Label("Mehr", systemImage: "ellipsis.circle") }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .fixedSize()
                Spacer()
                if let ts = doc.indexedAt {
                    Text("Indiziert \(Date(timeIntervalSince1970: ts).formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .glassSurface(cornerRadius: Theme.radiusLarge)
        .confirmationDialog(
            "„\(CortexTextSanitizer.displayTitle(doc.title))“ aus der Bibliothek entfernen?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Dokument entfernen", role: .destructive) {
                vm.deleteDocument(doc)
            }
        } message: {
            Text("Die PDF-Datei auf der Festplatte bleibt unverändert erhalten. Es werden lediglich die Chunks, Vektoren und Abbildungen aus dem Suchindex gelöscht.")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded).monospacedDigit())
            Text(LocalizedStringKey(label)).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
