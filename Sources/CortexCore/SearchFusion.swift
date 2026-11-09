import Foundation

/// What a search returns: passages and figures together (default), or only one kind.
public enum SearchContentMode: String, Codable, CaseIterable, Sendable {
    case all, text, figures

    public var displayName: String {
        switch self {
        case .all: return "Alles"
        case .text: return "Text"
        case .figures: return "Bilder"
        }
    }

    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .text: return "text.alignleft"
        case .figures: return "photo"
        }
    }
}

/// Merges text and figure hits by rank (reciprocal rank fusion). Raw scores of the two kinds are not
/// comparable: text-to-image similarities sit systematically lower than text-to-text. Ranks are.
public enum SearchFusion {
    /// - Parameters:
    ///   - minFigureScore: figures below this similarity do not take part (a figure list is never empty,
    ///     even when nothing fits; without this floor text and images would simply alternate).
    ///   - k: RRF constant; 60 is the common default.
    public static func fuse(
        text: [SearchResultItem],
        figures: [FigureResultItem],
        mode: SearchContentMode,
        topK: Int,
        minFigureScore: Double,
        k: Double = 60,
        allFiguresByPage: [String: [FigureResultItem]] = [:]
    ) -> [SearchResultItem] {
        switch mode {
        case .text:
            return renumber(Array(text.prefix(topK)))
        case .figures:
            return renumber(figures.prefix(topK).enumerated().map { i, f in
                let pageFigs = allFiguresByPage["\(f.documentID)#\(f.pageNumber)"]
                return SearchResultItem(figureHit: f, rank: i + 1, score: f.score, allFiguresOnPage: pageFigs)
            })
        case .all:
            break
        }
        let eligible = figures.filter { $0.score >= minFigureScore }
        var scored: [(item: SearchResultItem, rrf: Double)] = text.enumerated().map { i, t in (t, 1 / (k + Double(i + 1))) }
        var figureRank = 0
        for f in eligible {
            // The page is already a text hit: its card shows the page's figures, a second card would repeat it.
            if text.contains(where: { $0.documentID == f.documentID && $0.pageNumber == f.pageNumber }) { continue }
            figureRank += 1
            let pageFigs = allFiguresByPage["\(f.documentID)#\(f.pageNumber)"]
            let hit = SearchResultItem(figureHit: f, rank: 0, score: f.score, allFiguresOnPage: pageFigs)
            scored.append((hit, 1 / (k + Double(figureRank))))
        }
        // Stable: on equal fusion score the text hit stays first.
        let ordered = scored.enumerated().sorted { a, b in
            a.element.rrf != b.element.rrf ? a.element.rrf > b.element.rrf : a.offset < b.offset
        }.map(\.element.item)
        return renumber(Array(ordered.prefix(topK)))
    }

    private static func renumber(_ items: [SearchResultItem]) -> [SearchResultItem] {
        items.enumerated().map { i, item in
            var c = item
            c.rank = i + 1
            return c
        }
    }
}
