import Foundation

/// Turns the math/LaTeX and HTML notation that language models write ("$10^5$", "\frac{a}{b}", "\geq", "H<sub>2</sub>O",
/// "&lt;") into readable Unicode text for the answer view. Lightweight on purpose: no web view or TeX engine – medical
/// answers need exponents, indices, units, Greek letters and relations, not typeset equations.
public enum MathNotation {
    /// Converts a whole Markdown answer: fenced code blocks and `inline code` stay untouched, display math that spans
    /// several lines ($$ … $$, \[ … \]) is joined into one line first.
    public static func renderDocument(_ text: String) -> String {
        guard text.contains(where: { "$\\^<&".contains($0) }) else { return text }
        var out: [String] = []
        var inFence = false
        var mathBuffer: [String]? = nil
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); out.append(line); continue }
            if inFence { out.append(line); continue }
            if var buf = mathBuffer {
                if trimmed == "$$" || trimmed == "\\]" || trimmed.hasSuffix("$$") || trimmed.hasSuffix("\\]") {
                    buf.append(trimmed.replacingOccurrences(of: #"(\$\$|\\\])$"#, with: "", options: .regularExpression))
                    out.append(latex(buf.joined(separator: " ")))
                    mathBuffer = nil
                } else {
                    buf.append(trimmed)
                    mathBuffer = buf
                }
                continue
            }
            if (trimmed.hasPrefix("$$") && !trimmed.dropFirst(2).contains("$$")) || (trimmed.hasPrefix("\\[") && !trimmed.contains("\\]")) {
                mathBuffer = [String(trimmed.dropFirst(2))]
                continue
            }
            out.append(renderOutsideCode(line))
        }
        if let buf = mathBuffer { out.append(latex(buf.joined(separator: " "))) }
        return out.joined(separator: "\n")
    }

    /// Renders a line but leaves `inline code` spans as they are.
    static func renderOutsideCode(_ line: String) -> String {
        guard line.contains("`") else { return render(line) }
        let parts = line.components(separatedBy: "`")
        return parts.enumerated().map { $0.offset % 2 == 0 ? render($0.element) : $0.element }.joined(separator: "`")
    }

    /// Converts one line of answer text (not used inside code blocks or inline code).
    public static func render(_ line: String) -> String {
        guard line.contains(where: { "$\\^<&".contains($0) }) else { return line }
        var out = html(line)
        // Display and inline math delimiters: $$…$$, \[…\], \(…\), $…$.
        out = replace(out, #"\$\$(.+?)\$\$"#) { latex($0) }
        out = replace(out, #"\\\[(.+?)\\\]"#) { latex($0) }
        out = replace(out, #"\\\((.+?)\\\)"#) { latex($0) }
        // $…$ only when it looks like math: no space just inside the dollars, and a LaTeX/maths character inside.
        // "$5 und $10" (prices) stays as it is.
        out = replace(out, #"(?<![\\\w$])\$(?!\s)([^$\n]{1,200}?)(?<!\s)\$(?![\w$])"#) { body in
            body.range(of: #"[\\^_{}=<>]|^[\d.,]+$"#, options: .regularExpression) != nil ? latex(body) : "$" + body + "$"
        }
        // LaTeX commands written without delimiters ("\geq 4,0 mmol/l", "\text{mg}").
        if out.contains("\\") { out = commands(out) }
        // Plain-text exponents: "10^5", "10^-3", "x10^{-4}".
        out = replace(out, #"(?<=[\dA-Za-z)])\^\{?(-?[\d]+)\}?"#) { raised($0) ?? "^" + $0 }
        return out
    }

    /// Body of a math expression → text.
    static func latex(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        t = t.replacingOccurrences(of: #"\\left\s*|\\right\s*|\\big[lr]?\s*|\\Big[lr]?\s*"#, with: "", options: .regularExpression)
        t = commands(t)
        // Exponents and indices: ^{…} / ^x and _{…} / _x.
        t = replace(t, #"\^\{([^{}]*)\}"#) { raised($0) ?? "^(" + $0 + ")" }
        t = replace(t, #"\^([A-Za-z0-9+\-−])"#) { raised($0) ?? "^" + $0 }
        t = replace(t, #"_\{([^{}]*)\}"#) { lowered($0) ?? $0 }
        t = replace(t, #"_([A-Za-z0-9])"#) { lowered($0) ?? $0 }
        t = t.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// LaTeX commands → characters; structural commands (\frac, \sqrt, \text, \ce) → their content.
    static func commands(_ s: String) -> String {
        var t = s
        // Text-like wrappers keep their content.
        t = replace(t, #"\\(?:text|textrm|textit|textbf|mathrm|mathit|mathbf|mathsf|operatorname|mbox)\s*\{([^{}]*)\}"#) { $0 }
        // Chemistry (mhchem): digits after element symbols become subscripts, charges superscripts.
        t = replace(t, #"\\ce\s*\{([^{}]*)\}"#) { chemistry($0) }
        // Fractions and roots (innermost first, so nesting resolves).
        for _ in 0..<3 {
            t = replace(t, #"\\[dt]?frac\s*\{([^{}]*)\}\s*\{([^{}]*)\}"#, groups: 2) { g in
                let a = latex(g[0]), b = latex(g[1])
                func wrap(_ x: String) -> String { x.range(of: #"[\s+\-−·×]"#, options: .regularExpression) != nil ? "(\(x))" : x }
                return "\(wrap(a))/\(wrap(b))"
            }
            t = replace(t, #"\\sqrt\s*\{([^{}]*)\}"#) { x in
                let v = latex(x)
                return v.count > 1 ? "√(\(v))" : "√\(v)"
            }
        }
        // ^\circ and \degree → °
        t = t.replacingOccurrences(of: #"\^\s*\{?\\circ\}?(?:\s(?=[CF]\b))?"#, with: "°", options: .regularExpression)
        for (cmd, char) in symbols {
            // A space after a letter-like symbol only ends the command (\Delta pH → ΔpH); operators keep their spacing.
            let eatsSpace = char.first.map { $0.isLetter } ?? false
            t = t.replacingOccurrences(of: #"\\"# + cmd + #"(?![A-Za-z])"# + (eatsSpace ? #"\s?"# : ""), with: char, options: .regularExpression)
        }
        // Escaped characters and spacing.
        t = t.replacingOccurrences(of: #"\\([%$&#_{}])"#, with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\\[,;:! ]|~"#, with: " ", options: .regularExpression)
        return t
    }

    static func chemistry(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "->", with: "→").replacingOccurrences(of: "<=>", with: "⇌")
        t = replace(t, #"(?<=[A-Za-z)\]])(\d+)"#) { lowered($0) ?? $0 }
        t = replace(t, #"\^\{?([0-9]*[+\-])\}?"#) { raised($0) ?? $0 }
        return t
    }

    /// HTML that models put into answers: <sup>, <sub>, entities.
    static func html(_ s: String) -> String {
        guard s.contains("<") || s.contains("&") else { return s }
        var t = replace(s, #"(?i)<sup>([^<]{1,20})</sup>"#) { raised($0) ?? "^(" + $0 + ")" }
        t = replace(t, #"(?i)<sub>([^<]{1,20})</sub>"#) { lowered($0) ?? $0 }
        let entities = ["&lt;": "<", "&gt;": ">", "&le;": "≤", "&ge;": "≥", "&amp;": "&", "&nbsp;": " ", "&plusmn;": "±",
                        "&times;": "×", "&middot;": "·", "&deg;": "°", "&micro;": "µ", "&rarr;": "→", "&larr;": "←",
                        "&uarr;": "↑", "&darr;": "↓", "&asymp;": "≈", "&ne;": "≠", "&quot;": "\"", "&#39;": "'",
                        "&alpha;": "α", "&beta;": "β", "&gamma;": "γ", "&delta;": "δ", "&mu;": "μ", "&Delta;": "Δ"]
        for (e, c) in entities { t = t.replacingOccurrences(of: e, with: c) }
        return t
    }

    // MARK: Unicode scripts

    private static let superMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "a": "ᵃ", "b": "ᵇ",
        "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "o": "ᵒ", "p": "ᵖ", "t": "ᵗ", "T": "ᵀ", " ": " ",
    ]
    private static let subMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "−": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "o": "ₒ", "x": "ₓ", "h": "ₕ",
        "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "p": "ₚ", "s": "ₛ", "t": "ₜ", "i": "ᵢ", "r": "ᵣ", "u": "ᵤ", "v": "ᵥ",
    ]

    /// Unicode superscript, or nil when a character has none (then the caller writes ^(…)).
    static func raised(_ s: String) -> String? { mapAll(s, superMap) }
    static func lowered(_ s: String) -> String? { mapAll(s, subMap) }

    private static func mapAll(_ s: String, _ map: [Character: Character]) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var out = ""
        for ch in trimmed {
            guard let m = map[ch] else { return nil }
            out.append(m)
        }
        return out
    }

    private static let symbols: [(String, String)] = [
        // relations & operators
        ("leq", "≤"), ("le", "≤"), ("geq", "≥"), ("ge", "≥"), ("neq", "≠"), ("ne", "≠"), ("approx", "≈"), ("sim", "∼"),
        ("simeq", "≃"), ("equiv", "≡"), ("propto", "∝"), ("ll", "≪"), ("gg", "≫"), ("pm", "±"), ("mp", "∓"),
        ("times", "×"), ("cdot", "·"), ("div", "÷"), ("ast", "∗"), ("circ", "∘"), ("bullet", "•"),
        // arrows
        ("rightarrow", "→"), ("to", "→"), ("leftarrow", "←"), ("gets", "←"), ("Rightarrow", "⇒"), ("Leftarrow", "⇐"),
        ("leftrightarrow", "↔"), ("Leftrightarrow", "⇔"), ("uparrow", "↑"), ("downarrow", "↓"), ("rightleftharpoons", "⇌"),
        ("longrightarrow", "⟶"), ("mapsto", "↦"),
        // greek
        ("alpha", "α"), ("beta", "β"), ("gamma", "γ"), ("delta", "δ"), ("epsilon", "ε"), ("varepsilon", "ε"), ("zeta", "ζ"),
        ("eta", "η"), ("theta", "θ"), ("vartheta", "ϑ"), ("iota", "ι"), ("kappa", "κ"), ("lambda", "λ"), ("mu", "μ"),
        ("nu", "ν"), ("xi", "ξ"), ("pi", "π"), ("rho", "ρ"), ("sigma", "σ"), ("tau", "τ"), ("upsilon", "υ"), ("phi", "φ"),
        ("varphi", "φ"), ("chi", "χ"), ("psi", "ψ"), ("omega", "ω"), ("Gamma", "Γ"), ("Delta", "Δ"), ("Theta", "Θ"),
        ("Lambda", "Λ"), ("Xi", "Ξ"), ("Pi", "Π"), ("Sigma", "Σ"), ("Phi", "Φ"), ("Psi", "Ψ"), ("Omega", "Ω"),
        // misc
        ("infty", "∞"), ("degree", "°"), ("partial", "∂"), ("nabla", "∇"), ("sum", "Σ"), ("prod", "∏"), ("int", "∫"),
        ("sqrt", "√"), ("ldots", "…"), ("dots", "…"), ("cdots", "⋯"), ("in", "∈"), ("notin", "∉"), ("subset", "⊂"),
        ("cup", "∪"), ("cap", "∩"), ("forall", "∀"), ("exists", "∃"), ("neg", "¬"), ("wedge", "∧"), ("vee", "∨"),
        ("perp", "⊥"), ("parallel", "∥"), ("angle", "∠"), ("prime", "′"), ("ell", "ℓ"), ("hbar", "ℏ"), ("checkmark", "✓"),
        ("quad", " "), ("qquad", " "), ("percent", "%"), ("textperthousand", "‰"), ("mid", "|"),
    ]

    // MARK: Regex helper

    private static func replace(_ s: String, _ pattern: String, transform: (String) -> String) -> String {
        replace(s, pattern, groups: 1) { transform($0[0]) }
    }

    private static func replace(_ s: String, _ pattern: String, groups: Int, transform: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let g = (1...groups).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += transform(g)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}
