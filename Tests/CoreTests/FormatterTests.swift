import XCTest
@testable import Core

/// Testy dla FormatFileSystem i DiskFormatter.
final class FormatterTests: XCTestCase {

    func testFormatFileSystem_AllCases() {
        XCTAssertEqual(FormatFileSystem.allCases.count, 8)

        let names = FormatFileSystem.allCases.map { $0.displayName }
        XCTAssertTrue(names.contains("ExFAT (zalecane, >4 GB pliki)"))
        XCTAssertTrue(names.contains("APFS"))
        XCTAssertTrue(names.contains("Mac OS Extended (Journaled)"))
    }

    func testFormatFileSystem_Equatable() {
        let fs1 = FormatFileSystem.allCases[0]
        let fs2 = FormatFileSystem.allCases[0]
        let fs3 = FormatFileSystem.allCases[1]

        XCTAssertEqual(fs1, fs2)
        XCTAssertNotEqual(fs1, fs3)
    }

    func testFormatFileSystem_Hashable() {
        var set: Set<FormatFileSystem> = []
        set.insert(FormatFileSystem.allCases[0])
        set.insert(FormatFileSystem.allCases[0]) // duplicate
        XCTAssertEqual(set.count, 1)
    }

    func testFormatError_Cancelled() {
        let error = FormatError.cancelled
        XCTAssertNotNil(error.errorDescription)
        XCTAssertEqual(error.errorDescription, "Formatowanie anulowano")
    }

    func testFormatError_NotMounted() {
        let error = FormatError.notMounted("disk0s1")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("disk0s1") == true)
    }
}
