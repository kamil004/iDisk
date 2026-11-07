import Foundation
import IOKit
import Darwin

/// Odczyty liczników przepustowości sterownika blokowego (to samo źródło,
/// którego używa Activity Monitor). Na nowszych macOS statystyki są pod
/// kluczem `Statistics` („Bytes (Write)”), na starszych — `IOActivityStats`
/// („BlockWriteBytes”).
final class DiskIOStats {
    private var driver: io_registry_entry_t = 0
    private var statsKey: String = ""

    init?(bsd: String) {
        guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, bsd) else { return nil }
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else {
            IOObjectRelease(iter)
            return nil
        }
        defer { IOObjectRelease(iter) }
        while true {
            let service = IOIteratorNext(iter)
            if service == 0 { break }
            if let (driverEntry, key) = Self.storageDriver(from: service) {
                driver = driverEntry
                statsKey = key
                IOObjectRelease(service)
                break
            }
            IOObjectRelease(service)
        }
        if driver == 0 { return nil }
    }

    /// Wspinamy się do `IOBlockStorageDriver`, który trzyma liczniki.
    private static func storageDriver(from service: io_registry_entry_t) -> (io_registry_entry_t, String)? {
        var entry = service
        while entry != 0 {
            if IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0) != nil {
                return (entry, "Statistics")
            }
            if IORegistryEntryCreateCFProperty(entry, "IOActivityStats" as CFString, kCFAllocatorDefault, 0) != nil {
                return (entry, "IOActivityStats")
            }
            var parent: io_registry_entry_t = 0
            if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) != KERN_SUCCESS { return nil }
            entry = parent
        }
        return nil
    }

    func writeBytes() -> UInt64 {
        guard driver != 0 else { return 0 }
        let key = statsKey as CFString
        guard let cf = IORegistryEntryCreateCFProperty(driver, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return 0 }
        if statsKey == "Statistics" {
            if let n = cf["Bytes (Write)"] as? NSNumber { return n.uint64Value }
            if let i = cf["Bytes (Write)"] as? Int64 { return UInt64(i) }
            if let d = cf["Bytes (Write)"] as? Double { return UInt64(d) }
            return 0
        }
        return (cf["BlockWriteBytes"] as? NSNumber)?.uint64Value ?? 0
    }

    func readBytes() -> UInt64 {
        guard driver != 0 else { return 0 }
        let key = statsKey as CFString
        guard let cf = IORegistryEntryCreateCFProperty(driver, key, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] else { return 0 }
        if statsKey == "Statistics" {
            if let n = cf["Bytes (Read)"] as? NSNumber { return n.uint64Value }
            if let i = cf["Bytes (Read)"] as? Int64 { return UInt64(i) }
            if let d = cf["Bytes (Read)"] as? Double { return UInt64(d) }
            return 0
        }
        return (cf["BlockReadBytes"] as? NSNumber)?.uint64Value ?? 0
    }

    deinit {
        if driver != 0 { IOObjectRelease(driver) }
    }
}

public struct FormatFileSystem: Identifiable, Equatable, Hashable, CaseIterable, Sendable {
    public let id: String
    public let displayName: String
    public let diskutilToken: String

    public static let allCases: [FormatFileSystem] = [
        FormatFileSystem(id: "exfat", displayName: "ExFAT (zalecane, >4 GB pliki)", diskutilToken: "ExFAT"),
        FormatFileSystem(id: "fat32", displayName: "MS-DOS (FAT32) — kompatybilne", diskutilToken: "MS-DOS FAT32"),
        FormatFileSystem(id: "fat16", displayName: "MS-DOS (FAT16) — stare urządzenia", diskutilToken: "MS-DOS FAT16"),
        FormatFileSystem(id: "apfs", displayName: "APFS", diskutilToken: "APFS"),
        FormatFileSystem(id: "apfsx", displayName: "APFS (case-sensitive)", diskutilToken: "APFSX"),
        FormatFileSystem(id: "jhfs", displayName: "Mac OS Extended (Journaled)", diskutilToken: "JHFS+"),
        FormatFileSystem(id: "jhfsx", displayName: "Mac OS Extended (case-sensitive, journaled)", diskutilToken: "JHFSX"),
        FormatFileSystem(id: "hfs", displayName: "Mac OS Extended (HFS+, bez journal)", diskutilToken: "HFS+"),
    ]
}

