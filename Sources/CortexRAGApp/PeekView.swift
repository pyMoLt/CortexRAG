import SwiftUI
import PDFKit
import AppKit
import CortexCore

/// Quick-Look-style preview of a search hit (space bar): the document itself, scrollable and marked at the passage
/// or figure, next to the passage with its surrounding text. ↑/↓ steps through the hits, ↩ opens the reader.
struct PeekView: View {
    @Bindable var vm: AppViewModel
    let item: SearchResultItem
    let onClose: () -> Void
    let onStep: (Int) -> Void

    @State private var controller = ReaderController()
    @State private var showPassage = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            HStack(spacing: 0) {
                document
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showPassage {
                    Divider().opacity(0.5)
                    passage
                        .frame(width: 210)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 12)
        .background {
            Button("") { onClose() }
                .keyboardShortcut(.space, modifiers: [])
                .hidden()
        }
        .onChange(of: item.id, initial: true) { _, _ in load() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: item.isFigure ? "photo" : "doc.text.magnifyingglass")
                .foregroundStyle(item.isFigure ? Theme.figure : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(CortexTextSanitizer.displayTitle(item.documentTitle))
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Text("Seite \(item.pageNumber) · \(sectionName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !controller.lastJumpMatchedExactly {
                Label("Stelle nicht exakt gefunden", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                Button { controller.zoom(-0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Verkleinern")
                Button {
                    controller.fitWidth(margin: 20)
                } label: {
                    Text("\(controller.zoomPercent) %")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .frame(minWidth: 42)
                }
                .help("Auf Seitenbreite einpassen (oder per Trackpad zoomen)")
                Button { controller.zoom(0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Vergrößern")
            }
            .buttonStyle(.borderless)
            Divider().frame(height: 14)
            HStack(spacing: 4) {
                Button { onStep(-1) } label: { Image(systemName: "chevron.up") }
                    .help("Vorheriger Treffer (↑)")
                Button { onStep(1) } label: { Image(systemName: "chevron.down") }
                    .help("Nächster Treffer (↓)")
            }
            .buttonStyle(.borderless)
            Button {
                withAnimation(Theme.quick) { showPassage.toggle() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    controller.fitWidth(margin: 20)
                }
            } label: {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(showPassage ? Theme.accent : .secondary)
            }
            .buttonStyle(.borderless)
            .help(showPassage ? "Textspalte ausblenden" : "Textspalte einblenden")
            Menu {
                Button("In Vorschau öffnen") { NSWorkspace.shared.open(URL(fileURLWithPath: item.documentPath)) }
                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.documentPath)]) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button {
                openReader()
            } label: {
                Label("Im Reader öffnen", systemImage: "arrow.up.forward.app")
            }
            .glassButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            Button(action: onClose) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Schließen (Leertaste oder Esc)")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var sectionName: String {
        let parts = CortexTextSanitizer.displayTitle(item.breadcrumb).components(separatedBy: " > ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " › ") : item.collectionName
    }

    // MARK: Document

    @ViewBuilder
    private var document: some View {
        if FileManager.default.fileExists(atPath: DocumentFormats.readablePDFPath(for: item.documentPath)) {
            PDFKitHost(pdfView: controller.pdfView)
        } else {
            ContentUnavailableView("Datei nicht gefunden", systemImage: "doc.questionmark",
                                   description: Text(item.documentPath))
        }
    }

    // MARK: Passage with context

    private var passage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let fig = item.figure {
                    AssetImage(path: fig.croppedImagePath, maxHeight: 190, cornerRadius: 10)
                    Label(fig.label, systemImage: "photo")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.figure)
                    if !fig.caption.isEmpty { Text(fig.caption).font(.system(size: 11.5)) }
                    if !fig.surroundingContext.isEmpty {
                        contextText(vm.displayText(fig.surroundingContext, documentID: item.documentID, page: item.pageNumber))
                    }
                } else {
                    if !item.contextBefore.isEmpty {
                        contextText(vm.displayText(item.contextBefore, documentID: item.documentID))
                    }
                    Text(vm.displayText(item.matchedContent, documentID: item.documentID, page: item.pageNumber))
                        .font(.system(size: 13, weight: .regular))
                        .lineSpacing(3)
                        .padding(9)
                        .background(Color.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    if !item.contextAfter.isEmpty {
                        contextText(vm.displayText(item.contextAfter, documentID: item.documentID))
                    }
                }
            }
            .textSelection(.enabled)
            .padding(12)
        }
    }

    private func contextText(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineSpacing(2.5)
    }

    // MARK: Actions

    private func load() {
        controller.load(path: item.documentPath)
        DispatchQueue.main.async { applyJumpAndZoom() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { applyJumpAndZoom() }
    }

    private func applyJumpAndZoom() {
        controller.fitWidth(margin: 20)
        if let fig = item.figure {
            controller.highlightFigure(bbox: fig.bbox, page: item.pageNumber)
        } else {
            controller.jump(page: item.pageNumber, text: item.matchedContent)
        }
    }

    private func openReader() {
        if let fig = item.figure { vm.openReader(figure: fig) } else { vm.openReader(result: item) }
        onClose()
    }
}
