import Foundation

/// Wynik testu rzeczywistej pojemności (odpowiednik H2testW/FakeFlashTest).
public struct CapacityResult: Equatable {
    /// Wolne miejsce zgłoszone przez system na starcie (deklarowana pojemność).
    public var declaredBytes: Int64 = 0
    /// Ile bajtów test chciał zapisać (deklarowane × mnożnik).
    public var targetWriteBytes: Int64 = 0
    /// Danych faktycznie zapisanych na nośnik (wszystkie pliki testowe, łącznie z ostatnim częściowym).
    public var writtenBytes: Int64 = 0
    /// Bajtów odczytanych i zgodnych z wzorcem.
    public var verifiedBytes: Int64 = 0
    /// Bajtów niezgodnych z wzorcem lub niedoczytanych.
    public var corruptedBytes: Int64 = 0
    /// Plików z uszkodzeniem (błąd zapisu, brak, krótszy plik lub zniekształcone dane).
    public var problemFiles: Int = 0
    /// Prawda, gdy zapis zakończył się błędem (dysk pełny) przed osiągnięciem celu.
    public var writeStoppedEarly = false
    public var chunkFiles: Int = 0
    public var writeElapsed: TimeInterval = 0
    public var readElapsed: TimeInterval = 0
    public var writeSpeedMBS: Double = 0
    public var readSpeedMBS: Double = 0

    public enum Verdict: String, Equatable {
        /// Pojemność zgodna z deklaracją.
        case ok
        /// Nośnik jest mniejszy niż deklaruje (zapis przerwany przed wypełnieniem).
        case undersized
        /// Dane zostały nadpisane przez firmware (fałszywa pojemność / zawijanie).
        case corrupted
        /// Nie udało się zapisać żadnych danych.
        case unknown
    }

    public var verdict: Verdict {
        let accounted = Int64(verifiedBytes) + corruptedBytes
        guard accounted > 0 else { return .unknown }
        if corruptedBytes > 0 { return .corrupted }
        if writeStoppedEarly && declaredBytes > 0
            && Double(writtenBytes) < 0.90 * Double(declaredBytes) {
            return .undersized
        }
        return .ok
    }

    public var displayName: String {
        switch verdict {
        case .ok: return "pojemność zgodna z deklaracją"
        case .undersized: return "nośnik mniejszy niż deklaruje"
        case .corrupted: return "fałszywa pojemność — dane nadpisane"
        case .unknown: return "nie zapisano danych"
        }
    }

    /// Szacunkowa „rzeczywista" pojemność: ile bajtów dało się poprawne
    /// zapisać i odczytać.
    public var effectiveBytes: Int64 {
        verifiedBytes > 0 ? verifiedBytes : writtenBytes
    }

    public static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

 public enum CapacityTestError: LocalizedError {
    case io(String)
    case notWritable(String)
    case cancelled
    case allocationFailed

    public var errorDescription: String? {
        switch self {
        case .io(let m): return m
        case .notWritable(let m): return m
        case .cancelled: return "Przerwano test pojemności"
        case .allocationFailed: return "Nie udało się przydzielić pamięci (posix_memalign)"
        }
    }
}

/// Testuje, czy nośnik ma rzeczywiście tyle pojemności, ile zgłasza.
///
/// Zapisuje sekwencję plików wypełnionych deterministycznym pseudolosowym
/// wzorcem (unikalnym dla każdego pliku i pozycji), następnie czyta wszystko
/// z powrotem i porównuje.
///
///  - Dysk uczciwy: wypełni się do końca (błąd „pełny") i wszystkie pliki
///    odczytają się poprawnie.
///  - Fałszywa pojemność: zapis zakończy się przed deklarowanym rozmiarem
///    (mniejszy fizycznie nośnik) albo — przy „zawijaniu" (2.2×) — wcześniejsze
///    pliki zostaną nadpisane nowymi danymi i weryfikacja je wykryje.
 public final class CapacityTester {

