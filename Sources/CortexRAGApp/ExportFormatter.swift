import Foundation
import AppKit
import UniformTypeIdentifiers
import CortexCore

/// Builds the export formats for answers (Markdown / LaTeX / study script) and search results (JSON / list).
@MainActor
enum ExportFormatter {
    struct Round {
        let question: String
        let answer: String
    }

    // MARK: Conversation

    static func rounds(_ vm: AppViewModel) -> [Round] {
        vm.previousTurns.map { Round(question: $0.question, answer: $0.state.answerText) }
            + (vm.synthesisState.answerText.isEmpty ? [] : [Round(question: vm.currentQuestion, answer: vm.synthesisState.answerText)])
    }

    private static func sourceLine(_ i: Int, _ r: SearchResultItem) -> String {
        "[\(i)] \(CortexTextSanitizer.displayTitle(r.documentTitle)), S. \(r.pageNumber)"
    }

    static func conversationMarkdown(_ vm: AppViewModel) -> String {
        var out = ""
        let rs = rounds(vm)
        for (i, r) in rs.enumerated() {
            out += rs.count > 1 ? "## \(i == 0 ? "Frage" : "Nachfrage"): \(r.question)\n\n" : "## \(r.question)\n\n"
            out += r.answer + "\n\n"
        }
        if !vm.conversationSources.isEmpty {
            out += "### Quellen\n\n"
            out += vm.conversationSources.enumerated().map { "- " + sourceLine($0.offset + 1, $0.element) }.joined(separator: "\n") + "\n"
        }
        return out
    }

    /// Markdown for a study script: answer, sources with the cited passages and figures of the cited pages.
    static func studyScriptMarkdown(_ vm: AppViewModel) -> String {
        var out = conversationMarkdown(vm)
        let cited = citedIndices(in: rounds(vm).map(\.answer).joined(separator: " "))
        let sources = vm.conversationSources.enumerated().filter { cited.isEmpty || cited.contains($0.offset + 1) }
        guard !sources.isEmpty else { return out }
        out += "\n### Belegstellen\n\n"
        for (i, r) in sources {
            out += "**\(sourceLine(i + 1, r))** — \(CortexTextSanitizer.displayTitle(r.breadcrumb))\n\n"
            let quote = vm.displayText(r.matchedContent, documentID: r.documentID, page: r.pageNumber)
            out += quote.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n") + "\n\n"
            for fig in r.figuresOnPage {
                out += "![\(fig.caption.isEmpty ? fig.label : fig.caption)](\(fig.croppedImagePath))\n\n"
            }
        }
        return out
    }

    static func conversationLaTeX(_ vm: AppViewModel) -> String {
        var out = ""
        for r in rounds(vm) {
            out += "\\subsection*{\(latexEscape(r.question))}\n\n"
            out += markdownToLaTeX(r.answer) + "\n\n"
        }
        if !vm.conversationSources.isEmpty {
            out += "\\paragraph{Quellen}\n\\begin{enumerate}\n"
            for r in vm.conversationSources {
                out += "  \\item \(latexEscape(CortexTextSanitizer.displayTitle(r.documentTitle))), S.~\(r.pageNumber)\n"
            }
            out += "\\end{enumerate}\n"
        }
        return out
    }

    // MARK: Search results

