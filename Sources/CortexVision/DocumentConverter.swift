import Foundation
import AppKit
import CoreText
import CortexCore

/// Produces the cached PDF rendition of Word, PowerPoint, text and other documents.
public enum DocumentConverter {
    public struct ConversionError: Error, CustomStringConvertible {
        public let description: String
    }

    /// Returns a PDF for `url`: the file itself for PDFs, otherwise a cached rendition that is refreshed
    /// whenever the original is newer.
    public static func pdfURL(for url: URL) throws -> URL {
        guard !DocumentFormats.isPDF(url.path) else { return url }
        let ext = url.pathExtension.lowercased()
        guard DocumentFormats.supportedExtensions.contains(ext) else {
            throw ConversionError(description: "Dateityp .\(ext) wird nicht unterstützt.")
        }
        let target = DocumentFormats.convertedPDFURL(forOriginal: url.path)
        if let cached = modificationDate(target), let original = modificationDate(url), cached >= original {
            return target
        }
        try FileManager.default.createDirectory(at: DocumentFormats.convertedDir, withIntermediateDirectories: true)

        if DocumentFormats.ebooks.contains(ext) {
            if let calibre = DocumentFormats.calibreConverter {
                try run(calibre, [url.path, target.path], timeout: 300)
            } else {
                try convertEPUBText(url, to: target)
            }
        } else if let soffice = DocumentFormats.libreOfficeBinary {
            try convertWithLibreOffice(url, to: target, soffice: soffice)
        } else if DocumentFormats.textDocuments.contains(ext), ext != "pages" {
            try convertWithTextSystem(url, to: target)
        } else {
            throw ConversionError(description: "„\(url.lastPathComponent)“ braucht LibreOffice zur Umwandlung (kostenlos, libreoffice.org). Word-, RTF- und Textdateien gehen auch ohne.")
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw ConversionError(description: "Umwandlung von „\(url.lastPathComponent)“ in PDF fehlgeschlagen.")
        }
        return target
    }

    private static func modificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Headless LibreOffice with its own profile, so a LibreOffice window the user has open does not block it.
    private static func convertWithLibreOffice(_ url: URL, to target: URL, soffice: String) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-convert-\(UUID().uuidString)", isDirectory: true)
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-lo-profile", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: soffice)
        p.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                       "--convert-to", "pdf", "--outdir", work.path, url.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(180)
        while p.isRunning {
            if Date() > deadline || Task.isCancelled { p.terminate(); throw ConversionError(description: "Umwandlung abgebrochen (Zeitlimit).") }
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let produced = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension.lowercased() == "pdf" }) else {
            throw ConversionError(description: "LibreOffice konnte „\(url.lastPathComponent)“ nicht umwandeln.")
        }
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: produced, to: target)
    }

    private static func run(_ tool: String, _ args: [String], timeout: TimeInterval) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline || Task.isCancelled { p.terminate(); throw ConversionError(description: "Umwandlung abgebrochen (Zeitlimit).") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// EPUB without Calibre: chapters in reading order (spine), as text with headings and paragraphs.
    private static func convertEPUBText(_ url: URL, to target: URL) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cortex-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try run("/usr/bin/unzip", ["-q", "-o", url.path, "-d", work.path], timeout: 60)

        let container = (try? String(contentsOf: work.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)) ?? ""
        guard let opfRel = firstMatch(#"full-path="([^"]+)""#, in: container) else {
            throw ConversionError(description: "„\(url.lastPathComponent)“ ist kein gültiges EPUB.")
        }
        let opfURL = work.appendingPathComponent(opfRel)
        let opf = (try? String(contentsOf: opfURL, encoding: .utf8)) ?? ""
        var manifest: [String: String] = [:]
        for item in allMatches(#"<item\b[^>]*>"#, in: opf) {
            if let id = firstMatch(#"\bid="([^"]+)""#, in: item), let href = firstMatch(#"\bhref="([^"]+)""#, in: item) {
                manifest[id] = href.removingPercentEncoding ?? href
            }
        }
        let spine = allMatches(#"<itemref\b[^>]*>"#, in: opf).compactMap { firstMatch(#"idref="([^"]+)""#, in: $0) }
        let base = opfURL.deletingLastPathComponent()
        let text = NSMutableAttributedString()
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11)]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15)]
        for id in spine {
            guard let href = manifest[id], let html = try? String(contentsOf: base.appendingPathComponent(href), encoding: .utf8) else { continue }
            for block in htmlBlocks(html) {
                text.append(NSAttributedString(string: block.text + "\n\n", attributes: block.isHeading ? heading : body))
            }
        }
        guard text.length > 0 else { throw ConversionError(description: "Im EPUB „\(url.lastPathComponent)“ wurde kein Text gefunden.") }
        try layoutPDF(text, to: target)
    }

    /// Headings and paragraphs of an XHTML chapter as plain text.
    static func htmlBlocks(_ html: String) -> [(text: String, isHeading: Bool)] {
        var body = html
        if let r = body.range(of: #"<body[^>]*>"#, options: .regularExpression) { body = String(body[r.upperBound...]) }
        body = body.replacingOccurrences(of: #"(?is)<(script|style)[^>]*>.*?</\1>"#, with: "", options: .regularExpression)
        var out: [(String, Bool)] = []
        for m in allMatches(#"(?is)<(h[1-6]|p|li|blockquote|td|figcaption)\b[^>]*>.*?</\1>"#, in: body) {
            let isHeading = m.range(of: #"(?i)^<h[1-6]"#, options: .regularExpression) != nil
            var t = m.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
            for (e, c) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
                t = t.replacingOccurrences(of: e, with: c)
            }
            t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out.append(((m.lowercased().hasPrefix("<li") ? "• " : "") + t, isHeading)) }
        }
        return out
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    private static func allMatches(_ pattern: String, in s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
    }

    /// Word/RTF/HTML/Text via the macOS text system, laid out on A4 pages with Core Text (thread-safe, no UI).
    private static func convertWithTextSystem(_ url: URL, to target: URL) throws {
        let ext = url.pathExtension.lowercased()
        let text: NSAttributedString
        if ["txt", "md", "markdown"].contains(ext) {
            let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            text = NSAttributedString(string: raw, attributes: [.font: NSFont.systemFont(ofSize: 11)])
        } else {
            text = try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
        try layoutPDF(text, to: target)
    }

    /// Lays out attributed text on A4 pages with Core Text (thread-safe, no UI).
    private static func layoutPDF(_ text: NSAttributedString, to target: URL) throws {
        var page = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let ctx = CGContext(target as CFURL, mediaBox: &page, nil) else {
            throw ConversionError(description: "PDF konnte nicht angelegt werden.")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var location = 0
        let frameRect = page.insetBy(dx: 56, dy: 60)
        repeat {
            ctx.beginPDFPage(nil)
            let path = CGPath(rect: frameRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
            ctx.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { break }
            location += visible.length
        } while location < text.length
        ctx.closePDF()
    }
}
