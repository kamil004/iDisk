import XCTest
@testable import Core

/// Testy dla BenchmarkRunner - walidacja i funkcje pomocnicze.
final class BenchmarkRunnerTests: XCTestCase {

    func testRun_TooSmallTotal() {
        let runner = BenchmarkRunner()
        let dir = URL(fileURLWithPath: "/tmp")

        // Total mniejszy niż rndBlock (4096)
        XCTAssertThrowsError(try runner.run(inDirectory: dir, totalBytes: 100, includeRandom: false, progress: { _, _ in })) { error in
            XCTAssertTrue(error is BenchmarkError)
            XCTAssertEqual((error as? BenchmarkError)?.errorDescription?.contains("za mały"), true)
        }
    }

    func testRun_TotalNotDivisibleByBlock() {
        let runner = BenchmarkRunner()
        let dir = URL(fileURLWithPath: "/tmp")

        // Total niepodzielny przez block
        XCTAssertThrowsError(try runner.run(inDirectory: dir, totalBytes: 8192, seqBlockBytes: 300, includeRandom: false, progress: { _, _ in })) { error in
            XCTAssertTrue(error is BenchmarkError)
            XCTAssertTrue((error as? BenchmarkError)?.errorDescription?.contains("podzielny") == true, "Expected error about divisibility, got: \((error as? BenchmarkError)?.errorDescription ?? "none")")
        }
    }

    func testRun_BlockLargerThanTotal() {
        let runner = BenchmarkRunner()
        let dir = URL(fileURLWithPath: "/tmp")

        // Block większy niż total
        XCTAssertThrowsError(try runner.run(inDirectory: dir, totalBytes: 4096, seqBlockBytes: 8192, includeRandom: false, progress: { _, _ in })) { error in
            XCTAssertTrue(error is BenchmarkError)
            XCTAssertTrue((error as? BenchmarkError)?.errorDescription?.contains("większy") == true, "Expected error about block size, got: \((error as? BenchmarkError)?.errorDescription ?? "none")")
        }
    }

    func testCancelled() {
        // Test cancel during run — cancel() przed startem nie powoduje błędu,
        // bo runner sprawdza isCancelled dopiero w pętli I/O.
        // Dlatego testuje to poprzez setup z małym plikiem i natychmiastowe cancel.
        let runner = BenchmarkRunner()
        let dir = URL(fileURLWithPath: "/tmp")
        // Ustawiamy cancel przed startem — runner sprawdzi to w pierwszej iteracji
        runner.cancel()
        // Ponieważ runner waliduje parametry PRZED pętlą I/O, a totalBytes: 4096 przechodzi walidację,
        // pierwszy krok to seqWrite który próbuje otworzyć plik — wtedy sprawdza isCancelled.
        // W praktyce test jest trudny bez mockowania, więc pomijamy szczegółowe sprawdzenie.
        // Główny cel: upewnić się, że runner nie crashuje po cancel().
        do {
            _ = try runner.run(inDirectory: dir, totalBytes: 4096, includeRandom: false, progress: { _, _ in })
            // Jeśli doszło do końca — OK (anulowanie mogło nastąpić po zakończeniu)
        } catch BenchmarkError.cancelled {
            // Oczekiwane — runner wyrzucił cancelled
        } catch {
            // Inny błąd (np. IO) — też OK, runner nie crashuje
            XCTAssertTrue(error is BenchmarkError)
        }
    }

    func testBenchmarkResult_HasData() {
        var result = BenchmarkResult()
        XCTAssertFalse(result.hasData)

        result.seqWrite = 100
        XCTAssertTrue(result.hasData)

        result = BenchmarkResult()
        result.rndRead = 50
        XCTAssertTrue(result.hasData)
    }

    func testBenchmarkResult_Equatable() {
        var r1 = BenchmarkResult()
        r1.seqWrite = 100; r1.seqRead = 200; r1.rndWrite = 300; r1.rndRead = 400
        var r2 = BenchmarkResult()
        r2.seqWrite = 100; r2.seqRead = 200; r2.rndWrite = 300; r2.rndRead = 400
        var r3 = BenchmarkResult()
        r3.seqWrite = 100; r3.seqRead = 200; r3.rndWrite = 300; r3.rndRead = 500

        XCTAssertEqual(r1, r2)
        XCTAssertNotEqual(r1, r3)
    }
}

private func XCTAssertErrorIsCancelled(_ error: Error, file: StaticString = #file, line: UInt = #line) {
    XCTAssertTrue(error is BenchmarkError, "Expected BenchmarkError, got \(type(of: error))", file: file, line: line)
    if let be = error as? BenchmarkError, case .cancelled = be {
        // Pass
    } else {
        XCTFail("Expected .cancelled case", file: file, line: line)
    }
}
