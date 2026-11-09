import Foundation

/// Bereinigt und formatiert rohe PDF- und OCR-Textextrakte für eine saubere, artefaktfreie Anzeige in der UI.
public enum CortexTextSanitizer {

    /// Repariert doppelt dekodierte UTF-8-Namen (typisch nach dem Entpacken von ZIPs, z. B. "StÃ¶rung" oder
    /// "EinfuÌ\u{88}hrung") und normalisiert auf NFC. Liefert den Originaltext, wenn keine Reparatur nötig ist.
    public static func repairEncoding(_ input: String) -> String {
        // Filenames from APFS arrive decomposed (NFD); compose first so "Ã" is one Latin-1 scalar.
        let raw = input.precomposedStringWithCanonicalMapping
        guard raw.contains(where: { ("\u{00C2}"..."\u{00DF}").contains($0) }) else {
            return raw.precomposedStringWithCanonicalMapping
        }
        // Each character must fit into one Latin-1 byte, otherwise the string was not double-decoded.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.unicodeScalars.count)
        for scalar in raw.unicodeScalars {
            guard scalar.value <= 0xFF else { return raw.precomposedStringWithCanonicalMapping }
            bytes.append(UInt8(scalar.value))
        }
        guard let repaired = String(bytes: bytes, encoding: .utf8) else {
            return raw.precomposedStringWithCanonicalMapping
        }
        return repaired.precomposedStringWithCanonicalMapping
    }

    /// Lesbarer Anzeigetitel: Encoding repariert, Unterstriche als Leerzeichen, getrimmt.
    public static func displayTitle(_ raw: String) -> String {
        repairEncoding(raw)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Bereinigt typische PDF-Artefakte wie Trennstriche an Zeilenenden, mehrfache Leerzeichen,
    /// isolierte Zeilenumbrüche mitten im Satz und störende Fußnoten/Kopfzeilen-Fragmente.
    public static func cleanText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        
        var text = raw
        
        // 1. Windows/Mac Zeilenenden vereinheitlichen
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        
        // 2. Weiche Trennstriche und Silbentrennung über Zeilenumbrüche hinweg zusammenfügen
        // z.B. "Depres-\nsion" -> "Depression", "The- \n rapie" -> "Therapie"
        let hyphenPattern = #"([a-zA-ZäöüÄÖÜß])-[\t ]*[\n]+[\t ]*([a-zA-ZäöüÄÖÜß])"#
        if let regex = try? NSRegularExpression(pattern: hyphenPattern, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1$2")
        }
        
        // 3. Zeilenumbrüche mitten im Satz zu Leerzeichen zusammenführen, echte Absätze (2+ Umbrüche) erhalten
        let lines = text.components(separatedBy: "\n")
        var paragraphs: [String] = []
        var currentParagraph: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if !currentParagraph.isEmpty {
                    paragraphs.append(currentParagraph.joined(separator: " "))
                    currentParagraph.removeAll()
                }
            } else {
                // Wenn die Zeile wie eine neue Aufzählung oder Überschrift beginnt, neuen Absatz anfangen
                let isBullet = trimmed.starts(with: "•") || trimmed.starts(with: "- ") || trimmed.starts(with: "* ") || trimmed.range(of: #"^\d+[\.\)]\s"#, options: .regularExpression) != nil
                if isBullet && !currentParagraph.isEmpty {
                    paragraphs.append(currentParagraph.joined(separator: " "))
                    currentParagraph.removeAll()
                }
                currentParagraph.append(trimmed)
            }
        }
        if !currentParagraph.isEmpty {
            paragraphs.append(currentParagraph.joined(separator: " "))
        }
        
        text = paragraphs.joined(separator: "\n\n")
        
        // 4. Mehrfache Leerzeichen und Tabulatoren auf ein einzelnes Leerzeichen reduzieren
        let spacePattern = #"[ \t]{2,}"#
        if let regex = try? NSRegularExpression(pattern: spacePattern, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: " ")
        }
        
        // 5. Mehrfache Absatzumbrüche (> 2) auf genau zwei begrenzen
        let newlinePattern = #"\n{3,}"#
        if let regex = try? NSRegularExpression(pattern: newlinePattern, options: []) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "\n\n")
        }
        
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Teilt einen Text in einzelne vollständige Sätze auf, falls nur Kernsätze angezeigt werden sollen.
    public static func extractKeySentences(_ text: String, maxSentences: Int = 4) -> [String] {
        let cleaned = cleanText(text)
        var sentences: [String] = []
        
        cleaned.enumerateSubstrings(in: cleaned.startIndex..<cleaned.endIndex, options: [.bySentences, .localized]) { substring, _, _, stop in
            if let s = substring?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                sentences.append(s)
                if sentences.count >= maxSentences {
                    stop = true
                }
            }
        }
        
        return sentences
    }
}
