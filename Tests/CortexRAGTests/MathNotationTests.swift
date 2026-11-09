import XCTest
@testable import CortexCore

final class MathNotationTests: XCTestCase {
    func testInlineExponentsFromRealAnswer() {
        XCTAssertEqual(MathNotation.render("$10^5$ bis $10^8$ Keimen pro ml"), "10⁵ bis 10⁸ Keimen pro ml")
        XCTAssertEqual(MathNotation.render("(bis $10^4$–$10^5$/ml)"), "(bis 10⁴–10⁵/ml)")
        XCTAssertEqual(MathNotation.render("$10^{-3}$ mol"), "10⁻³ mol")
        XCTAssertEqual(MathNotation.render("Keimzahl ≥ 10^5/ml"), "Keimzahl ≥ 10⁵/ml")
    }

    func testDelimitersAndCommands() {
        XCTAssertEqual(MathNotation.render(#"\(\frac{a+b}{2}\)"#), "(a+b)/2")
        XCTAssertEqual(MathNotation.render(#"$$\text{BMI} = \frac{m}{l^2}$$"#), "BMI = m/l²")
        XCTAssertEqual(MathNotation.render(#"$K^+ \geq 5{,}5\ \text{mmol/l}$"#), "K⁺ ≥ 5,5 mmol/l")
        XCTAssertEqual(MathNotation.render(#"$37^\circ C$, $\alpha$-Rezeptor, $\Delta pH \approx 0{,}1$"#), "37°C, α-Rezeptor, ΔpH ≈ 0,1")
        XCTAssertEqual(MathNotation.render(#"\(\sqrt{x}\) und $\mathrm{HCO_3^-}$"#), "√x und HCO₃⁻")
        XCTAssertEqual(MathNotation.render(#"$\ce{CO2 + H2O <=> H2CO3}$"#), "CO₂ + H₂O ⇌ H₂CO₃")
        XCTAssertEqual(MathNotation.render(#"Na \to K, Wert \pm 2"#), "Na → K, Wert ± 2")
    }

    func testHTMLAndEntities() {
        XCTAssertEqual(MathNotation.render("H<sub>2</sub>O, Ca<sup>2+</sup>, &lt; 5 &amp; &ge; 3"), "H₂O, Ca²⁺, < 5 & ≥ 3")
    }

    func testPricesAndCodeStayUntouched() {
        XCTAssertEqual(MathNotation.render("kostet $5 und $10"), "kostet $5 und $10")
        let doc = "Text $10^5$ und `a^2` hier\n```\nx = $y^2$\n```"
        XCTAssertEqual(MathNotation.renderDocument(doc), "Text 10⁵ und `a^2` hier\n```\nx = $y^2$\n```")
        XCTAssertEqual(MathNotation.renderDocument("Keine Formel."), "Keine Formel.")
    }

    func testMultiLineDisplayMath() {
        XCTAssertEqual(MathNotation.renderDocument("Formel:\n$$\nc = \\frac{n}{V}\n$$\nEnde"), "Formel:\nc = n/V\nEnde")
    }
}
