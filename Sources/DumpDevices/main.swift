import Foundation
import Core

do {
    let devices = try SmartService.shared.listDevices()
    print("WYKRYTO \(devices.count) DYSK")
    for d in devices {
        print("---")
        print("BSD: \(d.bsdName)")
        print("Model: \(d.model)")
        print("Serial: \(d.serial)")
        print("Typ: \(d.deviceType)")
        print("Rozmiar: \(d.sizeBytes)")
        print("Zdrowie: \(d.health) -> \(d.healthText)")
        for f in d.fields {
            print("  \(f.key) = \(f.value)")
        }
        print("Atrybuty: \(d.attributes.count)")
    }
} catch {
    print("BŁĄD: \(error.localizedDescription)")
    exit(1)
}