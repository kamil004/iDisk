import SwiftUI
import Core

struct SmartView: View {
    @EnvironmentObject private var model: SmartModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Dysk:", selection: $model.selectedBSD) {
                    ForEach(model.devices) { device in
                        Text(deviceLabel(device)).tag(device.bsdName as String)
                    }
                }
                .frame(maxWidth: 360)

                Spacer()

                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    model.refresh()
                } label: {
                    Label("Odśwież", systemImage: "arrow.clockwise")
                }
            }
            .padding(14)

            Divider()

            if let error = model.errorMessage, model.devices.isEmpty {
                Spacer()
                ErrorBox(message: error)
                Spacer()
            } else if let device = model.selectedDevice {
                deviceContent(device)
            } else {
                Spacer()
                Text("Ładowanie danych…")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
    }

    private func deviceLabel(_ d: SmartDevice) -> String {
        let size = d.sizeBytes > 0 ? " (\(d.sizeBytes.buddyBytesString))" : ""
        return "\(d.model)\(size)"
    }

    private func deviceContent(_ device: SmartDevice) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                summaryCard(device)

                if device.fields.isEmpty && device.attributes.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text("Producent kontrolera tego dysku nie udostępnia danych SMART przez interfejs \(device.deviceType). Możesz nadal testować prędkość i formatować ten dysk.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                } else if !device.attributes.isEmpty {
                    HStack(alignment: .top, spacing: 16) {
                        healthPanel(device)
                            .frame(maxWidth: 360)
                        keyAttributesPanel(device)
                    }

                    attributesPanel(device.attributes)
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        healthPanel(device)
                            .frame(maxWidth: 360)
                        fieldsPanel(device.fields)
                    }
                }

                if !device.rawOutput.contains("smartctl nie ma dostępu") {
                    DisclosureGroup("Surowy wynik smartctl") {
                        Text(device.rawOutput)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(16)
        }
    }

    private func summaryCard(_ d: SmartDevice) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(d.model)
                    .font(.title2.bold())
                Text("\(d.serial)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if d.health.uppercased() == "NOT_AVAILABLE" {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.gray)
                VStack(alignment: .leading) {
                    Text("Stan: niedostępne")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("SMART: brak danych dla interfejsu (\(d.deviceType))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: d.isHealthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(d.isHealthy ? .green : .red)
                    VStack(alignment: .leading) {
                        Text(d.isHealthy ? "Stan: sprawny" : "Stan: uszkodzony")
                            .font(.headline)
                            .foregroundStyle(d.isHealthy ? .green : .red)
                        Text("SMART: \(d.healthText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func healthPanel(_ d: SmartDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dysk")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                row("Typ", d.deviceType)
                row("Pojemność", d.sizeBytes > 0 ? d.sizeBytes.buddyBytesString : "—")
                row("Wersja firmware", d.firmware)
                row("Interfejs", d.bsdName)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func fieldsPanel(_ fields: [SmartField]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Parametry SMART / zużycie")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(fields) { field in
                    row(SmartLabels.polish(for: field.key), field.value)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func keyAttributesPanel(_ device: SmartDevice) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kluczowe parametry")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                let attrs = device.attributes
                let keyed = attrs
                    .filter { SmartLabels.keyAttributeIDs.contains($0.id) }
                    .sorted { SmartLabels.keyAttributeIDs.firstIndex(of: $0.id) ?? 99 < SmartLabels.keyAttributeIDs.firstIndex(of: $1.id) ?? 99 }
                let lbaUnit = Self.lbaUnit(device)
                if keyed.isEmpty {
                    Text("Brak danych.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                ForEach(keyed) { a in
                    row(Self.keyLabel(a), attributeValue(a, lbaUnit: lbaUnit))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func attributeValue(_ a: SmartAttribute, lbaUnit: UInt64) -> String {
        switch a.id {
        case 9:
            return Self.hoursWithAge(a.raw)
        case 241, 242:
            return Self.lbaBytesString(raw: a.raw, unit: lbaUnit)
        default:
            return a.raw.isEmpty ? "—" : a.raw
        }
    }

    /// Jednostka surowej wartości atrybutów 241/242 (bajty na jednostkę).
    /// Kontrolery niekonsekwentnie raportują ten licznik:
    ///  - SandForce (OCZ, Kingston V100–V300, Corsair Force, Mushkin,
    ///    G.Skill Phoenix, ADATA S5xx, Patriot Wildfire): jednostka = 32 MiB,
    ///    rozpoznawane po charakterystycznych atrybutach A4–A9/AF–B6/F5
    ///    (ew. po nazwie modelu „sandforce”/„sf-”);
    ///  - pozostałe (Intel, Samsung, Marvell/Crucial/Plextor, Phison, Silicon
    ///    Motion, HDD Seagate/WD/Toshiba): standardowo licznik w sektorach
    ///    logicznych (512 B, przy 4Kn 4096 B).
    /// W razie braku danych przyjmujemy bezpiecznie 512 B.
    private static func lbaUnit(_ device: SmartDevice) -> UInt64 {
        if isSandForce(device) { return 32 << 20 }
        if let sector = device.logicalSectorSize, sector >= 512 { return UInt64(sector) }
        return 512
    }

    private static func isSandForce(_ device: SmartDevice) -> Bool {
        let sfIDs: Set<Int> = [0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAF, 0xB0, 0xB1, 0xB2, 0xB5, 0xB6, 0xF5]
        if device.attributes.contains(where: { sfIDs.contains($0.id) }) { return true }
        let model = device.model.lowercased()
        return model.contains("sandforce") || model.contains("sf-2") || model.contains("sf-1") || model.contains("sf-0")
    }

    /// Liczba sektorów LBA z surowej wartości atrybutu (zapis dziesiętny lub szesnastkowy).
    private static func lbaCount(_ raw: String) -> UInt64? {
        let r = raw.trimmingCharacters(in: .whitespaces)
        if r.lowercased().contains("0x") {
            return UInt64(r.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16)
        }
        return UInt64(r)
    }

    /// Dynamiczna konwersja liczby LBA na MB/GB/TB (z uwzględnieniem jednostki
    /// danego kontrolera): poniżej 1 GB w całych MB, potem do setnych,
    /// powyżej 1 TB w TB (setne).
    private static func lbaBytesString(raw: String, unit: UInt64) -> String {
        guard let count = lbaCount(raw) else { return raw.isEmpty ? "—" : raw }
        let mb = Double(count) * Double(unit) / Double(1024 * 1024)
        guard mb >= 1024 else { return "\(Int(mb.rounded())) MB" }
        let gb = mb / 1024
        guard gb >= 1024 else { return Self.fmt2(gb) + " GB" }
        return Self.fmt2(gb / 1024) + " TB"
    }

    private static func fmt2(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 2
        f.groupingSeparator = " "
        f.locale = Locale(identifier: "pl_PL")
        return f.string(from: NSNumber(value: v)) ?? String(format: "%.2f", v)
    }

    private static func keyLabel(_ a: SmartAttribute) -> String {
        SmartLabels.attributePolish(id: a.id) ?? a.name.replacingOccurrences(of: "_", with: " ")
    }

    /// Godziny pracy z przelicznikiem na lata i dni, np. „(4 lata i 249 dni) 41016 h”.
    private static func hoursWithAge(_ raw: String) -> String {
        guard let hours = Int(raw), hours > 0 else { return raw.isEmpty ? "—" : "\(raw) h" }
        let days = hours / 24
        guard days > 0 else { return "\(hours) h" }
        let prefix: String
        if days > 365 {
            let years = days / 365
            let rem = days % 365
            var s = plural(years, one: "rok", few: "lata", many: "lat")
            if rem > 0 { s += " i " + plural(rem, one: "dzień", few: "dni", many: "dni") }
            prefix = "(\(s))"
        } else {
            prefix = "(\(plural(days, one: "dzień", few: "dni", many: "dni")))"
        }
        return "\(prefix) \(hours) h"
    }

    private static func plural(_ n: Int, one: String, few: String, many: String) -> String {
        if n == 1 { return "\(n) \(one)" }
        let d = n % 10
        let m = n % 100
        if d >= 2 && d <= 4 && !(m >= 12 && m <= 14) { return "\(n) \(few)" }
        return "\(n) \(many)"
    }

    private func attributesPanel(_ attrs: [SmartAttribute]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Atrybuty SMART (tabela)")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("ID").foregroundStyle(.secondary)
                    Text("Atrybut").foregroundStyle(.secondary)
                    Text("Akt.").foregroundStyle(.secondary)
                    Text("Najg.").foregroundStyle(.secondary)
                    Text("Próg").foregroundStyle(.secondary)
                    Text("Dane RAW").foregroundStyle(.secondary)
                }
                .font(.caption.bold())
                Divider()
                ForEach(attrs) { a in
                    GridRow {
                        Text("\(a.id)").font(.system(.caption, design: .monospaced))
                        Text(SmartLabels.attributePolish(id: a.id) ?? a.name.replacingOccurrences(of: "_", with: " "))
                        Text("\(a.current)")
                        Text("\(a.worst)")
                        Text("\(a.threshold)")
                        Text(a.raw).font(.system(.caption, design: .monospaced))
                    }
                    .font(.callout)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct ErrorBox: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.orange)
            Text(message)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("Sprawdź ponownie") {
                NotificationCenter.default.post(name: .smartRetry, object: nil)
            }
        }
        .padding(24)
    }
}

extension Notification.Name {
    static let smartRetry = Notification.Name("smartRetry")
}

@MainActor
final class SmartModel: ObservableObject {
    @Published var devices: [SmartDevice] = []
    @Published var selectedBSD: String = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    var selectedDevice: SmartDevice? {
        devices.first { $0.bsdName == selectedBSD }
    }

    init() {
        NotificationCenter.default.addObserver(forName: .smartRetry, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func load() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SmartService.shared.listDevices() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let list):
                    self.devices = list
                    if self.selectedBSD.isEmpty
                        || !list.contains(where: { $0.bsdName == self.selectedBSD }) {
                        self.selectedBSD = list.first?.bsdName ?? ""
                    }
                    self.errorMessage = nil
                case .failure(let failure):
                    self.errorMessage = failure.localizedDescription
                }
            }
        }
    }

    func refresh() {
        load()
    }
}