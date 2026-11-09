import Foundation

/// Cleans page text before it is chunked, embedded and indexed, so that search vectors, keyword index and the
/// AI context all see readable content instead of slide footers, logo OCR and broken lines.
/// Builds on `ChunkDisplayCleaner` (same rules as the reading view) and adds index-only rules.
public enum IndexTextPreparer {
    /// Cleans one page. `profile` comes from all pages of the document (repeated footers, dates, logo text).
    public static func cleanPage(_ text: String, page: Int, profile: DocumentTextProfile) -> String {
        // Axis ticks of charts ("5.000 / 4.500 / 4.000") carry no meaning once the chart is text; drop them first,
        // otherwise the diagram-label rule would glue them into one long line.
        let withoutTicks = dropNumberRuns(ChunkDisplayCleaner.rawLines(text)).joined(separator: "\n")
        let cleaned = ChunkDisplayCleaner.clean(withoutTicks, page: page, profile: profile)
        return cleaned.components(separatedBy: "\n")
            .map(stripForeignScriptNoise)
            .filter {
                !$0.isEmpty
                    && !isCreditLine($0)
                    && !isPageNumberOnly($0)
                    && !isSymbolScrap($0)
                    && !isLogoOrNoiseFragment($0)
            }
            .joined(separator: "\n")
    }