    public static let testDirName = ".iDiskCapTest"
    static let block = 4 * 1_048_576        // 4 MiB
    static let corruptScanCap = 256 << 20   // dokładne porównanie maks. 256 MB/plik

    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }

    public func run(at url: URL,
                    declaredBytes: Int64,
                    multiplier: Double,
                    chunkSizeBytes: Int,
                    deleteAfter: Bool,
                    progress: @escaping (_ step: String, _ fraction: Double) -> Void,
                    inputOutputLine: @escaping (String) -> Void) throws -> CapacityResult {
        let outputLine: (String) -> Void = { inputOutputLine($0) }

        guard declaredBytes > 0, multiplier > 0 else {
            throw CapacityTestError.io("Brak wolnego miejsca do testu.")
        }
        guard chunkSizeBytes > 0, chunkSizeBytes % Self.block == 0 else {
            throw CapacityTestError.io("Rozmiar pliku musi być wielokrotnością bloku 4 MiB.")
        }

        var result = CapacityResult()
        result.declaredBytes = declaredBytes
        result.targetWriteBytes = Int64((Double(declaredBytes) * multiplier).rounded(.down))

        let fm = FileManager.default
        let dir = url.appendingPathComponent(Self.testDirName, isDirectory: true)
        try? fm.removeItem(at: dir)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw CapacityTestError.notWritable("Nie można utworzyć katalogu testowego w \(url.path): \(error.localizedDescription)")
        }

        defer {
            if deleteAfter { try? fm.removeItem(at: dir) }
        }

        guard fm.isWritableFile(atPath: dir.path) else {
            throw CapacityTestError.notWritable("Brak prawa zapisu do \(url.path). Zamontuj wolumen i spróbuj ponownie.")
        }

        outputLine("Test pojemności w \(url.path)")
        outputLine("Deklarowane wolne miejsce: \(CapacityResult.bytes(declaredBytes)) · cel zapisu: \(CapacityResult.bytes(result.targetWriteBytes)) (×\(Self.fmt(multiplier)))")
        outputLine("Plik testowy: \(CapacityResult.bytes(Int64(chunkSizeBytes))), blok wzorca: \(CapacityResult.bytes(Int64(Self.block)))")

        // ---- Faza zapisu ----
        progress("Zapis (wypełnianie)…", 0)
        let writeStart = Date()
        let sizes = try writeFiles(dir: dir,
                                   chunkSizeBytes: chunkSizeBytes,
                                   target: result.targetWriteBytes,
                                   stopEarlyRef: &result.writeStoppedEarly,
                                   writeStart: writeStart,
                                   progress: progress,
                                   outputLine: outputLine)
        result.chunkFiles = sizes.count
        result.writtenBytes = sizes.reduce(0, +)
        result.writeElapsed = Date().timeIntervalSince(writeStart)
        result.writeSpeedMBS = Self.mbs(result.writtenBytes, result.writeElapsed)

        // ---- Faza weryfikacji ----
        progress("Przygotowanie weryfikacji…", 0.55)
        let readStart = Date()
        let rd = try verifyFiles(dir: dir, sizes: sizes, progress: progress, outputLine: outputLine)
        result.readElapsed = Date().timeIntervalSince(readStart)
        result.readSpeedMBS = Self.mbs(rd.verified + rd.corrupted, result.readElapsed)
        result.verifiedBytes = rd.verified
        result.corruptedBytes = rd.corrupted
        result.problemFiles = rd.problems

