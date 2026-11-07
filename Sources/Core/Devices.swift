import Foundation
import DiskArbitration

public struct VolumeInfo: Identifiable, Equatable {
    public let bsdName: String
    public let name: String
    public let fileSystem: String
    public let mountPoint: URL?

    public var id: String { bsdName }
}

public struct DiskInfo: Identifiable, Equatable, Sendable {
    public let bsdName: String
    public let mediaName: String
    public let sizeBytes: Int64
    public let protocolName: String
    public let isRemovable: Bool
    public let volumes: [VolumeInfo]

    public var id: String { bsdName }

    public var sizeString: String {
        sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file) : "—"
    }

    /// Dysk zewnętrzny (po USB / FireWire / Thunderbolt).
    public var isExternal: Bool {
        var p = protocolName.uppercased()
        p = p.trimmingCharacters(in: .whitespacesAndNewlines)
        return p.hasPrefix("USB") || p == "FIREWIRE" || p == "THUNDERBOLT"
    }
}

public enum DeviceError: LocalizedError {
    case sessionFailed

    public var errorDescription: String? {
        switch self {
        case .sessionFailed: return "Nie można utworzyć sesji DiskArbitration"
        }
    }
}

/// Wykrywa fizyczne dyski oraz ich wolumeny przez framework DiskArbitration.
/// Wolumeny (montowane) i informacje o nośnikach są odczytywane synchronicznie.
 public final class RemovableDeviceService {

    public static let shared = RemovableDeviceService()
    public init() {}

    public func listDisks() throws -> [DiskInfo] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else {
            throw DeviceError.sessionFailed
        }

        var whole: [String: [String: Any]] = [:]
        var volumes: [String: [String: Any]] = [:]

        for path in Self.allDevPaths() {
            guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, path) else { continue }
            let desc = DADiskCopyDescription(disk) as? [String: Any]
            guard let desc,
                  let mediaBSD = desc[kDADiskDescriptionMediaBSDNameKey as String] as? String else { continue }

            if (desc[kDADiskDescriptionMediaWholeKey as String] as? Bool) == true {
                whole[mediaBSD] = desc
            } else if let wholeDisk = DADiskCopyWholeDisk(disk),
                      let wholeDesc = DADiskCopyDescription(wholeDisk) as? [String: Any],
                      let wholeBSD = wholeDesc[kDADiskDescriptionMediaBSDNameKey as String] as? String {
                var info = desc
                info["_wholeBSD"] = wholeBSD
                volumes[mediaBSD] = info
            }
        }

        var disks: [DiskInfo] = []
        for (bsd, desc) in whole {
            let volInfos: [VolumeInfo] = volumes.values.compactMap { volumeDesc in
                guard let wholeBSD = volumeDesc["_wholeBSD"] as? String, wholeBSD == bsd else {
                    return nil
                }
                let volumeBSD = volumeDesc[kDADiskDescriptionMediaBSDNameKey as String] as? String ?? ""
                let name = volumeDesc[kDADiskDescriptionVolumeNameKey as String] as? String ?? volumeBSD
                let fs = volumeDesc[kDADiskDescriptionVolumeTypeKey as String] as? String ?? ""
                let path = volumeDesc[kDADiskDescriptionVolumePathKey as String] as? URL
                return VolumeInfo(bsdName: volumeBSD, name: name, fileSystem: Self.fsDisplayName(fs: fs, mountPoint: path), mountPoint: path)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

            disks.append(DiskInfo(
                bsdName: bsd,
                mediaName: desc[kDADiskDescriptionMediaNameKey as String] as? String
                    ?? desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? bsd,
                sizeBytes: (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? -1,
                protocolName: desc[kDADiskDescriptionDeviceProtocolKey as String] as? String ?? "—",
                isRemovable: (desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool) ?? false,
                volumes: volInfos
            ))
        }

        return disks.sorted {
            ($0.protocolName.localizedCaseInsensitiveCompare("USB") != .orderedSame && $1.protocolName.localizedCaseInsensitiveCompare("USB") == .orderedSame)
                ? true
                : $0.mediaName.localizedCaseInsensitiveCompare($1.mediaName) == .orderedAscending
        }
    }

    /// Nazwa systemu plików wolumenu. Gdy DiskArbitration nie podaje nazwy
    /// (np. część nośników FAT), odczytuje typ systemu plików zamontowanego
    /// wolumenu przez `statfs` i mapuje na czytelną nazwę.
    private static func fsDisplayName(fs: String, mountPoint: URL?) -> String {
        if !fs.isEmpty { return fs }
        guard let path = mountPoint else { return "" }
        var st = statfs()
        guard statfs(path.path, &st) == 0 else { return "" }
        let raw = String(cString: withUnsafePointer(to: &st.f_fstypename) {
            UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
        })
        switch raw.uppercased() {
        case "MSDOS", "FAT", "FAT32": return "MS-DOS (FAT32)"
        case "FAT16": return "MS-DOS (FAT16)"
        case "EXFAT": return "ExFAT"
        case "APFS", "APFSX": return "APFS"
        case "HFSPLUS", "HFS", "JFS": return "HFS+"
        case "UFSD_NTFS": return "NTFS"
        case "UFSD_EXT", "EXT4", "UFSD_EXT4": return "ext4"
        default: return raw
        }
    }

    private static func allDevPaths() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/dev") else { return [] }
        let pattern = try! NSRegularExpression(pattern: "^disk[0-9]+(s[0-9]+)?$")
        return names
            .filter { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
            .map { "/dev/\($0)" }
    }
}