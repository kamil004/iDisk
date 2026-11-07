import Foundation

public struct SmartField: Identifiable, Equatable {
    public let key: String
    public let value: String
    public var id: String { key }
}

public struct SmartAttribute: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let current: Int
    public let worst: Int
    public let threshold: Int
    public let raw: String
}

public struct SmartDevice: Identifiable, Equatable {
    public let bsdName: String
    public var model: String
    public var serial: String
    public var firmware: String
    public var deviceType: String
    public var sizeBytes: Int64
    public var health: String
    public var fields: [SmartField]
    public var attributes: [SmartAttribute]
    public var rawOutput: String

    public var id: String { bsdName }

    public var isHealthy: Bool {
        health.uppercased().contains("PASSED")
    }

    /// Logiczny rozmiar sektora (bajty) z wyniku smartctl,
    /// np. 512 (512e) lub 4096 (4Kn); nil, gdy linia nie występuje.
    public var logicalSectorSize: Int? {
        guard let lower = rawOutput.range(of: "bytes logical")?.lowerBound else { return nil }
        var digits: [Character] = []
        var idx = lower
        while idx > rawOutput.startIndex {
            let prev = rawOutput.index(before: idx)
            if rawOutput[prev].isNumber {
                digits.append(rawOutput[prev])
                idx = prev
                continue
            }
            if rawOutput[prev].isWhitespace {
                idx = prev
                continue
            }
            break
        }
        guard !digits.isEmpty else { return nil }
        return Int(String(digits.reversed()))
    }

    public var healthText: String {
        switch health.uppercased() {
        case let h where h.contains("PASSED"): return "Sprawny"
        case let h where h.contains("FAILED"): return "USZKODZONY"
        default: return "Nieznany"
        }
    }
}

public enum SmartError: LocalizedError {
    case toolNotFound

    public var errorDescription: String? {
        switch self {
        case .toolNotFound:
            return "Nie znaleziono narzędzia smartctl. Zainstaluj je poleceniem: brew install smartmontools"
        }
    }
}

public final class SmartService {

    public static let shared = SmartService()
    public init() {}

    private var smartctlPath: String?

    func smartctlExecutable() throws -> String {
        if let p = smartctlPath { return p }
        let candidates = [
            "/opt/homebrew/bin/smartctl",
            "/usr/local/bin/smartctl",
            "/usr/bin/smartctl",
            "/usr/sbin/smartctl",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            smartctlPath = c
            return c
        }
        if let found = Self.which("smartctl") {
            smartctlPath = found
            return found
        }
        throw SmartError.toolNotFound
    }