    static func resultsJSON(_ vm: AppViewModel) -> String {
        let items: [[String: Any]] = vm.searchResults.map { r in
            [
                "rank": r.rank, "score": r.score, "chunk_id": r.chunkID,
                "document": CortexTextSanitizer.displayTitle(r.documentTitle), "document_id": r.documentID,
                "pdf_path": r.documentPath, "page": r.pageNumber,
                "section": CortexTextSanitizer.displayTitle(r.breadcrumb),
                "text": vm.displayText(r.matchedContent, documentID: r.documentID, page: r.pageNumber),
                "figures": r.figuresOnPage.map { ["label": $0.label, "caption": $0.caption, "image": $0.croppedImagePath] }
            ]
        }
        let obj: [String: Any] = ["query": vm.lastSubmittedQuery, "scope": vm.scopeSummary, "results": items]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func resultsMarkdownList(_ vm: AppViewModel) -> String {
        var out = "## Suchergebnisse: \(vm.lastSubmittedQuery)\n\n_Suchbereich: \(vm.scopeSummary)_\n\n"
        for r in vm.searchResults {
            out += "\(r.rank). **\(CortexTextSanitizer.displayTitle(r.documentTitle))**, S. \(r.pageNumber) — \(CortexTextSanitizer.displayTitle(r.breadcrumb))\n"
            let text = vm.displayText(r.matchedContent, documentID: r.documentID, page: r.pageNumber)
            out += text.split(separator: "\n").map { "   > \($0)" }.joined(separator: "\n") + "\n\n"
        }
        return out
    }

    // MARK: Helpers

    static func citedIndices(in text: String) -> Set<Int> {
        let regex = try! NSRegularExpression(pattern: #"\[(\d{1,2})\]"#)
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { Int(ns.substring(with: $0.range(at: 1))) })
    }

    static func latexEscape(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "\\", with: "\\textbackslash{}")
        for (a, b) in [("&", "\\&"), ("%", "\\%"), ("$", "\\$"), ("#", "\\#"), ("_", "\\_"), ("{", "\\{"), ("}", "\\}"), ("~", "\\textasciitilde{}"), ("^", "\\textasciicircum{}")] {
            out = out.replacingOccurrences(of: a, with: b)
        }
        return out.replacingOccurrences(of: "\\textbackslash\\{\\}", with: "\\textbackslash{}")
    }

    /// Minimal Markdown → LaTeX for LLM answers: headings, lists, bold/italic, tables, citations.
    static func markdownToLaTeX(_ md: String) -> String {
        var out: [String] = []
        var inList: String?
        func closeList() {
            if let env = inList { out.append("\\end{\(env)}"); inList = nil }
        }
        var tableRows: [[String]] = []
        func flushTable() {
            guard let header = tableRows.first else { return }
            let cols = header.count
            out.append("\\begin{tabular}{" + String(repeating: "p{\(String(format: "%.2f", 0.9 / Double(max(cols, 1))))\\linewidth}", count: cols) + "}")
            out.append("\\hline")
            for (i, row) in tableRows.enumerated() {
                out.append(row.map(inline).joined(separator: " & ") + " \\\\")
                if i == 0 { out.append("\\hline") }
            }
            out.append("\\hline\n\\end{tabular}")
            tableRows = []
        }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                let stripped = line.replacingOccurrences(of: " ", with: "")
                if stripped.allSatisfy({ "|-:".contains($0) }) { continue }
                var cells = line
                if cells.hasPrefix("|") { cells.removeFirst() }
                if cells.hasSuffix("|") { cells.removeLast() }
                tableRows.append(cells.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) })
                continue
            } else {
                flushTable()
            }
            if line.hasPrefix("#") {
                closeList()
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                out.append("\\paragraph{\(inline(title))}")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                if inList != "itemize" { closeList(); out.append("\\begin{itemize}"); inList = "itemize" }
                out.append("  \\item " + inline(String(line.dropFirst(2))))
            } else if let r = line.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) {
                if inList != "enumerate" { closeList(); out.append("\\begin{enumerate}"); inList = "enumerate" }
                out.append("  \\item " + inline(String(line[r.upperBound...])))
            } else if line.isEmpty {
                closeList()
                out.append("")
            } else {
                closeList()
                out.append(inline(line))
            }
        }
        flushTable()
        closeList()
        return out.joined(separator: "\n")
    }

    private static func inline(_ s: String) -> String {
        var t = latexEscape(s.replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression))
        t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "\\\\textbf{$1}", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\*(.+?)\*"#, with: "\\\\emph{$1}", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[(\d{1,2})\]"#, with: "\\\\textsuperscript{[$1]}", options: .regularExpression)
        return t.replacingOccurrences(of: "→", with: "$\\rightarrow$").replacingOccurrences(of: "≥", with: "$\\geq$").replacingOccurrences(of: "≤", with: "$\\leq$")
    }

    // MARK: Output

    static func copy(_ text: String, vm: AppViewModel, label: String) {
        NSPasteboard.copy(text)
        vm.showToast("\(label) kopiert")
    }

    static func save(_ text: String, suggestedName: String, type: UTType, vm: AppViewModel) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            vm.showToast("Gespeichert: \(url.lastPathComponent)")
        } catch {
            vm.errorBanner = "Speichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    static func fileName(_ base: String) -> String {
        let cleaned = base.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted).joined()
        return String(cleaned.prefix(50)).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "_")
    }
}