    static func isNumberOnly(_ line: String) -> Bool {
        line.range(of: #"^[\d.,\s%‰€$+\-–]+$"#, options: .regularExpression) != nil
    }

    /// Runs of three or more number-only lines (chart axes, value columns).
    static func dropNumberRuns(_ lines: [String]) -> [String] {
        var out: [String] = []
        var run: [String] = []
        func flush() {
            if run.count < 3 { out += run }
            run.removeAll()
        }
        for l in lines {
            if isNumberOnly(l) { run.append(l) } else { flush(); out.append(l) }
        }
        flush()
        return out
    }

    /// Short OCR leftovers without letters ("30.,", "-.") – percentages and real numbers with units stay.
    static func isSymbolScrap(_ line: String) -> Bool {
        guard line.count <= 5, !line.contains(where: \.isLetter), !line.contains("%") else { return false }
        return line.contains(where: { ".,;:-'\"/".contains($0) })
    }

    /// Detects recurring institutional or slide logo OCR artefacts such as "ılogo" (dotless Turkish ı from slide header logos).
    public static func isLogoOrNoiseFragment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        if lower == "ılogo" || lower == "ilogo" || lower == "institutelogo" { return true }
        if lower.range(of: #"^[ıi1l|!·•\-_]{0,3}(logo|inst|univ)$"#, options: .regularExpression) != nil { return true }
        // Short single token with Turkish dotless 'ı' (U+0131) in German/English text is almost always logo OCR noise.
        if trimmed.count <= 10 && !trimmed.contains(" ") && trimmed.unicodeScalars.contains(where: { $0.value == 0x0131 }) {
            return true
        }
        return false
    }

    /// Photo credits and stock-image notices carry no content ("© fotolia.com", "@ BillionPhotos.com I fotolia").
    public static func isCreditLine(_ line: String) -> Bool {
        let l = line.lowercased()
        let stock = ["fotolia", "shutterstock", "istock", "adobe stock", "adobestock", "pixabay", "unsplash", "getty images",
                     "gettyimages", "depositphotos", "123rf", "dreamstime", "billionphotos", "colourbox", "freepik", "clipart"]
        if stock.contains(where: l.contains) { return true }
        if l.hasPrefix("©") || l.hasPrefix("(c) ") || l.hasPrefix("@ ") { return line.count <= 90 }
        if l.hasPrefix("bildquelle") || l.hasPrefix("foto:") || l.hasPrefix("fotos:") || l.hasPrefix("abbildung mit freundlicher") { return true }
        // Publisher/licence footers of e-books ("© 2024 Academic Press KG", "All rights reserved", ISBN lines).
        let licence = ["all rights reserved", "usage subject to terms", "dieses dokument ist nur für den", "verlag kg", "isbn 978", "isbn: 978"]
        return licence.contains(where: l.contains) || (l.contains("©") && line.count <= 220)
    }

    private static func isPageNumberOnly(_ line: String) -> Bool {
        line.count <= 4 && Int(line) != nil
    }

    /// OCR of lecture slides occasionally emits Cyrillic/Greek look-alikes ("30 мо.") or logo tokens ("ılogo").
    /// Such tokens are dropped unless the line is mostly in that script (real Greek formulas, e.g. "α-divergence", stay).
    static func stripForeignScriptNoise(_ line: String) -> String {
        let rawTokens = line.split(separator: " ", omittingEmptySubsequences: false)
        let tokens = rawTokens.filter { !isLogoOrNoiseFragment(String($0)) }
        guard !tokens.isEmpty else { return "" }
        let cleanedLine = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        func isForeign(_ t: Substring) -> Bool {
            t.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        }
        let foreign = tokens.filter(isForeign)
        guard !foreign.isEmpty else { return cleanedLine }
        // A short line that is mostly look-alike noise ("30мо.") is dropped as a whole.
        if tokens.count <= 2 { return "" }
        guard foreign.count * 2 < tokens.count else { return cleanedLine }
        return tokens.filter { !isForeign($0) }.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Slides

    /// Outline entries that PowerPoint/Keynote exports generate without a real title.
    public static func isGenericOutlineLabel(_ title: String) -> Bool {
        title.range(of: #"(?i)^(foliennummer|folie|slide|seite|page|titel)\s*\d*$"#, options: .regularExpression) != nil
            || title.range(of: #"^\d+$"#, options: .regularExpression) != nil
    }

    private static func isSingleAllCapsWord(_ text: String) -> Bool {
        let words = text.split(separator: " ").filter { $0.filter(\.isLetter).count >= 2 }
        let letters = text.filter(\.isLetter)
        return words.count <= 1 && !letters.isEmpty && letters.allSatisfy(\.isUppercase)
    }

    /// Chooses the slide title: the OCR line with the largest glyph height near the top, mapped to the matching
    /// line of the cleaned page text (PDF text is more reliable than OCR). Falls back to the first short line,
    /// preferring multi-word lines over isolated all-caps diagram labels (e.g. "LATENCY" inside a chart).
    public static func slideTitle(cleanedPage: String, ocrCandidate: String?) -> String? {
        // A title needs words: "30.," or "5" (large numbers on a chart) are not titles.
        func isTitleLike(_ t: String) -> Bool {
            t.filter(\.isLetter).count >= 3 && !isGenericOutlineLabel(t) && !isLogoOrNoiseFragment(t)
        }
        let lines = cleanedPage.components(separatedBy: "\n").filter { !$0.isEmpty }
        let topMultiWordLine = lines.prefix(3).first { line in
            line.count <= 85
                && isTitleLike(line)
                && line.first?.isUppercase == true
                && !line.hasSuffix(".")
                && !line.hasPrefix("• ")
                && !line.hasPrefix("→ ")
                && line.split(separator: " ").count >= 2
                && !isSingleAllCapsWord(line)
        }

        if let cand = ocrCandidate?.trimmingCharacters(in: .whitespaces), isTitleLike(cand), !ChunkDisplayCleaner.isGarbled(cand) {
            if isSingleAllCapsWord(cand), let better = topMultiWordLine {
                return trimTitle(better)
            }
            let candTokens = tokens(cand)
            let best = lines.map { line -> (String, Double) in
                let lt = tokens(line)
                guard !lt.isEmpty, !candTokens.isEmpty else { return (line, 0) }
                return (line, Double(candTokens.intersection(lt).count) / Double(candTokens.count))
            }.max { $0.1 < $1.1 }
            if let best, best.1 >= 0.6 {
                if best.0.count <= 100 { return trimTitle(best.0) }
                // The title was joined with the following text: take as many words of the PDF line as the OCR line has
                // (PDF text keeps umlauts that fast OCR drops).
                let n = cand.split(separator: " ").count
                return trimTitle(best.0.split(separator: " ").prefix(n).joined(separator: " "))
            }
            if cand.count <= 100 { return trimTitle(cand) }
        }
        if let first = lines.first, isSingleAllCapsWord(first), let better = topMultiWordLine {
            return trimTitle(better)
        }
        if let first = lines.first, first.count <= 80, isTitleLike(first), !first.hasPrefix("• "), !first.hasPrefix("→ ") {
            return trimTitle(first)
        }
        return nil
    }

    private static func trimTitle(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: " :–-·"))
    }

    static func tokens(_ s: String) -> Set<String> {
        Set(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 })
    }

    /// Puts the title first (slides often extract it last) so that every chunk of the slide starts with it.
    public static func titleFirst(_ page: String, title: String?) -> String {
        guard let title, !title.isEmpty else { return page }
        var lines = page.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { trimTitle($0) == title }) {
            if i == 0 { return page }
            lines.remove(at: i)
        }
        return ([title] + lines).joined(separator: "\n")
    }

