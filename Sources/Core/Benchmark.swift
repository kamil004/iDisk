import Foundation

public struct BenchmarkResult: Equatable {
    public var seqWrite: Double = 0
    public var seqRead: Double = 0
    public var rndWrite: Double = 0
    public var rndRead: Double = 0

    public init() {}

    public var hasData: Bool {
        seqWrite > 0 || seqRead > 0 || rndWrite > 0 || rndRead > 0
    }
}

 public enum BenchmarkError: LocalizedError {
    case io(String)
    case cancelled
    case allocationFailed

    public var errorDescription: String? {
        switch self {
        case .io(let m): return m
        case .cancelled: return "Test anulowano"
        case .allocationFailed: return "Nie udało się przydzielić pamięci (posix_memalign)"
        }
    }
}

/// Silnik testu prędkości. Testuje:
///  - zapis/odczyt sekwencyjny w blokach 1 MiB,
///  - zapis/odczyt losowy w blokach 4 KiB.
/// I/O z pominięciem cache (`F_NOCACHE`), jak w profesjonalnych benchmarkach dysków.
 public final class BenchmarkRunner {

    static let seqBlock = 1_048_576      // 1 MiB
    static let rndBlock = 4_096          // 4 KiB
    static let benchDirName = ".iDiskBench"

    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

/// Uruchamia pełny test w podanym katalogu.
    /// - Parameter seqBlockBytes: rozmiar bloku dla zapisu/odczytu sekwencyjnego (domyślnie 1 MiB).
    /// `progress` wywoływany z katalogu `(opis kroku, postęp 0...1)`.
    public func run(inDirectory dir: URL,
                    totalBytes: Int64,
                    seqBlockBytes: Int = 1_048_576,
                    includeRandom: Bool = true,
                    progress: @escaping (_ step: String, _ fraction: Double) -> Void) throws -> BenchmarkResult {

        guard totalBytes >= Int64(Self.rndBlock) else {
            throw BenchmarkError.io("Rozmiar testu jest za mały")
        }
        guard seqBlockBytes <= totalBytes else {
            throw BenchmarkError.io("Rozmiar bloku nie może być większy niż rozmiar testu")
        }
        guard totalBytes % Int64(seqBlockBytes) == 0 else {
            throw BenchmarkError.io("Rozmiar testu musi być podzielny przez rozmiar bloku (\(seqBlockBytes) B)")
        }

        let benchDir = dir.appendingPathComponent(Self.benchDirName, isDirectory: true)
        try? FileManager.default.removeItem(at: benchDir)
        try FileManager.default.createDirectory(at: benchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: benchDir) }

        let seqURL = benchDir.appendingPathComponent("seq.bin")

        do {
            let total = totalBytes
            var result = BenchmarkResult()

            progress("Zapis sekwencyjny…", 0)
            result.seqWrite = try seqWrite(
                at: seqURL, total: total, block: seqBlockBytes,
                progress: { progress("Zapis sekwencyjny…", $0) })

            progress("Odczyt sekwencyjny…", 0)
            result.seqRead = try seqRead(
                at: seqURL, total: total, block: seqBlockBytes,
                progress: { progress("Odczyt sekwencyjny…", $0) })

            let rndURL = benchDir.appendingPathComponent("rnd.bin")
            if includeRandom {
                progress("Zapis losowy 4K…", 0)
                result.rndWrite = try randomWrite(
                    at: rndURL, total: total, block: Self.rndBlock,
                    progress: { progress("Zapis losowy 4K…", $0) })

                progress("Odczyt losowy 4K…", 0)
                result.rndRead = try randomRead(
                    at: rndURL, total: total, block: Self.rndBlock,
                    progress: { progress("Odczyt losowy 4K…", $0) })
            }

            return result
        } catch BenchmarkError.cancelled {
            throw BenchmarkError.cancelled
        } catch let e as CocoaError {
            throw BenchmarkError.io(e.localizedDescription)
        }
    }

    // MARK: - Sekwencyjny zapis

    func seqWrite(at url: URL, total: Int64, block: Int,
                  progress: @escaping (Double) -> Void) throws -> Double {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            let msg = String(cString: strerror(errno))
            throw BenchmarkError.io("Nie można utworzyć pliku: \(msg)")
        }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let buf = try makeAligned(block)
        defer { free(buf) }
        memset(buf, 0x5A, block)

        return try measure(total: total, block: block, progress: progress) { offset, count in
            var written = 0
            while written < count {
                guard !isCancelled else { throw BenchmarkError.cancelled }
                let n = write(fd, buf.advanced(by: written), count - written)
                guard n > 0 else {
                    throw BenchmarkError.io("Błąd zapisu: \(String(cString: strerror(errno)))")
                }
                written += n
            }
        }
    }

    // MARK: - Sekwencyjny odczyt

    func seqRead(at url: URL, total: Int64, block: Int,
                 progress: @escaping (Double) -> Void) throws -> Double {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw BenchmarkError.io("Nie można otworzyć pliku") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let buf = try makeAligned(block)
        defer { free(buf) }

        return try measure(total: total, block: block, progress: progress) { offset, count in
            var start = offset
            let end = offset + Int64(count)
            while start < end {
                guard !isCancelled else { throw BenchmarkError.cancelled }
                let remaining = Int(end - start)
                let n = pread(fd, buf, remaining, start)
                guard n > 0 else {
                    throw BenchmarkError.io("Błąd odczytu: \(String(cString: strerror(errno)))")
                }
                start += Int64(n)
            }
        }
    }

    // MARK: - Losowy zapis 4K

    func randomWrite(at url: URL, total: Int64, block: Int,
                     progress: @escaping (Double) -> Void) throws -> Double {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw BenchmarkError.io("Nie można utworzyć pliku") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let buf = try makeAligned(block)
        defer { free(buf) }
        memset(buf, 0xA5, block)

        let offsets = shuffledOffsets(total: total, block: block)
        return try measure(offsets: offsets, total: total, block: block, progress: progress) { offset, count in
            var done = 0
            while done < count {
                guard !isCancelled else { throw BenchmarkError.cancelled }
                let n = pwrite(fd, buf.advanced(by: done), count - done, offset + Int64(done))
                guard n > 0 else {
                    throw BenchmarkError.io("Błąd zapisu losowego: \(String(cString: strerror(errno)))")
                }
                done += n
            }
        }
    }

    // MARK: - Losowy odczyt 4K

    func randomRead(at url: URL, total: Int64, block: Int,
                    progress: @escaping (Double) -> Void) throws -> Double {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw BenchmarkError.io("Nie można otworzyć pliku") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)

        let buf = try makeAligned(block)
        defer { free(buf) }

        let offsets = shuffledOffsets(total: total, block: block)
        return try measure(offsets: offsets, total: total, block: block, progress: progress) { offset, count in
            var done = 0
            while done < count {
                guard !isCancelled else { throw BenchmarkError.cancelled }
                let n = pread(fd, buf.advanced(by: done), count - done, offset + Int64(done))
                guard n > 0 else {
                    throw BenchmarkError.io("Błąd odczytu losowego: \(String(cString: strerror(errno)))")
                }
                done += n
            }
        }
    }

    // MARK: - Pomocnicze

    private func measure(total: Int64, block: Int, progress: @escaping (Double) -> Void,
                         io: (_ offset: Int64, _ count: Int) throws -> Void) throws -> Double {
        let t0 = DispatchTime.now()
        var offset: Int64 = 0
        var lastEmit = 0.0
        while offset < total {
            guard !isCancelled else { throw BenchmarkError.cancelled }
            try io(offset, block)
            offset += Int64(block)
            let frac = Double(offset) / Double(total)
            if frac - lastEmit >= 0.02 || offset >= total {
                progress(frac)
                lastEmit = frac
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000
        if isCancelled { throw BenchmarkError.cancelled }
        return mbs(Double(total), elapsed)
    }

    private func measure(offsets: [Int64], total: Int64, block: Int,
                         progress: @escaping (Double) -> Void,
                         io: (_ offset: Int64, _ count: Int) throws -> Void) throws -> Double {
        let t0 = DispatchTime.now()
        var done = 0
        var lastEmit = 0.0
        for offset in offsets {
            guard !isCancelled else { throw BenchmarkError.cancelled }
            try io(offset, block)
            done += block
            let frac = Double(done) / Double(total)
            if frac - lastEmit >= 0.02 || done >= total {
                progress(frac)
                lastEmit = frac
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000_000
        if isCancelled { throw BenchmarkError.cancelled }
        return mbs(Double(total), elapsed)
    }

    private func shuffledOffsets(total: Int64, block: Int) -> [Int64] {
        let count = Int(total / Int64(block))
        return (0..<count).map { Int64($0) * Int64(block) }.shuffled()
    }

    private func makeAligned(_ size: Int) throws -> UnsafeMutableRawPointer {
        var p: UnsafeMutableRawPointer?
        guard posix_memalign(&p, 4_096, size) == 0, let p else {
            throw BenchmarkError.allocationFailed
        }
        return p
    }
    private func mbs(_ bytes: Double, _ seconds: Double) -> Double {
        guard seconds > 0 else { return 0 }
        return bytes / seconds / 1_048_576
    }
}