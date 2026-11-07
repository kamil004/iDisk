import SwiftUI
import Core

struct CapTestView: View {
    @EnvironmentObject private var model: CapTestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Prawdziwa pojemność")
                    .font(.headline)
                Spacer()
                if model.isLoadingVolumes {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    Task { await model.loadVolumes() }
                } label: {
                    Label("Odśwież", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRunning)
            }

            settingsSection

            if let result = model.result {
                Divider()
                resultSection(result)
            }

            Divider()
            logSection
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.loadVolumes() }
        .alert("Test prawdziwej pojemności", isPresented: $model.showConfirm) {
            Button("Anuluj", role: .cancel) {}
            Button("Rozpocznij test", role: .destructive) {
                model.start()
            }
        } message: {
            Text(model.confirmMessage)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ustawienia testu")
                .font(.headline)

            HStack {
                Picker("Wolumen:", selection: $model.selectedVolumeBSD) {
                    if model.volumes.isEmpty {
                        Text("Brak zamontowanych wolumenów").tag("")
                    }
                    ForEach(model.volumes) { v in
                        Text(volumeLabel(v)).tag(v.bsdName)
                    }
                }
                .frame(maxWidth: 460)
                .disabled(model.isRunning)

                if let vol = model.volumes.first(where: { $0.bsdName == model.selectedVolumeBSD }) {
                    HStack(spacing: 8) {
                        infoChip("System plików", vol.fileSystem)
                        infoChip("Wolne", model.freeBytesString(for: vol))
                        infoChip("Całkowita", model.totalBytesString(for: vol))
                    }
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Text("Tryb:")
                Picker("", selection: $model.mode) {
                    ForEach(CapTestModel.Mode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Spacer()
            }
            .font(.callout)
            .disabled(model.isRunning)

            HStack(spacing: 10) {
                Text("Plik testowy:")
                Picker("", selection: $model.chunkMB) {
                    Text("64 MB").tag(64)
                    Text("128 MB").tag(128)
                    Text("256 MB").tag(256)
                    Text("512 MB").tag(512)
                    Text("1 GB").tag(1024)
                }
                .labelsHidden()
                .frame(width: 110)

                Text("Drugi odczyt/zapis — im mniejszy plik, tym dokładniejsze wykrycie granicy rzeczywistej pojemności, ale więcej operacji.")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                Spacer()
            }
            .font(.callout)
            .disabled(model.isRunning)

            Toggle(isOn: $model.deleteAfter) {
                Text("Usuń pliki testowe po zakończeniu")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .disabled(model.isRunning)

            Text("Test zapisuje deterministyczny wzorzec do plików wypełniających wolny obszar, a następnie czyta je i porównuje. Wykrywa nośniki, które zgłaszają większą pojemność niż mają (podróbki, „przyrost” przez zawijanie adresów). Na dużych nośnikach może trwać długo.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button {
                    model.requestConfirm()
                } label: {
                    Label(model.isRunning ? "W trakcie…" : "Rozpocznij test", systemImage: "play.fill")
                        .frame(minWidth: 160)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isRunning || model.selectedVolumeBSD.isEmpty)

                if model.isRunning {
                    Button {
                        model.cancel()
                    } label: {
                        Label("Anuluj", systemImage: "stop.fill")
                    }
                }

                if let error = model.error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func resultSection(_ result: CapacityResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Wynik")
                    .font(.headline)
                Spacer()
                verdictLine(result)
                if model.isRunning {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                }
            }

            HStack(spacing: 20) {
                statRow("Deklarowane wolne", CapacityResult.bytes(result.declaredBytes))
                statRow("Zapisano", CapacityResult.bytes(result.writtenBytes))
                statRow("Poprawnych danych", CapacityResult.bytes(result.verifiedBytes))
                statRow("Uszkodzone/brak", CapacityResult.bytes(result.corruptedBytes), danger: result.corruptedBytes > 0)
                statRow("Czas zapisu", Self.time(result.writeElapsed))
                statRow("Czas odczytu", Self.time(result.readElapsed))
                statRow("Śr. prędkość zapisu", Self.speed(result.writeSpeedMBS))
                statRow("Śr. prędkość odczytu", Self.speed(result.readSpeedMBS))
            }

            if result.verdict != .ok {
                Text("Rzeczywista pojemność szacowana na: \(CapacityResult.bytes(result.effectiveBytes)) — czyli mniej niż zgłaszane \(CapacityResult.bytes(result.declaredBytes)).")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func verdictLine(_ result: CapacityResult) -> some View {
        switch result.verdict {
        case .ok:
            Label("Pojemność zgodna", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.bold())
        case .undersized:
            Label("Nośnik mniejszy niż deklaruje", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout.bold())
        case .corrupted:
            Label("Fałszywa pojemność — dane nadpisane", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout.bold())
        case .unknown:
            Label("Nie zapisano danych", systemImage: "questionmark.circle.fill")
                .foregroundStyle(.secondary)
                .font(.callout.bold())
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
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
            .frame(maxHeight: 180)
            .padding(10)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func infoChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private func statRow(_ label: String, _ value: String, danger: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.monospacedDigit().bold())
                .foregroundStyle(danger ? Color.red : Color.primary)
        }
    }

    private func volumeLabel(_ v: VolumeInfo) -> String {
        var s = v.name
        if let mp = v.mountPoint { s += " · \(mp.path)" }
        return s
    }

    static func speed(_ v: Double) -> String {
        v > 0 ? String(format: "%.1f MiB/s", v) : "—"
    }

    static func time(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return "—" }
        let m = Int(interval) / 60
        let s = Int(interval) % 60
        return m > 0 ? "\(m) min \(s) s" : "\(s) s"
    }
}

@MainActor
final class CapTestModel: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        /// Zapis do wyczerpania wolnego miejsca.
        case fillOnce = "1× — tylko zapis wolnego miejsca"
        /// Dwukrotne wypełnienie — wychwytuje firmware „zawijające" adresy.
        case fillWrap = "2.2× — wykrywa zamianę/powielenie danych"
        var id: String { rawValue }
        var multiplier: Double {
            switch self {
            case .fillOnce: return 1.0
            case .fillWrap: return 2.2
            }
        }
    }

    @Published var volumes: [VolumeInfo] = []
    @Published var selectedVolumeBSD = ""
    @Published var isLoadingVolumes = false
    @Published var mode = Mode.fillWrap
    @Published var chunkMB = 256
    @Published var deleteAfter = true

    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var phase: String?
    @Published var log: [String] = []
    @Published var result: CapacityResult?
    @Published var error: String?
    @Published var showConfirm = false

    private var tester = CapacityTester()
    private var task: Task<Void, Never>?

    var selectedVolume: VolumeInfo? {
        volumes.first { $0.bsdName == selectedVolumeBSD }
    }

    var effectiveURL: URL? {
        selectedVolume?.mountPoint
    }

    var confirmMessage: String {
        let url = effectiveURL?.path ?? "—"
        let free = effectiveURL.flatMap(Self.freeBytes(of:)) ?? 0
        return "Test wypełni wolny obszar na \(url) wzorcem \(mode.multiplier.formatted())× wolnego miejsca (ok. \(CapacityResult.bytes(free))), następnie zweryfikuje dane. Dane zapisywane są w katalogu \(CapacityTester.testDirName) (pliki testowe). Na nośniku fałszywej pojemności test może trwać długo. Kontynuować?"
    }

    func loadVolumes() async {
        isLoadingVolumes = true
        let disks = await Task.detached(priority: .utility) {
            (try? RemovableDeviceService.shared.listDisks()) ?? []
        }.value
        var mounted: [VolumeInfo] = []
        for d in disks {
            for v in d.volumes where v.mountPoint != nil {
                mounted.append(v)
            }
        }
        mounted.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        volumes = mounted
        if !mounted.contains(where: { $0.bsdName == selectedVolumeBSD }) {
            selectedVolumeBSD = mounted.first?.bsdName ?? ""
        }
        isLoadingVolumes = false
    }

    func requestConfirm() {
        guard let url = effectiveURL else {
            error = "Wybierz zamontowany wolumen do testu."
            return
        }
        guard let free = Self.freeBytes(of: url), free > 0 else {
            error = "Nie można odczytać wolnego miejsca na \(url.path)."
            return
        }
        error = nil
        showConfirm = true
    }

    func start() {
        guard let url = effectiveURL, !isRunning else { return }
        guard let free = Self.freeBytes(of: url), free > 0 else {
            error = "Nie można odczytać wolnego miejsca na \(url.path)."
            return
        }
        error = nil
        log = []
        result = nil
        isRunning = true
        progress = 0
        phase = "Przygotowanie…"

        let mult = mode.multiplier
        let chunk = chunkMB << 20
        let cleanup = deleteAfter
        let tester = CapacityTester()
        self.tester = tester

        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let res = try tester.run(
                    at: url,
                    declaredBytes: free,
                    multiplier: mult,
                    chunkSizeBytes: chunk,
                    deleteAfter: cleanup,
                    progress: { step, fraction in
                        Task { @MainActor in
                            self?.phase = step
                            self?.progress = fraction
                        }
                    },
                    inputOutputLine: { line in
                        Task { @MainActor in
                            self?.log.append(line)
                        }
                    }
                )
                await MainActor.run {
                    self?.result = res
                    self?.isRunning = false
                    self?.phase = nil
                    self?.progress = 1
                }
            } catch {
                await MainActor.run {
                    if case CapacityTestError.cancelled = error {
                        self?.log.append("✖ Test przerwany — pliki testowe usunięte.")
                    } else {
                        self?.error = error.localizedDescription
                    }
                    self?.isRunning = false
                    self?.phase = nil
                }
            }
        }
    }

    func cancel() {
        tester.cancel()
        task?.cancel()
    }

    nonisolated static func freeBytes(of url: URL) -> Int64? {
        let vals = try? url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
        if let v = vals?.volumeAvailableCapacityForImportantUsage, v > 0 { return v }
        if let v = vals?.volumeAvailableCapacity, v > 0 { return Int64(v) }
        var st = statfs()
        if statfs(url.path, &st) == 0 { return Int64(st.f_bavail) * Int64(st.f_bsize) }
        return nil
    }

    func freeBytesString(for vol: VolumeInfo) -> String {
        guard let mp = vol.mountPoint else { return "—" }
        guard let free = Self.freeBytes(of: mp) else { return "—" }
        return CapacityResult.bytes(free)
    }

    func totalBytesString(for vol: VolumeInfo) -> String {
        guard let mp = vol.mountPoint,
              let vals = try? mp.resourceValues(forKeys: [.volumeTotalCapacityKey]),
              let total = vals.volumeTotalCapacity else { return "—" }
        return CapacityResult.bytes(Int64(total))
    }
}