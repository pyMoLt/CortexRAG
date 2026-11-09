import Foundation

/// Per-document statistics used to strip repeated slide footers, running headers and logo OCR.
public struct DocumentTextProfile: Sendable, Equatable {
    /// Lines that repeat across many chunks of the document (dates, institute names, logos).
    public var boilerplateLines: Set<String>
    /// Running header merged into lines, e.g. "Lecture Notes Distributed Systems".
    public var headerPrefix: String?

    public init(boilerplateLines: Set<String> = [], headerPrefix: String? = nil) {
        self.boilerplateLines = boilerplateLines
        self.headerPrefix = headerPrefix
    }

    public static let empty = DocumentTextProfile()

    /// Builds the profile from all chunk texts of one document.
    public static func build(from chunks: [String]) -> DocumentTextProfile {
        let n = chunks.count
        guard n >= 4 else { return .empty }
        var lineFreq: [String: Int] = [:]
        var prefixFreq: [Int: [String: Int]] = [:]
        for chunk in chunks {
            let lines = ChunkDisplayCleaner.rawLines(chunk)
            for line in Set(lines) { lineFreq[line, default: 0] += 1 }
            var seenPrefixes: Set<String> = []
            for line in lines {
                let words = line.split(separator: " ")
                for k in 2...5 where words.count > k {
                    let p = words.prefix(k).joined(separator: " ")
                    if seenPrefixes.insert("\(k)|\(p)").inserted {
                        prefixFreq[k, default: [:]][p, default: 0] += 1
                    }
                }
            }
        }

        var boilerplate: Set<String> = []
        for (line, count) in lineFreq where count >= 3 {
            let share = Double(count) / Double(n)
            if share >= 0.5 || (share >= 0.2 && (ChunkDisplayCleaner.isDateLike(line) || ChunkDisplayCleaner.isGarbled(line) || line.count <= 3)) {
                boilerplate.insert(line)
            }
        }

        // Longest prefix (2–5 words) that starts lines in at least half of all chunks.
        var header: String?
        for k in stride(from: 5, through: 2, by: -1) {
            if let (p, count) = prefixFreq[k]?.max(by: { $0.value < $1.value }), Double(count) / Double(n) >= 0.5 {
                header = p
                break
            }
        }
        return DocumentTextProfile(boilerplateLines: boilerplate, headerPrefix: header)
    }
}

/// Display-only cleanup of chunk text. Indexed text, LLM context and MCP output stay untouched.
public enum ChunkDisplayCleaner {
    // Symbol/Wingdings code points as extracted from PDFs (private use area) and common bullet glyphs.
    private static let bulletGlyphs: Set<UInt32> = [0xF0A7, 0xF0D8, 0xF076, 0xF0B7, 0xF06C, 0xF06E, 0xF0A8, 0xF02D, 0x25AA, 0x25A0, 0x25E6, 0x25CF, 0x2756, 0x27A2, 0x25BA, 0x2023]
    private static let arrowGlyphs: Set<UInt32> = [0xF0E0, 0xF0DE, 0xF0F0, 0xF0E8, 0xF0D5, 0xF061, 0x21D2, 0x2794, 0x279C]
    private static let checkGlyphs: Set<UInt32> = [0xF0FC, 0xF0FB]
    /// Wingdings bullets that PDF text extraction maps to Latin letters at the start of a line.
    private static let wingdingsLeaders: [String: String] = ["Ø ": "• ", "à ": "→ ", "§ ": "• ", "ü ": "✓ ", "Ÿ ": "• ", "¨ ": "• "]

    static func rawLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func isDateLike(_ line: String) -> Bool {
        let patterns = [
            #"^([A-Za-zÄÖÜäöüß]+,\s*)?\d{1,2}\.\d{1,2}\.\d{2,4}$"#,                 // 25.11.2025, Berlin, 28.10.2025
            #"^\d{1,2}/\d{1,2}/\d{2,4}$"#,                                         // 10/17/2025
            #"^\d{4}-\d{2}-\d{2}$"#,                                               // 2025-10-17
            #"(?i)^(\d{1,2}\.?\s+)?(jan|feb|mär|mar|apr|mai|may|jun|jul|aug|sep|okt|oct|nov|dez|dec)[a-zä]{0,6}\.?\s+(\d{1,2},?\s+)?\d{4}$"#  // 17. Oktober 2025, Oct 17, 2025
        ]
        return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
    }

