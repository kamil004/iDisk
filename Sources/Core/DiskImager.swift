import Foundation
import Darwin

/// Format obrazu dysku.
public enum ImageFormat: String, CaseIterable, Identifiable {
    case dmg
    case raw

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .dmg: return "DMG (skompresowany, mniejszy plik)"
        case .raw: return "IMG (surowy, 1:1 bez kompresji)"
        }
    }

    public var fileExtension: String {
        switch self {
        case .dmg: return "dmg"
        case .raw: return "img"
        }
    }
}

/// Zakres obrazu — cały dysk albo pojedynczy wolumen.
public enum ImageScope: String, CaseIterable, Identifiable {
    case wholeDisk
    case volume

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wholeDisk: return "Cały dysk"
        case .volume: return "Wolumen"
        }
    }
}

public enum ImageError: LocalizedError {
    case attachFailed(String)
    case toolFailed(String)
    case cancelled
    case needsFullDiskAccess

    public var errorDescription: String? {
        switch self {
        case .attachFailed(let m): return "Nie udało się podłączyć obrazu: \(m)"
        case .toolFailed(let m): return m
        case .cancelled: return "Operacja obrazu została anulowana"
        case .needsFullDiskAccess:
            return "Brak uprawnień do fizycznego dysku. 1) Włącz „iDisk” w Ustawieniach systemu → Prywatność i bezpieczeństwo → Pełny dostęp do dysku, 2) zamknij i uruchom ponownie iDisk, 3) powtórz operację."
        }
    }
}

