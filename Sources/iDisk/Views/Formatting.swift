import Foundation

enum SmartLabels {

    private static let map: [String: String] = [
        "Critical Warning": "Ostrzeżenie krytyczne",
        "Temperature": "Temperatura",
        "Available Spare": "Dostępna rezerwa",
        "Available Spare Threshold": "Próg dostępnej rezerwy",
        "Percentage Used": "Zużycie nośnika",
        "Data Units Read": "Dane odczytane łącznie",
        "Data Units Written": "Dane zapisane łącznie",
        "Host Read Commands": "Polecenia odczytu (host)",
        "Host Write Commands": "Polecenia zapisu (host)",
        "Controller Busy Time": "Czas pracy kontrolera",
        "Power Cycles": "Cykle zasilania",
        "Power On Hours": "Godziny pracy",
        "Unsafe Shutdowns": "Niebezpieczne wyłączenia",
        "Media and Data Integrity Errors": "Błędy integralności mediów",
        "Error Information Log Entries": "Błędy w dzienniku",
        "Model Number": "Model",
        "Serial Number": "Numer seryjny",
        "Firmware Version": "Wersja firmware",
        "Device Type": "Typ urządzenia",
        "Rotation Rate": "Prędkość obrotowa",
        "Raw read error rate": "Błędy odczytu",
        "Reallocated Sector Count": "Przydzielone ponownie sektory",
        "Temperature Case": "Temperatura obudowy",
        "Current Pending Sector": "Sektory oczekujące",
        "CRC Error Count": "Błędy CRC",
    ]

    static func polish(for key: String) -> String {
        map[key] ?? key.replacingOccurrences(of: "_", with: " ")
    }
}

extension Double {
    /// Format 1 234,6 MiB/s
    var mbsString: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 1
        f.minimumFractionDigits = 1
        f.groupingSeparator = " "
        f.locale = Locale(identifier: "pl_PL")
        return (f.string(from: NSNumber(value: self)) ?? "0") + " MiB/s"
    }
}

extension SmartLabels {

    /// Polskie nazwy najważniejszych atrybutów SMART (dla dysków z tabelą ATA/SATA).
    static let attributeNames: [Int: String] = [
        1: "Błędy odczytu surowca",
        4: "Cykle start/stop",
        5: "Realokowane sektory",
        7: "Błędy pozycjonowania",
        9: "Godziny pracy",
        10: "Ponowne rozruchy głowic",
        12: "Cykle zasilania",
        190: "Temperatura (przepływ powietrza)",
        191: "Wstrząsy (G-sense)",
        193: "Cykle załadunku",
        194: "Temperatura",
        196: "Zdarzenia realokacji",
        197: "Sektory oczekujące",
        198: "Niepoprawialne w trybie offline",
        199: "Błędy CRC (UDMA)",
        241: "Dane zapisane łącznie (LBA)",
        242: "Dane odczytane łącznie (LBA)",
    ]

    /// Atrybuty pokazywane w karcie „Kluczowe parametry” — „Realokowane sektory”
    /// (ID 05) celowo tuż nad „Sektory oczekujące” (ID 197), aby widać było związek.
    /// ID 241/242 to całkowity zapis/odczyt LBA (przeliczany dynamicznie na MB/GB/TB).
    static let keyAttributeIDs: [Int] = [5, 197, 9, 194, 198, 199, 191, 193, 241, 242]

    static func attributePolish(id: Int) -> String? {
        attributeNames[id]
    }
}