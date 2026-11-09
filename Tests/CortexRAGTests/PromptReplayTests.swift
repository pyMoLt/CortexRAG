import XCTest
import AppKit
@testable import CortexCore

/// Follow-ups replay earlier rounds byte for byte so the local server can answer from its prompt cache.
final class PromptReplayTests: XCTestCase {
    func testImageEncodingIsDeterministic() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("replay_\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let img = NSImage(size: NSSize(width: 1600, height: 900), flipped: false) { r in
            NSColor.systemTeal.setFill(); r.fill()
            NSColor.black.setFill(); NSRect(x: 100, y: 100, width: 600, height: 300).fill()
            return true
        }
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(img.tiffRepresentation)))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        let a = try XCTUnwrap(CortexLLMService.jpegDataURL(url.path))
        let b = try XCTUnwrap(CortexLLMService.jpegDataURL(url.path))
        XCTAssertEqual(a, b, "same image must encode to the same bytes, otherwise the prompt prefix changes")
    }

    func testExchangeKeepsImagesAndRawAnswer() throws {
        let ex = ConversationExchange(question: "q", answer: "Antwort", fullPrompt: "Frage …",
                                      promptImages: [.init(index: 2, path: "/x.png")], rawAnswer: "Antwort\n")
        let data = try JSONEncoder().encode(ex)
        XCTAssertEqual(try JSONDecoder().decode(ConversationExchange.self, from: data), ex)
    }
}
