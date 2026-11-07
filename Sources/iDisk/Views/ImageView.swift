import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Core

@MainActor
final class ImageModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var selectedDiskBSD = ""
    @Published var selectedVolumeBSD = ""
    @Published var scope: ImageScope = .wholeDisk
    @Published var format: ImageFormat = .dmg
    @Published var destination: URL?
    @Published var isLoading = false
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var progressBytes: UInt64 = 0
    @Published var progressTotal: UInt64 = 0
    @Published var progressSpeedMbps = -1.0
    @Published var progressETA = -1.0
    @Published var operationStatus = ""
    @Published var log: [String] = []
    @Published var errorMessage: String?
    @Published var accessCheck: String = ""
    @Published var restoreImageURL: URL?
    @Published var showRestoreConfirm = false

    private var imager: DiskImager?
    private var smpBytes: UInt64 = 0
    private var smpTime: CFTimeInterval = 0
    private var smpRate: Double = 0

    var selectedDisk: DiskInfo? {
        disks.first { $0.bsdName == selectedDiskBSD }
    }

    var selectedVolumes: [VolumeInfo] {
        selectedDisk?.volumes ?? []
    }

    var selectedVolume: VolumeInfo? {
        selectedVolumes.first { $0.bsdName == selectedVolumeBSD }
    }

    /// Źródło obrazu albo docelowy dysk przywracania (cały dysk / wolumen).
    var createTargetBSB: String? {
        switch scope {
        case .wholeDisk: return selectedDiskBSD.isEmpty ? nil : selectedDiskBSD
        case .volume: return selectedVolumeBSD.isEmpty ? nil : selectedVolumeBSD
        }
    }

    var createSourceLabel: String {
        guard let bsd = createTargetBSB else { return "—" }
        return bsd + (scope == .volume ? " (wolumen)" : " (cały dysk)")
    }

    func load() async {
        isLoading = true
        let list = await Task.detached(priority: .userInitiated) {
            (try? RemovableDeviceService.shared.listDisks()) ?? []
        }.value
        disks = list.filter { $0.isExternal }
        if !disks.contains(where: { $0.bsdName == selectedDiskBSD }) {
            selectedDiskBSD = disks.first?.bsdName ?? ""
            diskSelectionChanged()
        }
        isLoading = false
    }

    func refresh() {
        Task { await load() }
    }

    func diskSelectionChanged() {
        if let disk = selectedDisk {
            selectedVolumeBSD = disk.volumes.first?.bsdName ?? ""
        }
    }

    private func defaultName(for bsd: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "iDisk-\(bsd)-\(df.string(from: Date())).\(format.fileExtension)"
    }

    func pickDestination() {
        guard !isRunning else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.message = "Zapisz obraz dysku"
        panel.nameFieldStringValue = defaultName(for: createTargetBSB ?? "dysk")
        if panel.runModal() == .OK, let url = panel.url {
            destination = url
        }
    }

    func pickRestoreImage() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data]
        if panel.runModal() == .OK, let url = panel.url {
            restoreImageURL = url
        }
    }

    // MARK: - Utworzenie obrazu

    func startCreate() {
        guard !isRunning else { return }
        guard let bsd = createTargetBSB else {
            errorMessage = "Wybierz dysk lub wolumen do obrazowania."
            return
        }
        guard let dest = destination else {
            errorMessage = "Wybierz plik docelowy obrazu."
            return
        }
        errorMessage = nil
        log = []
        isRunning = true
        progress = 0
        operationStatus = ""
        resetProgressStats()
        let capacity: Int64
        if scope == .wholeDisk {
            capacity = selectedDisk?.sizeBytes ?? 0
        } else if let vol = selectedVolume {
            capacity = SmartService.mediaSize(bsd: vol.bsdName)
        } else {
            capacity = 0
        }
        guard capacity > 0 else {
            errorMessage = "Nie udało się określić pojemności źródła."
            isRunning = false
            return
        }

        let fmt = format
        let running = DiskImager()
        imager = running
        log.append("Rozpoczynanie tworzenia obrazu \(bsd)…")

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try running.createImage(
                    bsd: bsd,
                    capacityBytes: UInt64(max(0, capacity)),
                    format: fmt,
                    destination: dest,
                    progress: { step, fraction, bytes, total in
                        Task { @MainActor [weak self] in
                            self?.progress = fraction
                            self?.operationStatus = step
                            self?.sampleProgress(bytes: bytes, total: total)
                        }
                    },
                    outputLine: { line in
                        Task { @MainActor [weak self] in
                            self?.log.append(line)
                        }
                    }
                )
                await MainActor.run {
                    self?.log.append("✔ Obraz utworzony: \(dest.lastPathComponent)")
                    self?.isRunning = false
                    self?.resetProgressStats()
                }
            } catch {
                await MainActor.run {
                    if case ImageError.cancelled = error {
                        self?.log.append("✖ Tworzenie obrazu anulowane.")
                    } else {
                        self?.errorMessage = error.localizedDescription
                    }
                    self?.isRunning = false
                    self?.resetProgressStats()
                }
            }
        }
    }

    // MARK: - Przywrócenie obrazu

    func requestRestoreConfirm() {
        guard !isRunning else { return }
        guard let image = restoreImageURL else {
            errorMessage = "Wybierz plik obrazu do przywrócenia."
            return
        }
        guard let disk = selectedDisk, !disk.bsdName.isEmpty else {
            errorMessage = "Wybierz dysk docelowy."
            return
        }
        if image.lastPathComponent.lowercased().hasPrefix(disk.bsdName) {
            errorMessage = "Obraz i dysk docelowy wydają się tym samym urządzeniem."
            return
        }
        errorMessage = nil
        showRestoreConfirm = true
    }

    func startRestore() {
        guard !isRunning, let image = restoreImageURL, let disk = selectedDisk else { return }
        errorMessage = nil
        log = []
        isRunning = true
        progress = 0
        operationStatus = ""
        resetProgressStats()

        let target = disk.bsdName
        let running = DiskImager()
        imager = running
        log.append("Rozpoczynanie przywracania \(image.lastPathComponent) na \(target)…")

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try running.restoreImage(
                    image: image,
                    targetBSD: target,
                    progress: { step, fraction, bytes, total in
                        Task { @MainActor [weak self] in
                            self?.progress = fraction
                            self?.operationStatus = step
                            self?.sampleProgress(bytes: bytes, total: total)
                        }
                    },
                    outputLine: { line in
                        Task { @MainActor [weak self] in
                            self?.log.append(line)
                        }
                    }
                )
                await MainActor.run {
                    self?.log.append("✔ Obraz przywrócony na \(target).")
                    self?.isRunning = false
                    self?.resetProgressStats()
                }
            } catch {
                await MainActor.run {
                    if case ImageError.cancelled = error {
                        self?.log.append("✖ Przywracanie anulowane.")
                    } else {
                        self?.errorMessage = error.localizedDescription
                    }
                    self?.isRunning = false
                    self?.resetProgressStats()
                }
            }
        }
    }

    func cancel() {
        imager?.cancel()
    }

    /// Sprawdza, czy proces aplikacji ma dostęp do surowego urządzenia (FDA),
    /// próbując odczytać pierwsze 4 KB z /dev/r<dysk> (fallback: /dev/<dysk>).
    /// Dodatkowo probuje odczytu file chronionego FDA (TCC.db) oraz wypisuje
    /// własny podpis (identyfikator/DR) — to pozwala odróżnić „grant FDA nie
    /// działa w tym procesie” od „osobna bramka dla blokowych urządzeń”.
    func checkDiskAccess() {
        accessCheck = ""

        let fdaProbe: String
        let tccPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        if let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: tccPath)),
           let d = try? h.read(upToCount: 64), !d.isEmpty {
            try? h.close()
            fdaProbe = "FDA (TCC.db): OK — odczytano \(d.count) B"
        } else {
            fdaProbe = "FDA (TCC.db): BRAK — proces NIE ma Pełnego dostępu do dysku"
        }

        let dr = Self.ownDesignatedRequirement()
        accessCheck = "\(fdaProbe)\nDR: \(dr)"

        guard let bsd = createTargetBSB else {
            accessCheck += "\nNajpierw wybierz dysk źródłowy."
            return
        }
        for path in ["/dev/r\(bsd)", "/dev/\(bsd)"] {
            do {
                let h = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? h.close() }
                let data = try h.read(upToCount: 4096)
                if let data, !data.isEmpty {
                    accessCheck += "\nOdczyt \(path) OK (\(data.count) B)."
                    return
                }
                accessCheck += "\n\(path): zwrócono pusty odczyt."
                return
            } catch {
                accessCheck += "\nBrak dostępu do \(path): \(error.localizedDescription)"
            }
        }
        accessCheck += "\nDotyczy to TYLKO przywracania obrazu na dysk: wymaga Pełnego dostępu do dysku (Ustawienia → Prywatność i bezpieczeństwo → Pełny dostęp do dysku → iDisk). Tworzenie obrazów (DMG i IMG 1:1) działa bez dodatkowych uprawnień."
        log.append("Sprawdzenie dostępu (dotyczy przywracania):\n" + accessCheck)
    }

    private static func ownDesignatedRequirement() -> String {
        guard let path = Bundle.main.executablePath else { return "?" }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else { return "?" }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req else { return "?" }
        var str: CFString?
        guard SecRequirementCopyString(req, [], &str) == errSecSuccess, let str else { return "?" }
        return String(str)
    }

    /// Otwiera (oraz odblokowuje kłódkę) panel Pełnego dostępu do dysku.
    func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Prędkość i ETA

    private func resetProgressStats() {
        smpBytes = 0
        smpTime = 0
        smpRate = 0
        progressBytes = 0
        progressTotal = 0
        progressSpeedMbps = -1
        progressETA = -1
    }

    /// Wylicza wygładzoną prędkość (EMA) z licznika bajtów i pozostały czas.
    private func sampleProgress(bytes: UInt64, total: UInt64) {
        progressBytes = bytes
        progressTotal = total > 0 ? total : progressTotal
        let now = CFAbsoluteTimeGetCurrent()
        if smpBytes == 0 {
            smpBytes = bytes
            smpTime = now
            return
        }
        let dt = now - smpTime
        if dt >= 0.5 {
            let delta = bytes >= smpBytes ? bytes - smpBytes : bytes
            let inst = Double(delta) / dt
            if inst > 0, inst.isFinite {
                smpRate = smpRate > 0 ? smpRate * 0.7 + inst * 0.3 : inst
            }
            smpBytes = bytes
            smpTime = now
        }
        if smpRate > 0 {
            progressSpeedMbps = smpRate / 1_048_576
            let remaining = total > bytes ? Double(total - bytes) : 0
            progressETA = remaining > 0 ? remaining / smpRate : -1
        }
    }
}

