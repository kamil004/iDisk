import Foundation
import Core

// Narzędzie do szybkiej weryfikacji silnika benchmarku z linii poleceń.
// Użycie: BenchTest [katalog] [rozmiar MiB] [blok MiB] [rnd: 1/0]

let args = CommandLine.arguments
let dirArg = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
let sizeMiB = args.count > 2 ? Int64(args[2]) ?? 512 : 512
let blockMiB = args.count > 3 ? Int(args[3]) ?? 1 : 1
let includeRandom = args.count > 4 ? (args[4] != "0") : true

let dir = URL(fileURLWithPath: dirArg, isDirectory: true)
let total = sizeMiB << 20

let runner = BenchmarkRunner()
var steps = ["Zapis sekwencyjny…", "Odczyt sekwencyjny…"]
if includeRandom { steps += ["Zapis losowy 4K…", "Odczyt losowy 4K…"] }
for step in steps {
    print(step)
}

do {
    let r = try runner.run(inDirectory: dir, totalBytes: total, seqBlockBytes: blockMiB << 20, includeRandom: includeRandom) { step, frac in
        print("  \(step) \(Int(frac * 100))%")
    }
    print("SEKWENCJYJNY ZAPIS: \(r.seqWrite.mbsString)")
    print("SEKWENCJYJNY ODCZYT: \(r.seqRead.mbsString)")
    if includeRandom {
        print("LOSOWY ZAPIS 4K:     \(r.rndWrite.mbsString)")
        print("LOSOWY ODCZYT 4K:    \(r.rndRead.mbsString)")
    }
} catch {
    print("BŁĄD: \(error.localizedDescription)")
    exit(1)
}

extension Double {
    var mbsString: String {
        String(format: "%.1f MiB/s", self)
    }
}