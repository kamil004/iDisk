import SwiftUI
import Core

/// Próbka prędkości zapisu z chwilą pobrania (czas bieżący epoch).
struct SpeedSample {
    let t: Double
    let v: Double
}

struct FormatView: View {
    @EnvironmentObject private var model: FormatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Dyski wymienne")
                    .font(.headline)
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
                .disabled(model.isRunning)

                Button {
                    model.unmountDisk()
                } label: {
                    Label("Odmontuj", systemImage: "eject.fill")
                }
                .disabled(model.isRunning || model.selectedDisk == nil || !model.isDiskMounted)

                Button {
                    model.mountDisk()
                } label: {
                    Label("Zamontuj", systemImage: "externaldrive.connected.to.line.below")
                }
                .disabled(model.isRunning || model.selectedDisk == nil || model.isDiskMounted)
            }

            if model.disks.isEmpty && !model.isLoading {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.minus")
                        .font(.system(size: 30))
                        .foregroundStyle(.orange)
                    Text("Nie wykryto dysków zewnętrznych.\nPodłącz dysk USB / USB-C (pendrive, kartę pamięci lub dysk SSD/NVMe) i kliknij „Odśwież”.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                diskSelector
                formatSettings
                Divider()
                logSection
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.load() }
        .alert("Formatowanie nośnika", isPresented: $model.showConfirm) {
            Button("Anuluj", role: .cancel) {}
            Button(model.lowLevelFormat ? "Low lvl format — usuń wszystkie dane" : "Formatuj — usuń wszystkie dane", role: .destructive) {
                model.startFormat()
            }
        } message: {
            Text(model.lowLevelFormat
                ? "Cały nośnik \(model.selectedDisk?.mediaName ?? "") zostanie nadpisany zerami — usunie to partycje i wszystkie dane bezpowrotnie. Po zakończeniu dysk zostanie utworzony od nowa (\(model.selectedFS.displayName), nazwa: \(model.formatName)). Czy na pewno chcesz kontynuować?"
                : "Wszystkie dane na nośniku \(model.selectedDisk?.mediaName ?? "") (\(model.formatSummary)) zostaną bezpowrotnie usunięte. Czy na pewno chcesz kontynuować?")
        }
    }

    private var diskSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Urządzenie:", selection: $model.selectedDiskBSD) {
                    ForEach(model.disks) { d in
                        Text(diskLabel(d)).tag(d.bsdName)
                    }
                }
                .frame(maxWidth: 420)

                Spacer()
            }

            if let disk = model.selectedDisk {
                HStack(spacing: 12) {
                    infoChip("Interfejs", disk.protocolName)
                    infoChip("System plików", disk.volumes.first?.fileSystem ?? "—")
                    infoChip("Pojemność", disk.sizeString)
                    infoChip("Wolumenów", "\(disk.volumes.count)")
                }
            }
        }
        .onChange(of: model.selectedDiskBSD) {
            model.diskSelectionChanged()
        }
    }

    private var formatSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ustawienia formatowania")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Button {
                        model.clearSpotlightIndex()
                    } label: {
                        Label("Wyczyść indeks i zablokuj", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(model.isRunning || model.mountedVolumePath == nil)
                    Text(model.mountedVolumePath ?? "brak zamontowanego wolumenu")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Usuwa katalog .Spotlight-V100 (istniejące dane indeksu) i tworzy plik .metadata_never_index, aby macOS nie indeksował tego nośnika.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let disk = model.selectedDisk {
                Toggle(isOn: $model.wholeDiskTarget) {
                    Text("Usuń partycje (formatowanie całego dysku)")
                        .font(.callout)
                }
                .disabled(model.isRunning)
                .onChange(of: model.wholeDiskTarget) {
                    if model.wholeDiskTarget {
                        model.selectedVolumeBSD = ""
                    } else if let first = model.selectedDisk?.volumes.first {
                        model.selectedVolumeBSD = first.bsdName
                    }
                }

                Toggle(isOn: $model.lowLevelFormat) {
                    Text("Low lvl Format — nadpisz cały dysk zerami (kasuje partycje i wszystkie dane)")
                        .font(.callout)
                }
                .disabled(model.isRunning)
                .onChange(of: model.lowLevelFormat) {
                    if model.lowLevelFormat {
                        model.wholeDiskTarget = true
                    }
                }

                HStack(spacing: 10) {
                    Text("Zakres:")
                    Picker("", selection: $model.selectedVolumeBSD) {
                        if model.wholeDiskTarget {
                            Text("Cały dysk (bez partycji)").tag("")
                        } else if disk.volumes.isEmpty {
                            Text("Brak wolumenów").tag("")
                        } else {
                            ForEach(disk.volumes) { v in
                                Text(v.name.isEmpty ? v.bsdName : "\(v.name) (\(v.bsdName))").tag(v.bsdName)
                            }
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 260)
                }
                .font(.callout)
                .disabled(model.isRunning || model.wholeDiskTarget)
            }

            HStack(spacing: 10) {
                Text("System plików:")
                Picker("", selection: $model.selectedFS) {
                    ForEach(FormatFileSystem.allCases) { fs in
                        Text(fs.displayName).tag(fs)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .frame(maxWidth: 420, alignment: .leading)
                Spacer()
            }
            .font(.callout)
            .disabled(model.isRunning)

            HStack(spacing: 10) {
                Text("Nazwa wolumenu:")
                TextField("np. KARTA", text: $model.volumeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .disabled(model.isRunning)

                Spacer()

                    Button {
                        model.requestConfirm()
                    } label: {
                        Label(model.isRunning ? "Formatowanie…" : (model.lowLevelFormat ? "Low lvl format" : "Formatuj"), systemImage: "externaldrive.badge.xmark")
                            .frame(minWidth: 160)
                    }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(model.isRunning
                    || model.selectedDisk == nil
                    || (!model.wholeDiskTarget && (model.selectedDisk?.volumes.isEmpty ?? true)))

                if model.isRunning {
                    Button {
                        model.cancel()
                    } label: {
                        Label("Anuluj", systemImage: "stop.fill")
                    }
                }
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
                if model.isRunning {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 200)
                }
            }

            if model.isRunning, !model.speedHistory.isEmpty {
                speedGraph(model.speedHistory)
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

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Wykres prędkości z podziałką: prędkość (MiB/s) w pionie, czas w poziomie.
    /// Okno czasowe 60 s; siatka pozioma — ładne wartości MiB/s, pionowa — co 15 s.
    private func speedGraph(_ samples: [SpeedSample]) -> some View {
        let window: Double = 60
        let now = samples.last?.t ?? 0
        return GeometryReader { geo in
            Canvas { context, size in
                let L: CGFloat = 40
                let R: CGFloat = 8
                let T: CGFloat = 10
                let B: CGFloat = 16
                let plot = CGRect(x: L, y: T,
                                  width: max(1, size.width - L - R),
                                  height: max(1, size.height - T - B))
                let inWindow = samples.filter { $0.t >= now - window }
                guard let maxV = inWindow.map(\.v).max(), maxV > 0, size.width > 0 else { return }

                // Skala pionowa liczy się z WIDOCZNYCH w oknie 60 s próbek —
                // gdy szybkie początkowe próbki wypadną z okna, oś się przeskaluje.
                let yMax = Self.niceCeiling(maxV)
                let stepV = Self.gridStep(yMax)

                // Linie poziome (prędkość) + etykiety MiB/s.
                var v = 0.0
                while v <= yMax {
                    let y = plot.maxY - plot.height * CGFloat(v / yMax)
                    let path = Path { p in
                        p.move(to: CGPoint(x: plot.minX, y: y))
                        p.addLine(to: CGPoint(x: plot.maxX, y: y))
                    }
                    context.stroke(path, with: .color(.primary.opacity(0.12)), lineWidth: 0.5)
                    let resolved = context.resolve(Text(String(format: "%.0f", v)).font(.system(size: 8)).foregroundStyle(.secondary))
                    context.draw(resolved, at: CGPoint(x: plot.minX - 4, y: y), anchor: .trailing)
                    v += stepV
                }

                // Linie pionowe (czas) co 15 s, od „-60 s" do „0".
                let timeStep = window / 4
                var t = now
                while t >= now - window {
                    let fracX = CGFloat((t - (now - window)) / window)
                    let x = plot.minX + plot.width * fracX
                    let path = Path { p in
                        p.move(to: CGPoint(x: x, y: plot.minY))
                        p.addLine(to: CGPoint(x: x, y: plot.maxY))
                    }
                    context.stroke(path, with: .color(.primary.opacity(0.12)), lineWidth: 0.5)
                    let secs = Int(round(now - t))
                    let resolved = context.resolve(Text(secs == 0 ? "0" : "-\(secs)s").font(.system(size: 8)).foregroundStyle(.secondary))
                    context.draw(resolved, at: CGPoint(x: x, y: plot.maxY + 3), anchor: .top)
                    t -= timeStep
                }

                // Pionowa oś „MiB/s".
                let axis = context.resolve(Text("MiB/s").font(.system(size: 8)).foregroundStyle(.tertiary))
                context.draw(axis, at: CGPoint(x: plot.minX - 4, y: plot.minY), anchor: .topTrailing)

                // Linia prędkości w oknie czasowym (grubość 50% szerokości
                // „słupka”, jakiego używałby wykres kolumnowy).
                let avgInterval = inWindow.count > 1 ? window / Double(inWindow.count) : 0.5
                let barW = max(1.5, min(16, plot.width * CGFloat(avgInterval / window) * 0.85))
                let lineW = max(1, barW * 0.5)

                let pts: [CGPoint] = inWindow.map { s in
                    let fracX = (s.t - (now - window)) / window
                    let x = plot.minX + plot.width * CGFloat(fracX)
                    let y = plot.maxY - plot.height * CGFloat(s.v / yMax)
                    return CGPoint(x: x, y: y)
                }
                guard let firstP = pts.first, let lastP = pts.last else { return }

                var line = Path()
                line.move(to: firstP)
                for p in pts.dropFirst() { line.addLine(to: p) }

                let gradient = Gradient(colors: [.teal, .green])
                let area = Path { p in
                    p.addPath(line)
                    p.addLine(to: CGPoint(x: lastP.x, y: plot.maxY))
                    p.addLine(to: CGPoint(x: firstP.x, y: plot.maxY))
                    p.closeSubpath()
                }
                context.opacity = 0.18
                context.fill(area, with: .linearGradient(gradient, startPoint: CGPoint(x: plot.minX, y: plot.minY), endPoint: CGPoint(x: plot.minX, y: plot.maxY)))
                context.opacity = 1
                context.stroke(line, with: .linearGradient(gradient, startPoint: CGPoint(x: plot.minX, y: 0), endPoint: CGPoint(x: plot.maxX, y: 0)), style: StrokeStyle(lineWidth: lineW, lineCap: .round, lineJoin: .round))
                context.fill(Path(ellipseIn: CGRect(x: lastP.x - 2.5, y: lastP.y - 2.5, width: 5, height: 5)), with: .color(.green))
            }
        }
        .frame(height: 92)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    /// Najwyższa „okrągła" wartość osi (1/2/5 · 10ⁿ) nie mniejsza niż max.
    nonisolated static func niceCeiling(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let exp = floor(log10(v))
        let m = v / pow(10, exp)
        let nice: Double
        if m <= 1 { nice = 1 }
        else if m <= 2 { nice = 2 }
        else if m <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * pow(10, exp)
    }

    /// Krok siatki pionowej (4 linie + 0).
    nonisolated static func gridStep(_ v: Double) -> Double {
        let raw = v / 4
        let exp = floor(log10(raw))
        let m = raw / pow(10, exp)
        let nice: Double
        if m <= 1 { nice = 1 }
        else if m <= 2 { nice = 2 }
        else if m <= 5 { nice = 5 }
        else { nice = 10 }
        return nice * pow(10, exp)
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

    private func diskLabel(_ d: DiskInfo) -> String {
        let removable = d.isRemovable ? "" : ""
        return "\(d.mediaName) · \(d.protocolName) · \(d.sizeString)\(removable)"
    }
}

@MainActor
final class FormatModel: ObservableObject {
    @Published var disks: [DiskInfo] = []
    @Published var selectedDiskBSD = ""
    @Published var selectedVolumeBSD = ""
    @Published var wholeDiskTarget = true
    @Published var selectedFS = FormatFileSystem.allCases[0]
    @Published var volumeName = "DYSK"
    @Published var lowLevelFormat = false
    @Published var isLoading = false
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var operationStatus = ""
    @Published var speedHistory: [SpeedSample] = []
    @Published var log: [String] = []
    @Published var errorMessage: String?
    @Published var showConfirm = false

    private var formatter = DiskFormatter()

    var selectedDisk: DiskInfo? {
        disks.first { $0.bsdName == selectedDiskBSD }
    }

    var selectedVolume: VolumeInfo? {
        selectedVolumes.first { $0.bsdName == selectedVolumeBSD }
    }

    /// Czy na wybranym dysku jest zamontowany jakikolwiek wolumen.
    var isDiskMounted: Bool {
        selectedDisk?.volumes.contains { $0.mountPoint != nil } ?? false
    }

    func unmountDisk() {
        guard let disk = selectedDisk else { return }
        errorMessage = nil
        let bsd = disk.bsdName
        let ref = self
        log.append("Odmontowywanie \(bsd)…")
        Task.detached(priority: .userInitiated) {
            let code = FormatModel.runTool("/usr/sbin/diskutil", ["unmountDisk", bsd])
            await MainActor.run {
                if code == 0 {
                    ref.log.append("✔ Odmontowano \(bsd).")
                } else {
                    ref.errorMessage = "Odmontowanie \(bsd) nie powiodło się."
                }
                ref.refresh()
            }
        }
    }

    func mountDisk() {
        guard let disk = selectedDisk else { return }
        errorMessage = nil
        let bsd = disk.bsdName
        let ref = self
        log.append("Montowanie \(bsd)…")
        Task.detached(priority: .userInitiated) {
            let code = FormatModel.runTool("/usr/sbin/diskutil", ["mountDisk", bsd])
            await MainActor.run {
                if code == 0 {
                    ref.log.append("✔ Zamontowano \(bsd).")
                } else {
                    ref.errorMessage = "Montowanie \(bsd) nie powiodło się."
                }
                ref.refresh()
            }
        }
    }

    /// Ścieżka zamontowanego wolumenu wybranego dysku (wybrany wolumen, a jeśli
    /// pusty — pierwszy zamontowany), dla którego można wyczyścić indeks Spotlight.
    var mountedVolumePath: String? {
        var vols = selectedVolumes
        if let selected = selectedVolume, selected.mountPoint != nil {
            vols = vols.filter { $0.bsdName == selected.bsdName }
        }
        return vols.compactMap { $0.mountPoint?.path }.first
    }

    func clearSpotlightIndex() {
        guard let path = mountedVolumePath else {
            errorMessage = "Brak zamontowanego wolumenu — zamontuj wolumen, aby wyczyścić indeks Spotlight."
            return
        }
        errorMessage = nil
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let marker = url.appendingPathComponent(".metadata_never_index")
        let spot = url.appendingPathComponent(".Spotlight-V100", isDirectory: true)
        let ref = self

        log.append("Czyszczenie indeksu Spotlight w \(path)…")
        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            let originalPath = path

            // 1) Zapewnij prawa zapisu jako bieżący użytkownik.
            if !FormatModel.probeWritable(fm, originalPath) {
                _ = FormatModel.runTool("/usr/sbin/diskutil", ["unmount", originalPath])
                let remount = FormatModel.runTool("/usr/sbin/diskutil", ["mount", originalPath])
                Thread.sleep(forTimeInterval: 1.0)
                if !FormatModel.probeWritable(fm, originalPath) {
                    await MainActor.run {
                        ref.errorMessage = "Nie udało się uzyskać prawa zapisu do \(originalPath). Odmontuj i zamontuj wolumen ręcznie (kod remount: \(remount)) i spróbuj ponownie."
                    }
                    return
                }
            }

            // 2) Wyłącz indeksowanie i wymaż dane indeksu mdutilem —
            //    zatrzymuje mdworker, który w przeciwnym razie ciągle zapisuje
            //    do .Spotlight-V100 i blokuje jego usunięcie.
            let off = FormatModel.runToolCaptured("/usr/bin/mdutil", ["-i", "off", originalPath])
            let erase = FormatModel.runToolCaptured("/usr/bin/mdutil", ["-E", originalPath])
            await MainActor.run {
                if off.code != 0 {
                    ref.log.append("mdutil -i off kod \(off.code): \(off.out.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                if erase.code != 0 {
                    ref.log.append("mdutil -E kod \(erase.code): \(erase.out.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }

            // 3) Znacznik blokujący indeksowanie (na wszelki wypadek).
            do {
                if fm.fileExists(atPath: marker.path) {
                    try fm.removeItem(at: marker)
                }
                fm.createFile(atPath: marker.path, contents: nil)
            } catch {
                await MainActor.run {
                    ref.log.append("⚠ Nie udało się utworzyć .metadata_never_index: \(error.localizedDescription)")
                }
            }

            // 4) Usuń dane indeksu z ponawianiami. Obecność mdworker
            //    (mimo wyłączonego indeksowania) zwykle mija w kilka sekund —
            //    stąd dłuższa pętla i rekurencyjne usuwanie zawartości.
            _ = FormatModel.runTool("/usr/bin/chflags", ["-R", "nouchg,noschg", spot.path])

            var removed = false
            for _ in 1...12 {
                if !fm.fileExists(atPath: spot.path) {
                    removed = true
                    break
                }
                if FormatModel.forceRemove(fm, spot) {
                    removed = true
                    break
                }
                Thread.sleep(forTimeInterval: 1.5)
            }

            // Ostatnia szansa: przełóż zamontowanie wolumenu — świeże
            // zamontowanie odblokowuje wpisy katalogowe trzymane przez daemony.
            if !removed {
                await MainActor.run {
                    ref.log.append("…próba usunięcia po ponownym zamontowaniu wolumenu…")
                }
                _ = FormatModel.runTool("/usr/sbin/diskutil", ["unmount", originalPath])
                _ = FormatModel.runTool("/usr/sbin/diskutil", ["mount", originalPath])
                Thread.sleep(forTimeInterval: 2.0)
                if FormatModel.probeWritable(fm, originalPath) {
                    if FormatModel.forceRemove(fm, spot) {
                        removed = true
                    }
                }
            }

            await MainActor.run {
                if removed {
                    ref.log.append("✔ Usunięto dane indeksu (.Spotlight-V100) w \(originalPath) i utworzono .metadata_never_index.")
                } else {
                    ref.log.append("⚠ Nie udało się usunąć .Spotlight-V100 w \(originalPath) mimo ponowień. Znacznik .metadata_never_index zapobiega dalszemu indeksowaniu. Jeśli błąd się powtarza, odmontuj i zamontuj wolumen ręcznie, po czym spróbuj ponownie.")
                }
            }
        }
    }

    /// Rekurencyjnie usuwa element (z zawartością) z ponawianiami,
    /// po kolei usuwając podkatalogi/pliki — radzi sobie też z wpisami
    /// doraźnie zajętymi przez mdworker/indexing.
    nonisolated static func forceRemove(_ fm: FileManager, _ url: URL, retries: Int = 3) -> Bool {
        if !fm.fileExists(atPath: url.path) { return true }
        for _ in 0..<retries {
            if (try? fm.removeItem(at: url)) != nil { return true }
        }
        if let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) {
            for child in children {
                _ = forceRemove(fm, child, retries: retries)
            }
        }
        for _ in 0..<retries {
            if (try? fm.removeItem(at: url)) != nil { return true }
        }
        return !fm.fileExists(atPath: url.path)
    }

    /// Sprawdza zapisywalność wolumenu (próba zapisu i usunięcia pliku tymczasowego).
    nonisolated static func probeWritable(_ fm: FileManager, _ path: String) -> Bool {
        let probe = URL(fileURLWithPath: path, isDirectory: true).appendingPathComponent(".idisk_write_probe")
        do {
            try Data([0]).write(to: probe, options: .atomic)
            try fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    /// Uruchamia narzędzie jako bieżący użytkownik (bez uprawnień administratora).
    nonisolated static func runTool(_ executable: String, _ args: [String]) -> Int32 {
        runToolCaptured(executable, args).code
    }

    /// Uruchamia narzędzie jako bieżący użytkownik i zwraca kod + wyjście (stderr+stdout).
    nonisolated static func runToolCaptured(_ executable: String, _ args: [String]) -> (code: Int32, out: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    var formatSummary: String {
        if lowLevelFormat {
            return "niskopoziomowy (nadpisanie zerami, kasuje partycje), cały dysk"
        }
        return "\(selectedFS.displayName)\(wholeDiskTarget ? ", cały dysk" : ", wolumen")"
    }

    var formatName: String {
        volumeName.isEmpty ? "DYSK" : volumeName
    }

    /// Formatuje wskaźnik prędkości/ETA, np. „12,4 MiB/s · ETA ~ 1 h 12 min”.
    /// Ujemne wartości (np. poza fazą nadpisywania) zwracają pusty ciąg.
    nonisolated static func speedETA(_ mbps: Double, _ eta: Double) -> String {
        if mbps < 0 { return "" }
        let speed = String(format: "%.1f MiB/s", mbps)
        if !eta.isFinite || eta <= 0 { return speed }
        let secs = Int(eta.rounded())
        if secs < 90 { return "\(speed) · ETA ~ \(secs) s" }
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(speed) · ETA ~ \(h) h \(m) min" }
        return "\(speed) · ETA ~ \(m) min"
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

    func requestConfirm() {
        showConfirm = true
    }

    func startFormat() {
        guard let disk = selectedDisk, !isRunning else { return }
        errorMessage = nil
        log = []
        isRunning = true
        progress = 0
        operationStatus = ""
        speedHistory = []

        let bsd: String
        let whole = wholeDiskTarget
        if whole {
            bsd = disk.bsdName
        } else {
            guard let vol = selectedVolumes.first(where: { $0.bsdName == selectedVolumeBSD }) else {
                errorMessage = "Wybierz wolumen do sformatowania."
                isRunning = false
                return
            }
            bsd = vol.bsdName
        }

        let fs = selectedFS
        let name = volumeName.isEmpty ? "DYSK" : volumeName
        let low = lowLevelFormat
        // Używamy egzemplarza z @Published, żeby cancel() trafiał w ten sam obiekt.
        let runningFormatter = DiskFormatter()
        self.formatter = runningFormatter
        let formatter = runningFormatter
        if low { operationStatus = "Obliczanie prędkości…" }

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if low {
                    try formatter.lowLevelFormat(
                        bsd: disk.bsdName,
                        fileSystem: fs,
                        name: name,
                        capacityBytes: UInt64(max(0, disk.sizeBytes)),
                        progress: { step, fraction in
                            Task { @MainActor in
                                self?.progress = fraction
                            }
                        },
                        outputLine: { line in
                            Task { @MainActor in
                                self?.log.append(line)
                            }
                        },
                        stats: { mbps, eta in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                self.operationStatus = Self.speedETA(mbps, eta)
                                if mbps > 0 {
                                    let sample = SpeedSample(t: Date().timeIntervalSinceReferenceDate, v: mbps)
                                    self.speedHistory.append(sample)
                                    if self.speedHistory.count > 600 {
                                        self.speedHistory.removeFirst(self.speedHistory.count - 600)
                                    }
                                }
                            }
                        }
                    )
                } else {
                    try formatter.format(
                        bsd: bsd,
                        wholeDisk: whole,
                        fileSystem: fs,
                        name: name,
                        progress: { step, fraction in
                            Task { @MainActor in
                                self?.progress = fraction
                            }
                        },
                        outputLine: { line in
                            Task { @MainActor in
                                self?.log.append(line)
                            }
                        }
                    )
                }
                await MainActor.run {
                    self?.log.append(low
                        ? "✔ Niskopoziomowe formatowanie zakończone pomyślnie."
                        : "✔ Formatowanie zakończone pomyślnie.")
                    self?.isRunning = false
                }
            } catch {
                await MainActor.run {
                    if case FormatError.cancelled = error {
                        self?.log.append("✖ Formatowanie anulowane.")
                    } else {
                        self?.errorMessage = error.localizedDescription
                    }
                    self?.isRunning = false
                }
            }
        }
    }

    func cancel() {
        formatter.cancel()
    }

    func diskSelectionChanged() {
        if let disk = selectedDisk {
            selectedVolumeBSD = disk.volumes.first?.bsdName ?? ""
            if disk.volumes.isEmpty { wholeDiskTarget = true }
        }
    }

    private var selectedVolumes: [VolumeInfo] {
        selectedDisk?.volumes ?? []
    }
}