    private static func which(_ name: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [name]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return nil }
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty ?? true) ? nil : s
    }

    private func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty || !errData.isEmpty else {
            throw SmartError.toolNotFound
        }
        var text = String(data: data, encoding: .utf8) ?? ""
        text += String(data: errData, encoding: .utf8) ?? ""
        return text
    }

    /// Lista fizycznych dysków (wewnętrznych i zewnętrznych) z danymi SMART.
    /// Dla dysków, których smartctl nie potrafi odczytać (np. przez zewnętrzny
    /// mostek USB), zwracana jest karta z podstawowymi informacjami o nośniku.
    public func listDevices() throws -> [SmartDevice] {
        let daDisks = (try? RemovableDeviceService.shared.listDisks()) ?? []
        var seen = Set<String>()
        var result: [SmartDevice] = []

        for disk in daDisks {
            let name = disk.bsdName
            var info: SmartDevice?
            for extra in [[], ["-d", "sat"], ["-d", "auto"]] {
                if let candidate = try? fullInfo(from: "/dev/\(name)", deviceArgs: extra),
                   Self.modelFrom(candidate.rawOutput) != nil {
                    info = candidate
                    break
                }
            }
            if let info {
                let serial = info.serial
                if serial != "—", !serial.isEmpty {
                    if seen.contains(serial) { continue }
                    seen.insert(serial)
                }
                result.append(info)
            } else {
                result.append(SmartDevice(
                    bsdName: "/dev/\(name)",
                    model: disk.mediaName,
                    serial: "—",
                    firmware: "—",
                    deviceType: disk.protocolName,
                    sizeBytes: disk.sizeBytes,
                    health: "NOT_AVAILABLE",
                    fields: [],
                    attributes: [],
                    rawOutput: "smartctl nie ma dostępu do danych SMART tego dysku na interfejsie \(disk.protocolName)."
                ))
            }
        }
        return result.isEmpty ? try listViaScan() : result
    }

    private func listViaScan() throws -> [SmartDevice] {
        let tool = try smartctlExecutable()
        let scan = (try? run(tool, ["--scan"])) ?? ""
        var result: [SmartDevice] = []
        let lines = scan.split(separator: "\n").prefix(16)
        for line in lines {
            guard let rawDev = line.split(separator: " ").first else { continue }
            let dev = String(rawDev)
            if let info = try? fullInfo(from: dev) {
                result.append(info)
            }
        }
        return result
    }

    /// Pełne dane SMART dla dysku po nazwie bsd (np. "disk0").
    public func fullInfo(from bsdOrPath: String) throws -> SmartDevice {
        try fullInfo(from: bsdOrPath, deviceArgs: [])
    }

    func fullInfo(from bsdOrPath: String, deviceArgs: [String]) throws -> SmartDevice {
        let tool = try smartctlExecutable()
        let device = bsdOrPath.hasPrefix("/dev/") || bsdOrPath.hasPrefix("IOService:")
            ? bsdOrPath : "/dev/\(bsdOrPath)"
        let bsdName = device

        let brief = (try? run(tool, ["-i"] + deviceArgs + [device])) ?? ""
        // `-a` daje kompaktowe, czytelne wyjście SMART (bez nieobsługiwanych
        // przez mostek USB logów SCT/phy, które `-x` sygnalizuje jako „failed”).
        var text = (try? run(tool, ["-a"] + deviceArgs + [device])) ?? ""
        if Self.modelFrom(text) == nil {
            text = (try? run(tool, ["-x"] + deviceArgs + [device])) ?? ""
        }
        if Self.modelFrom(text) == nil {
            text = brief
        }

        let model = Self.modelFrom(text) ?? "Nieznany model"
        let serial = Self.valueFrom(text, key: "Serial Number") ?? "—"
        let firmware = Self.valueFrom(text, key: "Firmware Version")
            ?? Self.valueFrom(text, key: "Firmware") ?? "—"
        let deviceType = Self.deviceTypeFrom(text) ?? "—"
        let health = Self.valueFrom(text, key: "SMART overall-health self-assessment test result")
            ?? "UNKNOWN"
        var size: Int64 = -1
        if bsdName.hasPrefix("/dev/") {
            let name = (bsdName as NSString).lastPathComponent
            size = Self.mediaSize(bsd: name)
        }
        return SmartDevice(
            bsdName: bsdName,
            model: model,
            serial: serial,
            firmware: firmware,
            deviceType: deviceType,
            sizeBytes: size,
            health: health,
            fields: Self.parseFields(Self.healthBlock(text)),
            attributes: Self.parseAttributes(text),
            rawOutput: text
        )
    }

    // MARK: - Parsowanie

    static func valueFrom(_ text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func modelFrom(_ text: String) -> String? {
        valueFrom(text, key: "Model Number") ?? valueFrom(text, key: "Device Model")
    }

    static func deviceTypeFrom(_ text: String) -> String? {
        let t = valueFrom(text, key: "Device Type") ?? valueFrom(text, key: "NVMe Version")
        if let t = valueFrom(text, key: "Device Type") { return t }
        if text.contains("NVMe") { return "NVMe" }
        return t
    }

    static func parseFields(_ text: String) -> [SmartField] {
        guard !text.isEmpty else { return [] }
        var fields: [SmartField] = []
        for line in text.split(separator: "\n") {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            if key == "SMART overall-health self-assessment test result" { continue }
            fields.append(SmartField(key: key, value: value))
        }
        return fields
    }

    static func healthBlock(_ text: String) -> String {
        guard let range = text.range(of: "=== START OF READ SMART DATA SECTION ===")
            ?? text.range(of: "=== START OF SMART DATA SECTION ===") else {
            return text
        }
        let after = String(text[range.upperBound...])
        if let stop = after.range(of: "\nRead ") { return String(after[..<stop.lowerBound]) }
        return after
    }

    static func parseAttributes(_ text: String) -> [SmartAttribute] {
        var result: [SmartAttribute] = []
        let lines = text.split(separator: "\n")
        var inTable = false
        for rawLine in lines {
            let line = String(rawLine)
            if line.contains("SMART Attributes Data Structure") { inTable = true; continue }
            if inTable && line.hasPrefix("SMART ") { break }
            if !inTable { continue }
            let tokens = line.split(separator: " ").filter { !$0.isEmpty }
            guard tokens.count >= 7, let id = Int(tokens[0]) else { continue }
            // Format ATA: ID# NAZWA FLAG(0xHEX) VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
            // Format SATA bez FLAG:   ID# NAZWA VALUE WORST THRESH TYPE UPDATED WHEN_FAILED RAW_VALUE
            let hasHexFlag = tokens[2].hasPrefix("0x")
            let vi = hasHexFlag ? 3 : 2
            guard tokens.count > vi + 2,
                  let current = Int(tokens[vi]),
                  let worst = Int(tokens[vi + 1]),
                  let threshold = Int(tokens[vi + 2] == "-" ? "0" : tokens[vi + 2])
            else { continue }
            let rawStart = min(hasHexFlag ? 9 : 8, tokens.count - 1)
            let raw = tokens[rawStart...].joined(separator: " ")
            result.append(SmartAttribute(
                id: id,
                name: String(tokens[1]),
                current: current,
                worst: worst,
                threshold: threshold,
                raw: String(raw)
            ))
        }
        return result
    }

    /// Całe dyski w /dev (nazwy typu disk0, bez partycji disk0s1).
    static func wholeDiskBSDs() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
        let pattern = try! NSRegularExpression(pattern: "^disk[0-9]+$")
        let filtered = names.filter { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        return filtered.sorted { l, r in
            let ln = Int(l.dropFirst(4)) ?? 0
            let rn = Int(r.dropFirst(4)) ?? 0
            return ln < rn
        }
    }

    public static func mediaSize(bsd: String) -> Int64 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", bsd]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
            p.waitUntilExit()
        } catch { return -1 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let size = plist["TotalSize"] as? NSNumber ?? plist["MediaSize"] as? NSNumber else { return -1 }
        return size.int64Value
    }
}

// MARK: - Formatowanie

extension Int64 {
    public var buddyBytesString: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}