        outputLine("")
        outputLine("Zapisano: \(CapacityResult.bytes(result.writtenBytes)) w \(result.chunkFiles) plików (\(Self.fmt(result.writeSpeedMBS)) MiB/s)")
        outputLine("Odczytano poprawnie: \(CapacityResult.bytes(result.verifiedBytes)) (\(Self.fmt(result.readSpeedMBS)) MiB/s)")
        if result.corruptedBytes > 0 {
            outputLine("Uszkodzone/nadpisane dane: \(CapacityResult.bytes(result.corruptedBytes)), plików z problemem: \(result.problemFiles)")
        }
        outputLine("Werdykt: \(result.displayName)")
        if deleteAfter {
            outputLine("Usunięto pliki testowe (\(Self.testDirName)).")
        }
        return result
    }

    // MARK: - Faza zapisu

    private func writeFiles(dir: URL,
                            chunkSizeBytes: Int,
                            target: Int64,
                            stopEarlyRef: inout Bool,
                            writeStart: Date,
                            progress: @escaping (_ step: String, _ fraction: Double) -> Void,
                            outputLine: @escaping (String) -> Void) throws -> [Int64] {
        var sizes: [Int64] = []
        var writtenTotal: Int64 = 0
        var index = 0
        var lastPercentEmit = -1

        while writtenTotal < target {
            guard !isCancelled else { throw CapacityTestError.cancelled }

            let url = dir.appendingPathComponent(String(format: "cap_%06d.bin", index))
            let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            guard fd >= 0 else {
                stopEarlyRef = true
                break
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            let buf = try Self.makeAligned(Self.block)

            defer { free(buf) }

            var fileBytes: Int64 = 0
            var fileBlock = 0
            var earlyStop = false
            while fileBytes < Int64(chunkSizeBytes) {
                guard !isCancelled else {
                    close(fd)
                    throw CapacityTestError.cancelled
                }
                let count = Int(min(Int64(Self.block), Int64(chunkSizeBytes) - fileBytes))
                Self.fill(buf, count: count, seed: UInt64(index), wordStart: UInt64(fileBlock) * UInt64(Self.block / 8))
                let w = Self.writeFull(fd, buf, count)
                fileBytes += Int64(w)
                if w < count {
                    earlyStop = true
                    break
                }
                fileBlock += 1
            }
            if fileBytes > 0 {
                sizes.append(fileBytes)
                writtenTotal += fileBytes
            } else {
                stopEarlyRef = true
            }
            fsync(fd)
            close(fd)
            if earlyStop {
                stopEarlyRef = true
            }
            index += 1

            let fraction = Double(writtenTotal) / Double(max(1, target))
            let pct = Int(fraction * 100)
            if pct / 5 > lastPercentEmit {
                lastPercentEmit = pct / 5
                progress("Zapis \(pct)%…", min(fraction * 0.55, 0.55))
            }
            let fileSpeed = Self.mbs(fileBytes, Date().timeIntervalSince(writeStart))
            if index % 4 == 0 || earlyStop || index < 10 {
                outputLine(String(format: "#%04d: zapis %@ (%@ MiB/s) · łącznie %@", index, CapacityResult.bytes(fileBytes), Self.fmt(fileSpeed), CapacityResult.bytes(writtenTotal)))
            }
            if earlyStop { break }
        }

        return sizes
    }

    // MARK: - Faza weryfikacji

    private func verifyFiles(dir: URL,
                             sizes: [Int64],
                             progress: @escaping (_ step: String, _ fraction: Double) -> Void,
                             outputLine: @escaping (String) -> Void) throws -> (verified: Int64, corrupted: Int64, problems: Int) {
        var verified: Int64 = 0
        var corrupted: Int64 = 0
        var problems = 0

        for (i, expectedSize) in sizes.enumerated() {
            guard !isCancelled else { throw CapacityTestError.cancelled }

            let url = dir.appendingPathComponent(String(format: "cap_%06d.bin", i))
            let fd = open(url.path, O_RDONLY)
            if fd < 0 {
                corrupted += expectedSize
                problems += 1
                outputLine(String(format: "#%04d: brak pliku (%@)", i, CapacityResult.bytes(expectedSize)))
                progress("Weryfikacja \(i+1)/\(sizes.count)…", 0.56 + Double(i+1) / Double(max(1, sizes.count)) * 0.44)
                continue
            }
            _ = fcntl(fd, F_NOCACHE, 1)
            let verifyStart = Date()

            let readBuf = try Self.makeAligned(Self.block)
            let genBuf = try Self.makeAligned(Self.block)
            defer { free(readBuf); free(genBuf) }

            var done: Int64 = 0
            var fileBlock = 0
            var fileCorrupt: Int64 = 0
            var overCap = false
            while done < expectedSize {
                guard !isCancelled else {
                    close(fd)
                    throw CapacityTestError.cancelled
                }
                let count = Int(min(Int64(Self.block), expectedSize - done))
                let n = Self.readFull(fd, readBuf, count)
                guard n > 0 else { break }
                Self.fill(genBuf, count: n, seed: UInt64(i), wordStart: UInt64(fileBlock) * UInt64(Self.block / 8))

                if memcmp(readBuf, genBuf, n) == 0 {
                    verified += Int64(n)
                } else {
                    if !overCap {
                        let scanLeft = Int(Self.corruptScanCap) - Int(fileCorrupt)
                        if scanLeft > 0 {
                            let scanned = min(n, scanLeft)
                            let rb = readBuf.assumingMemoryBound(to: UInt8.self)
                            let gb = genBuf.assumingMemoryBound(to: UInt8.self)
                            for k in 0..<scanned where rb[k] != gb[k] {
                                fileCorrupt += 1
                            }
                            if Int(fileCorrupt) >= Int(Self.corruptScanCap) {
                                overCap = true
                            }
                        }
                        if fileCorrupt > 0 || overCap { problems = 1 }
                    }
                    corrupted += Int64(n)
                }
                done += Int64(n)
                fileBlock += 1
            }
            close(fd)

            let readSpeed = Self.mbs(done, Date().timeIntervalSince(verifyStart))
            if i < 10 || i % 4 == 0 {
                outputLine(String(format: "#%04d: odczyt %@ (%@ MiB/s)", i, CapacityResult.bytes(done), Self.fmt(readSpeed)))
            }

            if done < expectedSize {
                corrupted += expectedSize - done
                problems = 1
                outputLine(String(format: "#%04d: plik krótszy o %@", i, CapacityResult.bytes(expectedSize - done)))
            } else if fileCorrupt > 0 && !overCap {
                outputLine(String(format: "#%04d: zniekształcone dane (%@)", i, CapacityResult.bytes(fileCorrupt)))
            }

            progress("Weryfikacja \(i+1)/\(sizes.count)…", 0.56 + Double(i+1) / Double(max(1, sizes.count)) * 0.44)
        }

        return (verified, corrupted, problems)
    }

    // MARK: - Pomocnicze

    private static func mbs(_ bytes: Int64, _ seconds: TimeInterval) -> Double {
        guard seconds > 0 else { return 0 }
        return Double(bytes) / seconds / 1_048_576
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    /// Deterministyczna pseudolosowa wartość 64-bitowa dla pary (seed, indeks).
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
            p[j] = wordPattern(seed, wordStart &+ UInt64(j))
        }
    }

    private static func makeAligned(_ size: Int) throws -> UnsafeMutableRawPointer {
        var p: UnsafeMutableRawPointer?
        guard posix_memalign(&p, 4_096, size) == 0, let p else {
            throw CapacityTestError.allocationFailed
        }
        return p
    }

    private static func writeFull(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
        var off = 0
        while off < count {
            let n = write(fd, buf.advanced(by: off), count - off)
            if n > 0 { off += n; continue }
            if n < 0 && errno == EINTR { continue }
            break
        }
        return off
    }

    private static func readFull(_ fd: Int32, _ buf: UnsafeMutableRawPointer, _ count: Int) -> Int {
        let n = read(fd, buf, count)
        if n < 0 && errno == EINTR { return readFull(fd, buf, count) }
        return n
    }
}