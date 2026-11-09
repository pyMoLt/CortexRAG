import Foundation
import CryptoKit

/// File types the library accepts. PDFs are read directly; every other format is converted once into a cached
/// PDF (`Converted/`) that search, figures and the reader use. The original file stays where it is and remains
/// the document's path, so the library only links to it.
public enum DocumentFormats {
    /// Converted natively by macOS (text system) or by LibreOffice when installed.
    public static let textDocuments: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "txt", "md", "markdown", "html", "htm", "pages"]
    /// Need LibreOffice (presentations and spreadsheets have no native converter).
    public static let officeOnly: Set<String> = ["pptx", "ppt", "pps", "ppsx", "odp", "key", "xlsx", "xls", "ods", "csv"]

    /// E-books: Calibre (with images) when installed, otherwise text with chapter structure.
    public static let ebooks: Set<String> = ["epub"]

    public static var supportedExtensions: Set<String> { textDocuments.union(officeOnly).union(ebooks).union(["pdf"]) }

    public static func isSupported(_ url: URL) -> Bool { supportedExtensions.contains(url.pathExtension.lowercased()) }
    public static func isPDF(_ path: String) -> Bool { (path as NSString).pathExtension.lowercased() == "pdf" }

    public static var convertedDir: URL { CortexPaths.appSupport.appendingPathComponent("Converted", isDirectory: true) }

    /// Cache location of the PDF rendition of a non-PDF document (stable per original path).
    public static func convertedPDFURL(forOriginal path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let safe = base.replacingOccurrences(of: "/", with: "-").prefix(60)
        return convertedDir.appendingPathComponent("\(safe)-\(digest).pdf")
    }

    /// The PDF to read for a document path: the file itself for PDFs, the cached rendition otherwise.
    public static func readablePDFPath(for path: String) -> String {
        isPDF(path) ? path : convertedPDFURL(forOriginal: path).path
    }

    /// Calibre's converter, if installed.
    public static var calibreConverter: String? {
        ["/Applications/calibre.app/Contents/MacOS/ebook-convert", "/opt/homebrew/bin/ebook-convert", "/usr/local/bin/ebook-convert"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Installed LibreOffice binary, if any.
    public static var libreOfficeBinary: String? {
        let candidates = ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
                          NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
                          "/opt/homebrew/bin/soffice", "/usr/local/bin/soffice"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
