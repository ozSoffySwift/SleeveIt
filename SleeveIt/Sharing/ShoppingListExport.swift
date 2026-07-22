import Foundation
import UIKit

/// Turns the consolidated shopping list into shareable text and a PDF.
///
/// The text builder is pure so it's unit-tested; the PDF wraps that text in a
/// simple printable page.
enum ShoppingListExport {

    struct Line {
        var count: Int
        var sizeName: String
        var dimensions: String
    }

    /// Plain-text list, suitable for Messages, Notes, or an email body.
    static func text(lines: [Line], title: String = "SleeveIt — sleeves to buy") -> String {
        guard !lines.isEmpty else {
            return "\(title)\n\nNothing to buy — everything is sleeved."
        }
        let body = lines
            .map { "• \($0.count)× \($0.sizeName) (\($0.dimensions))" }
            .joined(separator: "\n")
        let total = lines.reduce(0) { $0 + $1.count }
        return """
        \(title)

        \(body)

        Total: \(total) sleeves
        Sleeve it, don't leave it.
        """
    }

    /// Renders the text list to a US-Letter PDF and returns a temp-file URL.
    static func pdf(lines: [Line]) -> URL? {
        let text = text(lines: lines)
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter @72dpi
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SleeveIt-shopping-list.pdf")

        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: UIColor.black,
                ]
                let inset = CGRect(x: 48, y: 56, width: pageRect.width - 96, height: pageRect.height - 112)
                (text as NSString).draw(in: inset, withAttributes: attributes)
            }
            return url
        } catch {
            return nil
        }
    }
}