struct ImageView: View {
    @EnvironmentObject private var model: ImageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if model.disks.isEmpty && !model.isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text("Nie wykryto dysków zewnętrznych.\nPodłącz dysk, aby utworzyć lub przywrócić jego obraz.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                createSection
                Divider()
                logSection
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
        .alert("Błąd", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("Obraz dysku")
                .font(.headline)
            Spacer()
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            if !model.accessCheck.isEmpty {
                Text(model.accessCheck)
                    .font(.caption)
                    .foregroundStyle(model.accessCheck.contains("OK") ? .green : .orange)
                    .frame(minWidth: 340, alignment: .trailing)
            }
            Button {
                model.refresh()
            } label: {
                Label("Odśwież", systemImage: "arrow.clockwise")
            }
            .disabled(model.isRunning)
        }
    }

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Utwórz obraz")
                .font(.headline)

            HStack(spacing: 12) {
                Picker("Zakres:", selection: $model.scope) {
                    ForEach(ImageScope.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)

                Picker("Format:", selection: $model.format) {
                    ForEach(ImageFormat.allCases) { f in
                        Text(f.displayName).tag(f)
                    }
                }
                .frame(maxWidth: 360)

                Spacer()
            }

            Picker("Źródło:", selection: selectionBinding) {
                ForEach(sourceOptions) { device in
                    Text(device.label).tag(device.bsd)
                }
            }
            .frame(maxWidth: 420)
            .disabled(model.isRunning)

            if let disk = model.selectedDisk, model.scope == .wholeDisk {
                chipRow(disk: disk)
            }

            HStack(spacing: 12) {
                Button {
                    model.pickDestination()
                } label: {
                    Label("Wybierz plik docelowy…", systemImage: "folder")
                }
                .disabled(model.isRunning)

                Text(model.destination?.path ?? "brak wybranego pliku")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    model.startCreate()
                } label: {
                    Label("Utwórz obraz", systemImage: "plus.viewfinder")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(model.isRunning || model.createTargetBSB == nil || model.destination == nil)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                if model.isRunning, !model.operationStatus.isEmpty {
                    Text(model.operationStatus)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if model.isRunning {
                progressBar
            }

            ScrollView {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: 2) {
                        if model.log.isEmpty {
                            Text("Gotowy.")
                                .foregroundStyle(.tertiary)
                                .font(.callout)
                        }
                        ForEach(Array(model.log.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .onChange(of: model.log.count) {
                        withAnimation(.none) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .frame(maxHeight: 200)
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                if model.isRunning {
                    Button {
                        model.cancel()
                    } label: {
                        Label("Anuluj", systemImage: "xmark.circle")
                    }
                    .tint(.red)
                }
                Spacer()
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Pomocnicze

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)

            HStack(spacing: 6) {
                if model.progressSpeedMbps >= 0 {
                Text(model.progressETA >= 0
                        ? FormatModel.speedETA(model.progressSpeedMbps, model.progressETA)
                        : String(format: "%.1f MiB/s", model.progressSpeedMbps))
                } else {
                    Text("pomiar prędkości…")
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Text(percentText)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("\(bytesText(model.progressBytes)) / \(bytesText(model.progressTotal))")
                }
                .foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())
        }
    }

    private var percentText: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        f.groupingSeparator = " "
        f.locale = Locale(identifier: "pl_PL")
        let v = model.progress * 100
        return (f.string(from: NSNumber(value: v)) ?? "0") + "%"
    }

    private func bytesText(_ b: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
    }

    private struct SourceOption: Identifiable {
        let bsd: String
        let label: String
        var id: String { bsd }
    }

    private var sourceOptions: [SourceOption] {
        if model.scope == .wholeDisk {
            return model.disks.map { SourceOption(bsd: $0.bsdName, label: diskLabel($0)) }
        }
        return model.selectedDisk?.volumes.map {
            SourceOption(bsd: $0.bsdName, label: volumeLabel($0))
        } ?? []
    }

    private var selectionBinding: Binding<String> {
        Binding(
            get: { model.scope == .wholeDisk ? model.selectedDiskBSD : model.selectedVolumeBSD },
            set: { newValue in
                if model.scope == .wholeDisk {
                    model.selectedDiskBSD = newValue
                } else {
                    model.selectedVolumeBSD = newValue
                }
            }
        )
    }

    private func diskLabel(_ d: DiskInfo) -> String {
        "\(d.mediaName) (\(d.sizeString)) — \(d.bsdName)"
    }

    private func volumeLabel(_ v: VolumeInfo) -> String {
        let mounted = v.mountPoint == nil ? " (odmontowany)" : ""
        return "\(v.name) (\(v.fileSystem))\(mounted) — \(v.bsdName)"
    }

    private func chipRow(disk: DiskInfo) -> some View {
        HStack(spacing: 12) {
            chip("Interfejs", disk.protocolName)
            chip("System plików", disk.volumes.first?.fileSystem ?? "—")
            chip("Pojemność", disk.sizeString)
            chip("Wolumenów", "\(disk.volumes.count)")
        }
    }

    private func chip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.callout)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.background.tertiary, in: RoundedRectangle(cornerRadius: 8))
    }
}