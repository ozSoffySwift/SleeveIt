import XCTest
@testable import SleeveIt

final class ShoppingExportTests: XCTestCase {

    private let lines = [
        ShoppingListExport.Line(count: 892, sizeName: "Standard", dimensions: "63.5 × 88 mm"),
        ShoppingListExport.Line(count: 31, sizeName: "Mini", dimensions: "43 × 65 mm"),
    ]

    func testTextListsEveryLineAndTotals() {
        let text = ShoppingListExport.text(lines: lines)
        XCTAssertTrue(text.contains("892× Standard (63.5 × 88 mm)"))
        XCTAssertTrue(text.contains("31× Mini (43 × 65 mm)"))
        XCTAssertTrue(text.contains("Total: 923 sleeves"))
    }

    func testEmptyListReadsAsNothingToBuy() {
        let text = ShoppingListExport.text(lines: [])
        XCTAssertTrue(text.contains("Nothing to buy"))
        XCTAssertFalse(text.contains("Total:"))
    }

    func testPDFIsProduced() throws {
        let url = try XCTUnwrap(ShoppingListExport.pdf(lines: lines))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        // PDFs start with the %PDF- magic bytes.
        XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-")
    }
}