public enum FormatError: LocalizedError {
    case notMounted(String)
    case diskutilFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notMounted(let m): return "Wolumen nie jest zamontowany: \(m)"
        case .diskutilFailed(let m): return m
        case .cancelled: return "Formatowanie anulowano"
        }
    }
}

/// Formatuje dyski / wolumeny przez `diskutil eraseVolume` / `eraseDisk`.
 public final class DiskFormatter {

    public init() {}

    /// - Parameters:
    ///   - bsd: np. `disk4s1` (wolumen) lub `disk4` (cały dysk).
    ///   - wholeDisk: `true` → `eraseDisk` (usuwa partycje), `false` → `eraseVolume`.
    ///   - progress: postęp `(opis, procent 0...1)` w miarę możliwości.
    ///   - outputLine: kolejne linie wyjścia diskutil do pokazania w logu.
    public func format(bsd: String,
                       wholeDisk: Bool,
                       fileSystem: FormatFileSystem,
                       name: String,
                       progress: @escaping (_ step: String, _ fraction: Double) -> Void = { _, _ in },
                       outputLine: @escaping (String) -> Void = { _ in }) throws {
        guard !isCancelled else { throw FormatError.cancelled }

        let devicePath = "/dev/" + bsd
        let verb = wholeDisk ? "eraseDisk" : "eraseVolume"
        let result = try runProcess(args: [verb, fileSystem.diskutilToken, name, devicePath],
                                    outputLine: outputLine) { fraction in
            progress("Formatowanie…", fraction)
        }
        guard result.status == 0 else {
            throw Self.failure(result.output, "diskutil \(verb)")
        }
        progress("Zakończono", 1)
    }

    /// Formatowanie niskopoziomowe: nadpisuje cały dysk zerami
    /// (`diskutil zeroDisk` — usuwa partycje i wszystkie dane),
    /// a następnie tworzy dysk od nowa z wybranym systemem plików.
    /// W trakcie nadpisywania raportuje aktualną prędkość zapisu (MiB/s)
    /// i szacowany czas pozostały (`stats`, na podstawie `capacityBytes`).
    public func lowLevelFormat(bsd: String,
                               fileSystem: FormatFileSystem,
                               name: String,
                               capacityBytes: UInt64,
                               progress: @escaping (_ step: String, _ fraction: Double) -> Void = { _, _ in },
                               outputLine: @escaping (String) -> Void = { _ in },
                               stats: @escaping (_ writeMBs: Double, _ etaSeconds: Double) -> Void = { _, _ in }) throws {
        guard !isCancelled else { throw FormatError.cancelled }

        let devicePath = "/dev/" + bsd

        // Krok 1: nadpisanie całego urządzenia zerami (kasuje partycje i dane).
        let total = Double(capacityBytes)
        let start = Date()
        var history: [(t: Double, bytes: Double)] = []
        var speeds: [Double] = []
        let ioStats = DiskIOStats(bsd: bsd)

        progress("Nadpisywanie zerami…", 0)
        let wipe = try runProcess(args: ["zeroDisk", devicePath],
                                  outputLine: outputLine,
                                  totalBytes: capacityBytes,
                                  writeBytes: { ioStats?.writeBytes() ?? 0 }) { fraction in
            progress("Nadpisywanie zerami…", fraction * 0.9)
            let tNow = Date().timeIntervalSince(start)
            let bytes = fraction * total
            // Przez pierwsze 10 s licznik (i bufor zapisu OS) zawyża wartości —
            // pomijamy. Prędkość liczona jest z okna cofniętego o 5 s,
            // więc nagłe wyrzuty bufora nie zniekształcają odczytu.
            guard tNow >= 10, total > 0 else { return }
            history.append((tNow, bytes))
            if history.count > 600 { history.removeFirst(history.count - 600) }
            guard let lastE = history.last else { return }
            let cut = lastE.t - 5
            guard let base = history.first(where: { $0.t >= cut }) ?? history.first else { return }
            let span = lastE.t - base.t
            let deltaBytes = lastE.bytes - base.bytes
            guard span > 0.5, deltaBytes > 0 else { return }
            let speed = deltaBytes / span
            speeds.append(speed)
            if speeds.count > 30 { speeds.removeFirst(speeds.count - 30) }
            let avg = speeds.reduce(0, +) / Double(speeds.count)
            let remaining = max(0, (1 - fraction) * total)
            stats(avg / 1_048_576, remaining / avg)
        }
        guard wipe.status == 0 else {
            throw Self.failure(wipe.output, "diskutil zeroDisk")
        }

        // Krok 2: świeży podział dysku i system plików (dysk jest już pusty).
        if isCancelled { throw FormatError.cancelled }
        stats(-1, -1)
        progress("Tworzenie systemu plików…", 0.9)
        let format = try runProcess(args: ["eraseDisk", fileSystem.diskutilToken, name, devicePath],
                                    outputLine: outputLine) { fraction in
            progress("Tworzenie systemu plików…", 0.9 + fraction * 0.1)
        }
        guard format.status == 0 else {
            throw Self.failure(format.output, "diskutil eraseDisk")
        }
        progress("Zakończono", 1)
    }

    /// Uruchamia proces `diskutil`, buforuje i przekazuje wyjście, monitoruje
    /// postęp oraz obsługuje anulowanie (brute-force: SIGINT → SIGTERM →
    /// SIGKILL całej grupy). Postęp raportowany jest z licznika zapisanych
    /// bajtów (jeśli podano `totalBytes` + `writeBytes`) albo z „n%” w wyjściu.
    private func runProcess(args: [String],
                            outputLine: @escaping (String) -> Void,
                            totalBytes: UInt64? = nil,
                            writeBytes: (() -> UInt64)? = nil,
                            progress: @escaping (Double) -> Void) throws -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        var buffer = Data()
        let lock = NSLock()

        pipe.fileHandleForReading.readabilityHandler = { handler in
            let data = handler.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            buffer.append(data)
            lock.unlock()
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    outputLine(String(line))
                }
            }
        }

        do {
            try p.run()
        } catch {
            throw FormatError.diskutilFailed("Nie można uruchomić diskutil: \(error.localizedDescription)")
        }

        // Pętla monitorująca do zakończenia (z obsługą anulowania).
        while p.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            lock.lock()
            let isCanc = isCancelled
            lock.unlock()
            if isCanc && p.isRunning {
                Self.forceKill(p)
                throw FormatError.cancelled
            }
            if let total = totalBytes, let write = writeBytes, total > 0 {
                // Postęp z faktycznej liczby zapisanych bajtów.
                progress(min(1, Double(write()) / Double(total)))
            } else {
                // Postęp z "n%" w wyjściu.
                lock.lock()
                let snapshot = String(data: buffer, encoding: .utf8) ?? ""
                lock.unlock()
                if let percent = Self.lastPercent(snapshot) {
                    progress(percent)
                } else {
                    progress(0)
                }
            }
        }

        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let output = String(data: buffer, encoding: .utf8) ?? ""
        lock.unlock()
        return (p.terminationStatus, output)
    }

    /// Brute-force anulowanie: SIGINT, potem SIGTERM, a jeśli proces dalej
    /// żyje — SIGKILL wysyłany do procesu i całej jego grupy.
    private static func forceKill(_ p: Process) {
        let pid = p.processIdentifier
        if pid <= 0 { return }
        p.interrupt()
        Thread.sleep(forTimeInterval: 0.3)
        if p.isRunning { p.terminate() }
        Thread.sleep(forTimeInterval: 0.4)
        for _ in 0..<4 where p.isRunning {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    private static func failure(_ output: String, _ prefix: String) -> FormatError {
        let tail = String(output.split(separator: "\n").suffix(8).joined(separator: "\n"))
        return FormatError.diskutilFailed("\(prefix) zakończył się błędem:\n\(tail)")
    }

    private var cancelled = false
    private let cancelLock = NSLock()

    public func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled
    }

    private static func lastPercent(_ text: String) -> Double? {
        var found: Double?
        for line in text.split(separator: "\n").suffix(40) {
            if let r = line.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) {
                let token = String(line[r]).dropLast()
                if let value = Double(token) { found = value / 100 }
            }
        }
        return found
    }
}
