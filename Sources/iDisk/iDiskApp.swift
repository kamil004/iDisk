import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct iDiskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("iDisk") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.smart)
                .environmentObject(appState.bench)
                .environmentObject(appState.format)
                .environmentObject(appState.capacity)
                .environmentObject(appState.image)
                .frame(minWidth: 860, minHeight: 720)
        }
        .defaultSize(width: 900, height: 981)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("O aplikacji iDisk") {
                    appState.showAbout = true
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

/// Wspólny stan aplikacji — modele żyją ponad zakładkami,
/// dzięki czemu test prędkości trwa po przełączeniu okna/zakładki.
@MainActor
final class AppState: ObservableObject {
    @Published var showAbout = false
    let smart = SmartModel()
    let bench = BenchmarkModel()
    let format = FormatModel()
    let capacity = CapTestModel()
    let image = ImageModel()
}

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: Side = .smart

    enum Side: String, CaseIterable, Identifiable {
        case smart = "Dyski i SMART"
        case bench = "Test prędkości"
        case format = "Formatowanie"
        case capacity = "Pojemność"
        case image = "Obraz dysku"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Picker("", selection: $selection) {
                    ForEach(Side.allCases) { side in
                        switch side {
                        case .smart:
                            Label(side.rawValue, systemImage: "externaldrive.fill.badge.checkmark").tag(side)
                        case .bench:
                            Label(side.rawValue, systemImage: "speedometer").tag(side)
                        case .format:
                            Label(side.rawValue, systemImage: "externaldrive.badge.xmark").tag(side)
                        case .capacity:
                            Label(side.rawValue, systemImage: "cylinder.split.1x2").tag(side)
                        case .image:
                            Label(side.rawValue, systemImage: "externaldrive.badge.plus").tag(side)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)

                HStack {
                    Spacer()
                    Button {
                        saveScreenshot()
                    } label: {
                        Label("Zrzut okna", systemImage: "floppy")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            ZStack {
                switch selection {
                case .smart: SmartView()
                case .bench: BenchmarkView()
                case .format: FormatView()
                case .capacity: CapTestView()
                case .image: ImageView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .sheet(isPresented: $appState.showAbout) {
            AboutView()
        }
        .alert("Zapis zrzutu okna", isPresented: Binding(
            get: { screenshotError != nil },
            set: { if !$0 { screenshotError = nil } }
        )) {
            Button("OK") { screenshotError = nil }
        } message: {
            Text(screenshotError ?? "")
        }
    }

    @State private var screenshotError: String?

    private func saveScreenshot() {
        guard let data = captureWindowPNG() else {
            screenshotError = "Nie udało się utworzyć zrzutu okna."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "iDisk-wyniki-\(df.string(from: Date())).png"
        panel.message = "Zapisz zrzut okna"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                screenshotError = "Błąd zapisu zrzutu: \(error.localizedDescription)"
            }
        }
    }

    private func captureWindowPNG() -> Data? {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            let windowID = CGWindowID(window.windowNumber)
            if let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                windowID,
                [.boundsIgnoreFraming, .bestResolution]
            ) {
                let rep = NSBitmapImageRep(cgImage: image)
                if let data = rep.representation(using: .png, properties: [:]) {
                    return data
                }
            }
            if let view = window.contentView {
                let rect = view.bounds
                if let rep = view.bitmapImageRepForCachingDisplay(in: rect) {
                    view.cacheDisplay(in: rect, to: rep)
                    return rep.representation(using: .png, properties: [:])
                }
            }
        }
        return nil
    }
}

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "—"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)

            Text("iDisk")
                .font(.title.bold())

            Text("Wersja \(version)")
                .foregroundStyle(.secondary)
                .font(.callout)

            Divider()
                .frame(width: 220)

            Text("Created by Kamil Gorecki")
                .font(.system(size: 14, weight: .medium))

            Text("SMART, test prędkości i formatowanie dysków")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Zamknij") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.top, 6)
        }
        .padding(28)
        .frame(width: 320)
    }
}