import Foundation

/// Language-dependent word lists for the rule-based parts of CortexRAG (the embeddings themselves are multilingual).
/// `ContentLanguage.mixed` combines German and English.
public struct LanguageRules: Sendable {
    public let questionStarts: [String]
    public let questionCues: [String]
    public let stopWords: Set<String>
    public let numericCues: [String]
    public let numericUnits: [String]
    public let followUpInstructionWords: Set<String>
    public let ellipticStarts: [String]

    /// Rough language guess from function words ("the/and/how" vs. "der/und/wie"). Returns nil when unclear.
    public static func detectLanguage(_ text: String) -> ContentLanguage? {
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
        let en: Set<String> = ["the", "and", "how", "what", "which", "why", "is", "are", "of", "for", "with", "does", "do", "in", "to", "treated", "treatment", "about", "when", "should", "can"]
        let de: Set<String> = ["der", "die", "das", "und", "wie", "was", "welche", "warum", "ist", "sind", "von", "für", "mit", "bei", "wird", "werden", "zu", "den", "dem", "kann", "soll"]
        let e = words.filter { en.contains($0) }.count
        let d = words.filter { de.contains($0) }.count
        if e == d { return nil }
        return e > d ? .english : .german
    }

    public static func current() -> LanguageRules { Self.for(CortexSettingsManager.shared.settings.contentLanguage) }

    public static func `for`(_ language: ContentLanguage) -> LanguageRules {
        switch language {
        case .german: return .german
        case .english: return .english
        case .mixed: return .german.merged(with: .english)
        }
    }

    private func merged(with o: LanguageRules) -> LanguageRules {
        LanguageRules(
            questionStarts: questionStarts + o.questionStarts,
            questionCues: questionCues + o.questionCues,
            stopWords: stopWords.union(o.stopWords),
            numericCues: numericCues + o.numericCues,
            numericUnits: numericUnits + o.numericUnits,
            followUpInstructionWords: followUpInstructionWords.union(o.followUpInstructionWords),
            ellipticStarts: ellipticStarts + o.ellipticStarts
        )
    }

    public static let german = LanguageRules(
        questionStarts: ["wie ", "was ", "welche", "warum ", "weshalb ", "wieso ", "wann ", "wo ", "wer ", "gibt es", "ist ", "sind ", "kann ", "können ", "muss ", "soll "],
        questionCues: ["dosierung", "therapie", "behandlung", "unterschied", "erkläre", "zusammenfassung", "ursache", "symptome", "diagnose"],
        stopWords: ["der", "die", "das", "und", "oder", "in", "im", "von", "zu", "mit", "auf", "für", "ist", "sind", "bei", "ein", "eine",
                    "einer", "einem", "den", "dem", "des", "wie", "was", "wann", "welche", "welcher", "welches", "wird", "werden", "nicht"],
        numericCues: ["dosierung", "dosis", "wie viel", "grenzwert", "dauer", "spiegel", "menge"],
        numericUnits: ["mg", "ml", "µg", "mmol", "tag", "täglich", "woche", "max", "initial", "dosis", "%"],
        followUpInstructionWords: [
            "bitte", "kurz", "kürzer", "kurze", "zusammen", "zusammenfassen", "fasse", "erkläre", "erklär", "erklären", "genauer",
            "ausführlicher", "einfacher", "nochmal", "noch", "mal", "tabelle", "liste", "stichpunkte", "beispiel", "beispiele",
            "warum", "wieso", "weshalb", "welche", "welcher", "welches", "meinst", "bedeutet", "heißt", "unterschied", "mehr",
            "details", "dazu", "davon", "darüber", "diese", "dieser", "dieses", "deine", "antwort", "quelle", "quellen", "punkt",
            "zweiten", "ersten", "dritten", "letzten", "satz", "sätzen", "wort", "wörtern", "form", "format", "mach", "mache",
            "schreibe", "schreib", "gibt", "gib", "auch", "also", "eher", "sehr", "wirklich", "genau", "richtig", "bezug", "über",
            "englisch", "deutsch", "übersetze"
        ],
        ellipticStarts: ["und ", "aber ", "bei ", "auch ", "was ist mit", "wie ist es", "wie sieht es", "und was", "oder "]
    )

    public static let english = LanguageRules(
        questionStarts: ["how ", "what ", "which", "why ", "when ", "where ", "who ", "is ", "are ", "can ", "does ", "do ", "should ", "is there"],
        questionCues: ["dose", "dosage", "treatment", "therapy", "difference", "explain", "summary", "cause", "symptoms", "diagnosis"],
        stopWords: ["the", "and", "for", "with", "of", "in", "on", "to", "a", "an", "is", "are", "be", "by", "or", "at", "as", "it",
                    "how", "what", "which", "when", "why", "does", "do", "this", "that", "not"],
        numericCues: ["dose", "dosage", "how much", "threshold", "duration", "level", "amount"],
        numericUnits: ["mg", "ml", "µg", "mmol", "daily", "per day", "week", "max", "initial", "%"],
        followUpInstructionWords: [
            "please", "short", "shorter", "summarize", "summarise", "summary", "explain", "simpler", "detail", "details", "more",
            "again", "table", "list", "bullet", "bullets", "example", "examples", "why", "which", "mean", "means", "difference",
            "this", "that", "these", "your", "answer", "source", "sources", "point", "first", "second", "third", "last",
            "sentence", "sentences", "word", "words", "format", "make", "write", "give", "also", "really", "exactly", "about",
            "german", "english", "translate"
        ],
        ellipticStarts: ["and ", "but ", "what about", "how about", "also ", "or ", "and what", "in "]
    )
}