    /// OCR noise from logos and scans: tokens with symbols inside words or no vowels at all.
    public static func isGarbled(_ line: String) -> Bool {
        let tokens = line.split(separator: " ").map(String.init).filter { $0.count >= 3 }
        guard !tokens.isEmpty else { return false }
        let weird = tokens.filter { token in
            let inner = token.dropFirst().dropLast()
            if inner.contains(where: { "%*[]{}<>|\\^~&$#@".contains($0) }) { return true }
            let letters = token.filter(\.isLetter)
            if letters.count >= 5 && !letters.lowercased().contains(where: { "aeiouyäöü".contains($0) }) { return true }
            // Case flips like "univERSITY" or "instiTuTeLogo" inside one token
            var flips = 0
            var prevUpper: Bool?
            for ch in token where ch.isLetter {
                let up = ch.isUppercase
                if let p = prevUpper, p != up { flips += 1 }
                prevUpper = up
            }
            return flips >= 4
        }
        return Double(weird.count) / Double(tokens.count) >= 0.5
    }

    /// Cleans one chunk for reading. `page` removes a trailing page number that matches the chunk's page.
    public static func clean(_ text: String, page: Int? = nil, profile: DocumentTextProfile = .empty) -> String {
        var lines: [String] = []
        for raw in rawLines(text) {
            var line = normalizeGlyphs(raw)
            if profile.boilerplateLines.contains(raw) || profile.boilerplateLines.contains(line) { continue }
            if let header = profile.headerPrefix, line.hasPrefix(header) {
                line = String(line.dropFirst(header.count)).trimmingCharacters(in: .whitespaces)
            }
            line = line.replacingOccurrences(of: #"(\s*\.){4,}"#, with: " …", options: .regularExpression)
            line = line.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            // Strip leading/trailing single garbled logo tokens (e.g. "uniVERSITYiNSTiTuTeLogo Daten zu...")
            var words = line.split(separator: " ").map(String.init)
            while let firstWord = words.first, words.count > 1 && (isGarbled(firstWord) || IndexTextPreparer.isLogoOrNoiseFragment(firstWord)) {
                words.removeFirst()
            }
            while let lastWord = words.last, words.count > 1 && (isGarbled(lastWord) || IndexTextPreparer.isLogoOrNoiseFragment(lastWord)) {
                words.removeLast()
            }
            line = words.joined(separator: " ")
            if line.isEmpty || isGarbled(line) || IndexTextPreparer.isLogoOrNoiseFragment(line) { continue }
            if line.allSatisfy({ "•→✓-–·.".contains($0) || $0 == " " }) { continue }
            lines.append(line)
        }

        // Leading / trailing date stamps and page numbers from slide footers.
        while let first = lines.first, isDateLike(first) { lines.removeFirst() }
        while let last = lines.last, isDateLike(last) || isLonePageNumber(last, page: page) { lines.removeLast() }
        // "… ggf. Replikation 45": only for multi-digit pages or long lines, so "Typ 2" / "Stufe 3" survive
        if let page, var last = lines.last, last.hasSuffix(" \(page)"), String(page).count >= 2 || last.count >= 60 {
            last.removeLast(" \(page)".count)
            lines[lines.count - 1] = last
        }

        return joinDiagramLabels(joinWrappedLines(lines)).joined(separator: "\n")
    }

    private static func isLonePageNumber(_ line: String, page: Int?) -> Bool {
        guard line.count <= 4, let n = Int(line) else { return false }
        return page == nil || n == page || abs(n - (page ?? n)) <= 2
    }

    private static func normalizeGlyphs(_ line: String) -> String {
        var out = ""
        out.reserveCapacity(line.count)
        for ch in line {
            let v = ch.unicodeScalars.first?.value ?? 0
            if bulletGlyphs.contains(v) { out.append("•") }
            else if arrowGlyphs.contains(v) { out.append("→") }
            else if checkGlyphs.contains(v) { out.append("✓") }
            else if (0xE000...0xF8FF).contains(v) { out.append("•") }
            else { out.append(ch) }
        }
        for (leader, replacement) in wingdingsLeaders where out.hasPrefix(leader) {
            out = replacement + out.dropFirst(leader.count)
        }
        // "•Text" → "• Text", "• • Text" → "• Text"
        out = out.replacingOccurrences(of: #"^([•→✓])\s*(?:[•→✓]\s*)*"#, with: "$1 ", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func isBullet(_ line: String) -> Bool {
        line.hasPrefix("• ") || line.hasPrefix("→ ") || line.hasPrefix("✓ ") || line.hasPrefix("- ") || line.hasPrefix("– ")
            || line.range(of: #"^\(?\d{1,2}[\.\)]\s"#, options: .regularExpression) != nil
    }

    /// Runs of ≥3 very short label lines (diagram text) become one "a · b · c" line.
    private static func joinDiagramLabels(_ lines: [String]) -> [String] {
        func isLabel(_ l: String) -> Bool {
            let words = l.split(separator: " ").count
            return words <= 2 && l.count <= 24 && !isBullet(l) && !l.hasSuffix(".") && !l.hasSuffix(":") && !l.hasSuffix("-")
        }
        var out: [String] = []
        var run: [String] = []
        func flush() {
            if run.count >= 3 { out.append(run.joined(separator: " · ")) } else { out.append(contentsOf: run) }
            run.removeAll()
        }
        for l in lines {
            if isLabel(l) { run.append(l) } else { flush(); out.append(l) }
        }
        flush()
        return out
    }

    /// Re-joins lines that PDF extraction wrapped: hyphenation, lowercase continuation, and long prose lines.
    /// Short lines (slide titles, "Label: value" rows) keep their own line so slide structure stays readable.
    private static func joinWrappedLines(_ lines: [String]) -> [String] {
        var out: [String] = []
        var lastIsBullet = false
        for line in lines {
            guard var prev = out.last, !isBullet(line) else {
                out.append(line)
                lastIsBullet = isBullet(line)
                continue
            }
            let endsSentence = prev.hasSuffix(".") || prev.hasSuffix(":") || prev.hasSuffix("?") || prev.hasSuffix("!") || prev.hasSuffix(";")
            let first = line.first!
            let labelRow = isLabelValue(line)
            if prev.hasSuffix("-"), first.isLowercase {
                // Silbentrennung: "Indivi-" + "duums" → "Individuums"
                prev.removeLast()
                out[out.count - 1] = prev + line
            } else if !endsSentence && (
                first.isLowercase
                || (!labelRow && (prev.hasSuffix(",") || prev.hasSuffix("(") || prev.count >= 55))
                || (!labelRow && lastIsBullet && line.split(separator: " ").count <= 3)   // wrapped bullet text
                || (!labelRow && prev.count <= 25 && line.count <= 45      // narrow text boxes on slides,
                    && !isNumberedHeading(prev) && !line.hasSuffix("."))    // but not "1.1. Titel" + sentence
            ) {
                out[out.count - 1] = prev + " " + line
            } else {
                out.append(line)
                lastIsBullet = false
            }
        }
        return out
    }

    private static func isNumberedHeading(_ line: String) -> Bool {
        line.range(of: #"^\d+(\.\d+)*\.?\s"#, options: .regularExpression) != nil
    }

    /// "Consensus: Raft, Paxos" – rows of a definition list keep their own line.
    private static func isLabelValue(_ line: String) -> Bool {
        line.range(of: #"^[^:•→]{2,32}:\s+\S"#, options: .regularExpression) != nil
    }
}
