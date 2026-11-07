import XCTest
@testable import Core

/// Testy dla CapacityTester - wzorce i werdykty.
final class CapacityTesterTests: XCTestCase {

    func testWordPattern_Deterministic() {
        // Ten sam seed + index zawsze daje ten sam wynik
        let pattern1 = CapacityTesterTests.wordPattern(123, 456)
        let pattern2 = CapacityTesterTests.wordPattern(123, 456)
        XCTAssertEqual(pattern1, pattern2)

        // Różny seed lub index daje inny wynik
        let pattern3 = CapacityTesterTests.wordPattern(124, 456)
        XCTAssertNotEqual(pattern1, pattern3)

        let pattern4 = CapacityTesterTests.wordPattern(123, 457)
        XCTAssertNotEqual(pattern1, pattern4)
    }

    func testFill_Boundary() {
        // Test z buforem mniejszym niż UInt64 (8 bajtów)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 4, alignment: 8)
        defer { buf.deallocate() }

        CapacityTesterTests.fill(buf, count: 4, seed: 1, wordStart: 0)
        // Nie powinno crashować - fill obsługuje count < 8
    }

    func testVerdict_Ok() {
        var result = CapacityResult()
        result.declaredBytes = 1000
        result.writtenBytes = 1000
        result.verifiedBytes = 1000
        result.corruptedBytes = 0
        XCTAssertEqual(result.verdict, .ok)
    }

    func testVerdict_Corrupted() {
        var result = CapacityResult()
        result.declaredBytes = 1000
        result.writtenBytes = 1000
        result.verifiedBytes = 900
        result.corruptedBytes = 100
        XCTAssertEqual(result.verdict, .corrupted)
    }

    func testVerdict_Undersized() {
        var result = CapacityResult()
        result.declaredBytes = 1000
        result.writtenBytes = 500
        result.verifiedBytes = 500
        result.corruptedBytes = 0
        result.writeStoppedEarly = true
        XCTAssertEqual(result.verdict, .undersized)
    }

    func testVerdict_Undersized_NotEarly() {
        // writeStoppedEarly = false → nie .undersized
        var result = CapacityResult()
        result.declaredBytes = 1000
        result.writtenBytes = 500
        result.verifiedBytes = 500
        result.corruptedBytes = 0
        result.writeStoppedEarly = false
        XCTAssertEqual(result.verdict, .ok)
    }

    func testVerdict_Unknown() {
        var result = CapacityResult()
        result.declaredBytes = 1000
        result.writtenBytes = 0
        result.verifiedBytes = 0
        result.corruptedBytes = 0
        XCTAssertEqual(result.verdict, .unknown)
    }

    func testEffectiveBytes() {
        var result = CapacityResult()
        result.verifiedBytes = 900
        result.writtenBytes = 1000
        XCTAssertEqual(result.effectiveBytes, 900)

        result.verifiedBytes = 0
        result.writtenBytes = 1000
        XCTAssertEqual(result.effectiveBytes, 1000)
    }

    // MARK: - Private helper (mirror CapacityTester.private static func)

    private static func wordPattern(_ seed: UInt64, _ index: UInt64) -> UInt64 {
        var x = seed &+ 0x9E3779B97F4A7C15 &+ index &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 30)) &* 0xBF58476D1CE4E5B9
        x = (x ^ (x >> 27)) &* 0x94D049BB133111EB
        return x ^ (x >> 31)
    }

    private static func fill(_ buf: UnsafeMutableRawPointer, count: Int, seed: UInt64, wordStart: UInt64) {
        let words = count / MemoryLayout<UInt64>.size
        if words == 0 { return }
        let p = buf.assumingMemoryBound(to: UInt64.self)
        for j in 0..<words {
            p[j] = CapacityTesterTests.wordPattern(seed, wordStart &+ UInt64(j))
        }
    }
}