/// Tworzenie i przywracanie obrazów dysków.
///  - Utworzenie DMG: `hdiutil create -srcdevice -format UDZO` — działa bez
///    Pełnego dostępu do dysku (hdiutil pomija bramkę; `dd` i `diskutil image
///    create from` fizycznych dysków nie otworzą).
///  - Utworzenie IMG (surowe 1:1) i przywrócenie: `dd` — wymaga Pełnego
///    dostępu do dysku w Ustawieniach systemu. Podniesienie do root (osascript
///    with administrator privileges) NIE omija TCC — root też dostaje
///    „Operation not permitted” bez FDA.
/// Postęp liczony jest z liczników IOKit (bajty odczytane / zapisane),
/// a anulowanie usuwane siłą (SIGINT → SIGTERM → SIGKILL całej grupy).
 public final class DiskImager {

    public init() {}

    /// Tworzy obraz dysku lub wolumenu `bsd` do pliku `destination`.
    /// Źródło jest chwilowo odmontowywane (wymóg `diskutil image create from`),
    /// a po zakończeniu — montowane z powrotem (best-effort).
    public func createImage(bsd: String,
                            capacityBytes: UInt64,
                            format: ImageFormat,
                            destination: URL,
                            progress: @escaping (_ step: String, _ fraction: Double, _ bytes: UInt64, _ total: UInt64) -> Void = { _, _, _, _ in },
                            outputLine: @escaping (String) -> Void = { _ in }) throws {
        guard !isCancelled else { throw ImageError.cancelled }

        unmountSource(bsd: bsd, outputLine: outputLine)
        defer { remountSource(bsd: bsd, outputLine: outputLine) }
        guard !isCancelled else { throw ImageError.cancelled }

        let io = DiskIOStats(bsd: bsd)
        var r: (status: Int32, output: String)
        switch format {
        case .dmg:
            // diskutil image create from → „Operation not permitted” dla fizycznych
            // dysków USB; hdiutil czyta je jako zwykły użytkownik (deprecated, działa).
            r = try runTool(executable: "/usr/bin/hdiutil",
                            args: ["create", "-srcdevice", "/dev/\(bsd)", "-format", "UDZO", "-o", destination.path],
                            outputLine: outputLine,
                            totalBytes: capacityBytes,
                            bytesDone: { io?.readBytes() ?? 0 }) { fraction, bytes, total in
                progress("Tworzenie obrazu DMG (skompresowany, mniejszy plik)…", fraction, bytes, total)
            }
            case .raw:
            // Surowy 1:1 BEZ Pełnego dostępu do dysku: `hdiutil create -srcdevice
            // -format UDTO` tworzy czystą kopię bajt-w-bajt (bez obudowy UDIF,
            // sprawdzone: cmp identyczny z urządzeniem), a hdiutil jako jedyny
            // czyta fizyczne dyski bez FDA. dd na /dev/rX wymagałby FDA.
            let stem = destination.deletingPathExtension().path
            let produced = stem + ".cdr"
            try? FileManager.default.removeItem(atPath: produced)
            let ur = try runTool(
                executable: "/usr/bin/hdiutil",
                args: ["create", "-srcdevice", "/dev/\(bsd)", "-format", "UDTO", "-o", stem],
                outputLine: outputLine,
                totalBytes: capacityBytes,
                bytesDone: { io?.readBytes() ?? 0 }
            ) { fraction, bytes, total in
                progress("Tworzenie obrazu IMG (surowy, 1:1 bez kompresji)…", fraction, bytes, total)
            }
            if FileManager.default.fileExists(atPath: produced) {
                try? FileManager.default.removeItem(atPath: destination.path)
                do {
                    try FileManager.default.moveItem(atPath: produced, toPath: destination.path)
                } catch {
                    throw ImageError.toolFailed("Nie udało się zapisać jako .img (\(produced) → \(destination.lastPathComponent)): \(error.localizedDescription)")
                }
            }
            r = ur
        }
        guard r.status == 0 else {
            if Self.looksLikePermissionDenied(r.output) {
                throw ImageError.needsFullDiskAccess
            }
            throw Self.failure(r.output, "hdiutil create")
        }

        progress("Zakończono — zapisano \(destination.lastPathComponent)", 1, capacityBytes, capacityBytes)
    }

    /// Przywraca obraz `image` na dysk `targetBSD` (dysk docelowy jest całkowicie
    /// nadpisywany danymi z obrazu).
    public func restoreImage(image: URL,
                             targetBSD: String,
                             progress: @escaping (_ step: String, _ fraction: Double, _ bytes: UInt64, _ total: UInt64) -> Void = { _, _, _, _ in },
                             outputLine: @escaping (String) -> Void = { _ in }) throws {
        guard !isCancelled else { throw ImageError.cancelled }

        outputLine("Podłączanie obrazu \(image.lastPathComponent)…")
        let attach = try runTool(executable: "/usr/sbin/diskutil",
                                 args: ["image", "attach", "--readOnly", "--noMount", "--nobrowse", image.path],
                                 outputLine: outputLine,
                                 progress: { _, _, _ in })
        guard attach.status == 0 else {
            throw ImageError.attachFailed("diskutil image attach \(image.lastPathComponent)")
        }
        guard let srcBSD = Self.attachedDevice(from: attach.output) else {
            throw ImageError.attachFailed("nie rozpoznano urządzenia obrazu")
        }

        defer { Self.detachImage(bsd: srcBSD, outputLine: outputLine) }

        let srcSize = SmartService.mediaSize(bsd: srcBSD)
        let io = DiskIOStats(bsd: targetBSD)

        outputLine("Odmontowywanie dysku docelowego \(targetBSD)…")
        _ = runShell("/usr/sbin/diskutil", ["unmountDisk", targetBSD])

        outputLine("Przywracanie /dev/r\(srcBSD) → /dev/r\(targetBSD)…")
        let copy = try runTool(executable: "/bin/dd",
                               args: ["if=/dev/r\(srcBSD)", "of=/dev/r\(targetBSD)", "bs=1m", "conv=fsync"],
                               outputLine: outputLine,
                               totalBytes: UInt64(max(0, srcSize)),
                               bytesDone: { io?.writeBytes() ?? 0 }) { fraction, bytes, total in
            progress("Przywracanie obrazu…", fraction, bytes, total)
        }
        guard copy.status == 0 else {
            if Self.looksLikePermissionDenied(copy.output) {
                throw ImageError.needsFullDiskAccess
            }
            throw Self.failure(copy.output, "dd")
        }

        let sz = UInt64(max(0, srcSize))
        progress("Zakończono — przywrócono \(image.lastPathComponent)", 1, sz, sz)
    }

    // MARK: - Anulowanie

    private var cancelled = false
    private let cancelLock = NSLock()

    public func cancel() {
        cancelLock.lock(); cancelled = true; cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }; return cancelled
    }

    // MARK: - Proces

    /// Uruchamia proces, buforuje wyjście, monitoruje postęp z licznika bajtów
    /// (`totalBytes` + `bytesDone`) i obsługuje anulowanie.
    private func runTool(executable: String,
                         args: [String],
                         outputLine: @escaping (String) -> Void,
                         totalBytes: UInt64? = nil,
                         bytesDone: (() -> UInt64)? = nil,
                         progress: @escaping (_ fraction: Double, _ bytes: UInt64, _ total: UInt64) -> Void) throws -> (status: Int32, output: String) {
        let url = URL(fileURLWithPath: executable, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ImageError.toolFailed("Nie znaleziono narzędzia \(executable)")
        }
        let p = Process()
        p.executableURL = url
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
                for chunk in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    let line = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty { outputLine(String(line)) }
                }
            }
        }

        do {
            try p.run()
        } catch {
            throw ImageError.toolFailed("Nie można uruchomić \(executable): \(error.localizedDescription)")
        }

        while p.isRunning {
            Thread.sleep(forTimeInterval: 0.2)
            lock.lock()
            let isCanc = isCancelled
            lock.unlock()
            if isCanc && p.isRunning {
                Self.forceKill(p)
                throw ImageError.cancelled
            }
            if let total = totalBytes, let done = bytesDone, total > 0 {
                let d = done()
                progress(min(1, Double(d) / Double(total)), d, total)
            } else {
                progress(0, 0, 0)
            }
        }

        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let output = String(data: buffer, encoding: .utf8) ?? ""
        lock.unlock()
        return (p.terminationStatus, output)
    }

    /// Czy wyjście narzędzia wskazuje na brak uprawnień (zw. Pełny dostęp do dysku).
    private static func looksLikePermissionDenied(_ output: String) -> Bool {
        let m = output.lowercased()
        return m.contains("permission denied") || m.contains("operation not permitted")
    }

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

    /// Pierwsze urządzenie (/dev/diskN) z wyjścia `hdiutil attach`.
    private static func attachedDevice(from output: String) -> String? {
        for token in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let s = String(token).trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("/dev/") {
                return String(s.dropFirst("/dev/".count).prefix(while: { $0 != " " && $0 != "\t" }))
            }
        }
        return nil
    }

    /// Odmontowuje wolumeny źródła przed tworzeniem obrazu (wymóg
    /// `diskutil image create from` — brak odmontowania kończy się „Resource busy”).
    private func unmountSource(bsd: String, outputLine: @escaping (String) -> Void) {
        outputLine("Odmontowywanie źródła \(bsd) przed obrazowaniem…")
        _ = runShell("/usr/sbin/diskutil", ["unmountDisk", bsd])
    }

    /// Ponowne zamontowanie źródła po zakończeniu (best-effort).
    private func remountSource(bsd: String, outputLine: @escaping (String) -> Void) {
        let code = runShell("/usr/sbin/diskutil", ["mountDisk", bsd])
        if code == 0 {
            outputLine("Ponownie zamontowano źródło \(bsd).")
        }
    }

    private static func detachImage(bsd: String, outputLine: @escaping (String) -> Void) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["eject", "/dev/" + bsd]
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0 {
            outputLine("Odłączono obraz /dev/\(bsd).")
        }
    }

    /// Uruchamia narzędzie i zwraca kod zakończenia.
    private func runShell(_ executable: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return -1
        }
        return p.terminationStatus
    }

    private static func failure(_ output: String, _ prefix: String) -> ImageError {
        let tail = String(output.split(separator: "\n").suffix(8).joined(separator: "\n"))
        return ImageError.toolFailed("\(prefix) zakończył się błędem:\n\(tail)")
    }
}