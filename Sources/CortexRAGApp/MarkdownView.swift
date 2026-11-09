import SwiftUI
import CortexCore

/// Lightweight block-level Markdown renderer for streamed LLM answers.
/// Supports headings, paragraphs, bullet/numbered lists (nested), block quotes, code blocks, tables,
/// horizontal rules and inline Markdown. Source references like `[1]` or `[1, 3]` become clickable badges.
struct MarkdownView: View {
    let text: String
    var baseSize: CGFloat = 13.5
    var onCitation: ((Int) -> Void)? = nil

    var body: some View {
        let blocks = MarkdownParser.parse(MathNotation.renderDocument(text))
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "cortex-cite", let n = Int(url.host ?? "") {
                onCitation?(n)
                return .handled
            }
            return .systemAction
        })
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            inline(content)
                .font(.system(size: headingSize(level), weight: level <= 2 ? .bold : .semibold, design: .rounded))
                .padding(.top, level <= 2 ? 6 : 3)
        case .paragraph(let content):
            inline(content)
                .font(.system(size: baseSize))
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)
        case .listItem(let ordered, let marker, let indent, let content):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Group {
                    if ordered {
                        Text(marker).font(.system(size: baseSize, weight: .semibold).monospacedDigit())
                    } else {
                        Circle().frame(width: 5, height: 5).offset(y: -2)
                    }
                }
                .foregroundStyle(Theme.accent)
                .frame(minWidth: ordered ? 18 : 10, alignment: .trailing)
                inline(content)
                    .font(.system(size: baseSize))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let content):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.5)).frame(width: 3)
                inline(content)
                    .font(.system(size: baseSize))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: baseSize - 1.5, design: .monospaced))
                    .padding(10)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .table(let header, let rows):
            table(header: header, rows: rows)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func table(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        // Cells wrap instead of scrolling horizontally, so every column stays visible.
        return Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    cell(c < header.count ? header[c] : "", header: true, striped: false)
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(c < row.count ? row[c] : "", header: false, striped: idx % 2 == 1)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
    }

    private func cell(_ content: String, header: Bool, striped: Bool) -> some View {
        inline(content)
            .font(.system(size: baseSize - 1, weight: header ? .semibold : .regular))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, header ? 6 : 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(header ? Theme.accent.opacity(0.10) : (striped ? Color.primary.opacity(0.03) : Color.clear))
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 6
        case 2: return baseSize + 3.5
        case 3: return baseSize + 1.5
        default: return baseSize
        }
    }

    private func inline(_ raw: String) -> Text {
        Text(MarkdownParser.inlineAttributed(raw, citationTint: Theme.accent))
    }
}

// MARK: - Parser

enum MarkdownBlock: Equatable {
    case heading(Int, String)
    case paragraph(String)
    case listItem(ordered: Bool, marker: String, indent: Int, content: String)
    case quote(String)
    case code(String)
    case table(header: [String], rows: [[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var codeLines: [String]? = nil
        var tableLines: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }
        func flushTable() {
            guard !tableLines.isEmpty else { return }
            let rows = tableLines
                .filter { !isTableSeparator($0) }
                .map(splitTableRow)
            if let header = rows.first {
                blocks.append(.table(header: header, rows: Array(rows.dropFirst())))
            }
            tableLines.removeAll()
        }

        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if var code = codeLines {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(code.joined(separator: "\n")))
                    codeLines = nil
                } else {
                    code.append(line)
                    codeLines = code
                }
                continue
            }
            if trimmed.hasPrefix("```") {
                flushParagraph(); flushTable()
                codeLines = []
                continue
            }
            if trimmed.hasPrefix("|") {
                flushParagraph()
                tableLines.append(trimmed)
                continue
            } else {
                flushTable()
            }
            if trimmed.isEmpty {
                flushParagraph()
                continue
            }
            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let item = parseListItem(line) {
                flushParagraph()
                blocks.append(item)
                continue
            }
            paragraph.append(trimmed)
        }
        if let code = codeLines { blocks.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushTable()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return .heading(level, rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces))
    }

    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        let indent = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 2
        let body = line.dropFirst(leading.count)
        for bullet in ["- ", "* ", "• ", "+ ", "– "] where body.hasPrefix(bullet) {
            return .listItem(ordered: false, marker: "•", indent: min(indent, 4), content: String(body.dropFirst(bullet.count)))
        }
        let digits = body.prefix(while: { $0.isNumber })
        if !digits.isEmpty, digits.count <= 3 {
            let after = body.dropFirst(digits.count)
            if after.hasPrefix(". ") || after.hasPrefix(") ") {
                return .listItem(ordered: true, marker: "\(digits).", indent: min(indent, 4), content: String(after.dropFirst(2)))
            }
        }
        return nil
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        return !stripped.isEmpty && stripped.allSatisfy { "|-:".contains($0) }
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var s = line
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Inline

    private static let citationRegex = try! NSRegularExpression(pattern: #"\[(\d{1,2}(?:\s*[,;–-]\s*\d{1,2})*)\](?!\()"#)

    /// Converts `[1]`, `[1, 2]`, `[2-4]` into links with the `cortex-cite://n` scheme.
    static func linkCitations(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in citationRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let inner = ns.substring(with: m.range(at: 1))
            var numbers: [Int] = []
            for part in inner.components(separatedBy: CharacterSet(charactersIn: ",;")) {
                let bounds = part.components(separatedBy: CharacterSet(charactersIn: "–-")).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] < 10 {
                    numbers.append(contentsOf: bounds[0]...bounds[1])
                } else if let n = bounds.first {
                    numbers.append(n)
                }
            }
            result += numbers.map { "[\($0)](cortex-cite://\($0))" }.joined(separator: "\u{2009}")
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    static func inlineAttributed(_ raw: String, citationTint: Color) -> AttributedString {
        // LLMs often use HTML line breaks inside table cells.
        let breaks = raw.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        let linked = linkCitations(breaks)
        var attr = (try? AttributedString(
            markdown: linked,
            options: .init(allowsExtendedAttributes: true, interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(raw)

        for run in attr.runs {
            guard let url = run.link else { continue }
            if url.scheme == "cortex-cite" {
                attr[run.range].foregroundColor = citationTint
                attr[run.range].font = .system(size: 11, weight: .bold, design: .rounded)
                attr[run.range].baselineOffset = 3
                attr[run.range].underlineStyle = nil
            }
        }
        return attr
    }
}
