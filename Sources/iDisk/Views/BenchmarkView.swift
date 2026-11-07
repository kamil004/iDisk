import SwiftUI
import AppKit
import Core

struct BenchmarkView: View {
    @EnvironmentObject private var model: BenchmarkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            settingsSection
            Divider()
            resultsSection
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.loadVolumes() }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ustawienia testu")
                .font(.headline)

            HStack(spacing: 8) {
                Text("Testuj:")
                Picker("", selection: $model.targetMode) {
                    Text("Wolumen / dysk").tag(BenchmarkModel.TargetMode.volume)
                    Text("Katalog").tag(BenchmarkModel.TargetMode.folder)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                Spacer()
            }

            Group {
                switch model.targetMode {
                case .volume:
                    volumeSelector
                case .folder:
                    folderSelector
                }
            }
            .disabled(model.isRunning)

            HStack(spacing: 8) {
                Text("Rozmiar testu:")
                Picker("", selection: $model.totalBytes) {
                    Text("256 MB").tag(Int64(256 << 20))
                    Text("512 MB").tag(Int64(512 << 20))
                    Text("1 GB").tag(Int64(1 << 30))
                    Text("2 GB").tag(Int64(2 << 30))
                    Text("4 GB").tag(Int64(4 << 30))
                }
                .labelsHidden()
                .frame(width: 100)

                Text("Rozmiar bloku:")
                Picker("", selection: $model.seqBlockMBs) {
                    Text("1 MiB").tag(1)
                    Text("32 MiB").tag(32)
                    Text("64 MiB").tag(64)
                }
                .labelsHidden()
                .frame(width: 120)

                Text("(zapis sekwencyjny w bloku, losowy 4 KiB)")
                    .foregroundStyle(.tertiary)
                    .font(.caption)

                Spacer()

                if model.isLoadingVolumes {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .disabled(model.isRunning)

            Toggle(isOn: $model.quickTest) {
                Text("Test szybki — tylko zapis/odczyt sekwencyjny (bez losowych 4 KiB)")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .disabled(model.isRunning)

            HStack(spacing: 12) {
                Button {
                    model.start()
                } label: {
                    Label(model.isRunning ? "W trakcie…" : "Uruchom test", systemImage: "play.fill")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning || model.effectiveURL == nil)

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
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var volumeSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                Button {
                    Task { await model.loadVolumes() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isRunning)
            }

            if let vol = model.selectedVolume {
                HStack(spacing: 6) {
                    Image(systemName: "externaldrive.fill")
                    Text("\(vol.name) — \(vol.fileSystem) — \(vol.mountPoint?.path ?? "nie zamontowany")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            } else {
                Text("Podłącz dysk wymienny (USB / karta SD) i kliknij ikonę odświeżania.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var folderSelector: some View {
        HStack(spacing: 8) {
            Text("Katalog testowy:")
            Text(model.folder?.path ?? "—")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let volume = model.volumeName {
                Text("(wolumen: \(volume))")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                chooseFolder()
            } label: {
                Label("Wybierz katalog…", systemImage: "folder")
            }
        }
        .font(.callout)
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Wyniki")
                    .font(.headline)
                Spacer()
                if let step = model.currentStep, model.isRunning {
                    Text(step)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }

            if model.isRunning {
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
            }

            if model.result.hasData {
                resultBars
            } else if !model.isRunning && model.hasRunOnce {
                Text("Zakończono.")
                    .foregroundStyle(.secondary)
            }

            if !model.isRunning {
                Text("Test I/O z pominięciem cache (F_NOCACHE). Pliki tymczasowe zapisywane są w wybranym miejscu i po teście usuwane.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var resultBars: some View {
        VStack(spacing: 12) {
            MetricBar(label: "Zapis sekwencyjny (blok \(model.seqBlockMBs) MiB · test \(model.totalBytes.buddyBytesString))", value: model.result.seqWrite, color: .red)
            MetricBar(label: "Odczyt sekwencyjny (blok \(model.seqBlockMBs) MiB · test \(model.totalBytes.buddyBytesString))", value: model.result.seqRead, color: .green)
            if !model.quickTest {
                MetricBar(label: "Zapis losowy 4K (blok 4 KiB · test \(model.totalBytes.buddyBytesString))", value: model.result.rndWrite, color: .red)
                MetricBar(label: "Odczyt losowy 4K (blok 4 KiB · test \(model.totalBytes.buddyBytesString))", value: model.result.rndRead, color: .green)
            }
        }
    }

    private func volumeLabel(_ v: VolumeInfo) -> String {
        var s = v.name
        if !v.fileSystem.isEmpty { s += " · \(v.fileSystem)" }
        if let mp = v.mountPoint { s += " · \(mp.path)" }
        return s
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Wybierz"
        panel.message = "Wybierz katalog, w którym zostanie wykonany test prędkości"
        panel.directoryURL = model.folder ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            model.folder = url
        }
    }
}

struct MetricBar: View {
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                Text(value.mbsString)
                    .font(.callout.monospacedDigit().bold())
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(color.gradient)
                        .frame(width: barWidth(geo.size.width))
                }
            }
            .frame(height: 10)
        }
    }

    private func barWidth(_ total: Double) -> Double {
        let maxValue = BenchmarkModel.displayMax.value
        guard maxValue > 0 else { return 0 }
        return Double(max(0, min(value / maxValue, 1))) * total
    }
}

@MainActor
final class BenchmarkModel: ObservableObject {

    enum TargetMode: String, CaseIterable, Identifiable {
        case volume = "Wolumen / dysk"
        case folder = "Katalog"
        var id: String { rawValue }
    }

    @Published var targetMode: TargetMode = .folder
    @Published var folder: URL? {
        didSet { updateVolumeName() }
    }
    @Published var volumeName: String?
    @Published var volumes: [VolumeInfo] = []
    @Published var selectedVolumeBSD = ""
    @Published var isLoadingVolumes = false
    @Published var totalBytes: Int64 = Int64(512 << 20)
    @Published var seqBlockMBs: Int = 64
    @Published var quickTest = true
    @Published var result = BenchmarkResult()
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var currentStep: String?
    @Published var error: String?
    @Published var hasRunOnce = false

    static let displayMax: CurrentValueBox<Double> = CurrentValueBox(0)

    private var runner = BenchmarkRunner()
    private var task: Task<Void, Never>?

    var selectedVolume: VolumeInfo? {
        volumes.first { $0.bsdName == selectedVolumeBSD }
    }

    var effectiveURL: URL? {
        switch targetMode {
        case .volume:
            guard let mp = selectedVolume?.mountPoint else { return nil }
            return URL(fileURLWithPath: mp.path, isDirectory: true)
        case .folder:
            return folder
        }
    }

    func loadVolumes() async {
        isLoadingVolumes = true
        let disks = await Task.detached(priority: .utility) {
            (try? RemovableDeviceService.shared.listDisks()) ?? []
        }.value
        let mounted = disks
            .flatMap { $0.volumes }
            .filter { $0.mountPoint != nil }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        volumes = mounted
        if !mounted.contains(where: { $0.bsdName == selectedVolumeBSD }) {
            selectedVolumeBSD = mounted.first?.bsdName ?? ""
        }
        isLoadingVolumes = false
    }

    private func updateVolumeName() {
        guard let folder else { volumeName = nil; return }
        volumeName = (try? folder.resourceValues(forKeys: [.volumeNameKey]))?.volumeName
    }

    init() {
        folder = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    func start() {
        guard let url = effectiveURL, !isRunning else { return }
        error = nil
        isRunning = true
        hasRunOnce = false
        progress = 0
        currentStep = "Przygotowanie…"

        let total = totalBytes
        let blockMBs = seqBlockMBs
        let includeRandom = !quickTest
        let runner = BenchmarkRunner()

        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try runner.run(
                    inDirectory: url,
                    totalBytes: total,
                    seqBlockBytes: blockMBs << 20,
                    includeRandom: includeRandom
                ) { step, fraction in
                    Task { @MainActor in
                        self?.currentStep = step
                        self?.progress = fraction
                    }
                }
                await MainActor.run {
                    self?.finish(result)
                }
            } catch {
                await MainActor.run {
                    self?.fail(error)
                }
            }
        }
    }

    func cancel() {
        runner.cancel()
        task?.cancel()
    }

    @MainActor
    private func finish(_ result: BenchmarkResult) {
        self.result = result
        let values = [
            result.seqWrite, result.seqRead, result.rndWrite, result.rndRead
        ].filter { $0 > 0 }
        if let max = values.max() {
            Self.displayMax.value = max
        }
        isRunning = false
        hasRunOnce = true
        currentStep = nil
    }

    @MainActor
    private func fail(_ error: Error) {
        self.error = error.localizedDescription
        isRunning = false
        currentStep = nil
        if case BenchmarkError.cancelled = error {
            // pozostaw wynik częściowy
        } else {
            self.result = BenchmarkResult()
        }
    }
}

/// Przywołalny pojemnik na wartość maksymalną do pasków.
final class CurrentValueBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}