    /// Adds OCR lines (text inside images/diagrams) that are not already part of the page text.
    public static func mergeOCRLines(_ ocr: [String], into page: String) -> String {
        let known = tokens(page)
        let extra = ocr.map { $0.trimmingCharacters(in: .whitespaces) }.filter { line in
            let t = tokens(line)
            guard line.count >= 3, !t.isEmpty, !ChunkDisplayCleaner.isGarbled(line), !isCreditLine(line) else { return false }
            return Double(t.subtracting(known).count) / Double(t.count) >= 0.5
        }
        guard !extra.isEmpty else { return page }
        return page.isEmpty ? extra.joined(separator: "\n") : page + "\n" + extra.joined(separator: "\n")
    }

    // MARK: Figure captions

    /// Running page header of textbooks: page number + chapter code + chapter title,
    /// e.g. "672 F 1 Distributed Consensus in Replicated State Machines", "389 D 1.3 Vector Quantization", "30 A 2 Graph Indexing".
    public static func isRunningHeader(_ line: String) -> Bool {
        line.range(of: #"^\d{1,4}\s+[A-Z]\s*[\dIl|]+(\.[\dIl|]+)*\b"#, options: .regularExpression) != nil
            || line.range(of: #"^[A-Z]\s*\d+(\.\d+)*\s+.+\s\d{1,4}$"#, options: .regularExpression) != nil
    }

    /// Readable caption from raw text near a figure (PDF text layer or OCR): running headers, page numbers, footers
    /// and unreadable fragments are dropped, hyphenated line breaks joined, and the result is cut to `maxLength` at a
    /// sentence or word boundary. Returns nil when nothing readable remains.
    public static func cleanCaption(_ raw: String, page: Int, profile: DocumentTextProfile = .empty, maxLength: Int = 220) -> String? {
        // Ligatures ("ﬀ") and compatibility forms become plain letters; leading bullets/symbols ("⊙ F-1.6 …") go.
        let normalized = raw.precomposedStringWithCompatibilityMapping
        let lines = ChunkDisplayCleaner.rawLines(normalized)
            .map { $0.replacingOccurrences(of: #"^[^\p{L}\p{N}]+"#, with: "", options: .regularExpression) }
            .filter { !$0.isEmpty && !isRunningHeader($0) && !isLogoOrNoiseFragment($0) && !isCreditLine($0) }
        let cleaned = cleanPage(lines.joined(separator: "\n"), page: page, profile: profile)
        var text = cleaned
            .replacingOccurrences(of: #"(\p{Ll})-\n(\p{Ll})"#, with: "$1$2", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Textbook labels are often repeated in the layout ("E-6.15 ⊙ E-6.15 Raft Leader Election") and figure panels
        // leave single letters at the end ("… a b").
        text = text.replacingOccurrences(of: #"^([A-H]-\d+(?:\.\d+)*)\s+\W*\s*\1\s+"#, with: "$1 ", options: .regularExpression)
            .replacingOccurrences(of: #"(\s+[a-h])+$"#, with: "", options: .regularExpression)
        guard text.filter(\.isLetter).count >= 8, !ChunkDisplayCleaner.isGarbled(text) else { return nil }
        if text.count > maxLength {
            let cut = String(text.prefix(maxLength))
            if let end = cut.range(of: #"[.!?:](?=\s)"#, options: [.regularExpression, .backwards]), cut.distance(from: cut.startIndex, to: end.lowerBound) > maxLength / 2 {
                text = String(cut[..<end.upperBound])
            } else if let space = cut.lastIndex(of: " ") {
                text = String(cut[..<space]) + " …"
            } else {
                text = cut + " …"
            }
        }
        return text
    }

    /// Caption line of a figure or table: "Abb. 3", "Tabelle 2", "Fig. 1", or textbook numbering like "F-1.6 B-Tree Split".
    public static let captionStartPattern = #"^(Abb\.|Abbildung|Tab\.|Tabelle|Fig\.|Figure|[A-H]-\d+(\.\d+)*\s)"#

    /// The caption line (plus its continuation) inside a block of text, if there is one.
    public static func captionLine(in raw: String) -> String? {
        let lines = ChunkDisplayCleaner.rawLines(raw.precomposedStringWithCompatibilityMapping)
            .map { $0.replacingOccurrences(of: #"^[^\p{L}\p{N}]+"#, with: "", options: .regularExpression) }
        guard let i = lines.firstIndex(where: { $0.range(of: captionStartPattern, options: .regularExpression) != nil }) else { return nil }
        var caption = lines[i]
        if i + 1 < lines.count, !caption.hasSuffix("."), let next = lines[i + 1].first, next.isLowercase {
            caption += " " + lines[i + 1]
        }
        return caption
    }

    // MARK: Chunking

    /// Splits cleaned text at line, then sentence, then word boundaries (never inside a word).
    /// The overlap repeats whole trailing lines/sentences of the previous chunk.
    public static func chunk(_ text: String, target: Int, overlap: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.count <= target { return [trimmed] }

        var units: [String] = []
        for line in trimmed.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            if line.count <= target { units.append(line) } else { units += splitLong(line, target: target) }
        }

        var chunks: [String] = []
        var current: [String] = []
        var length = 0
        for unit in units {
            if length + unit.count + 1 > target, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                // Overlap: trailing units up to `overlap` characters.
                var tail: [String] = []
                var tailLength = 0
                for u in current.reversed() where tailLength + u.count <= overlap {
                    tail.insert(u, at: 0)
                    tailLength += u.count + 1
                }
                current = tail
                length = tailLength
            }
            current.append(unit)
            length += unit.count + 1
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }

    private static func splitLong(_ line: String, target: Int) -> [String] {
        // Sentences first.
        var sentences: [String] = []
        line.enumerateSubstrings(in: line.startIndex..., options: [.bySentences, .localized]) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
        }
        if sentences.isEmpty { sentences = [line] }
        var out: [String] = []
        var current = ""
        for s in sentences {
            if s.count > target {
                if !current.isEmpty { out.append(current); current = "" }
                out += splitWords(s, target: target)
            } else if current.count + s.count + 1 > target {
                out.append(current)
                current = s
            } else {
                current = current.isEmpty ? s : current + " " + s
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private static func splitWords(_ s: String, target: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for word in s.split(separator: " ") {
            if current.count + word.count + 1 > target, !current.isEmpty {
                out.append(current)
                current = String(word)
            } else {
                current = current.isEmpty ? String(word) : current + " " + word
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
