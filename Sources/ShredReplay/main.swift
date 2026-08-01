import Foundation
import ShredCore
import TelemetryStore

// shred-replay — corpus replay + scoring CLI (docs/spec/08 §3).
// Usage: shred-replay run <corpus-dir> [--tuning file.json] [--report out.json] [--gates]
var args = Array(CommandLine.arguments.dropFirst())
if args.first == "dump-tuning" {
    // Writes the current default DetectionTuning as JSON (bundled as the app's tuning
    // resource so shipped defaults always match code defaults).
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try! enc.encode(DetectionTuning())
    if args.count >= 2 {
        try! data.write(to: URL(fileURLWithPath: args[1]))
    } else {
        print(String(data: data, encoding: .utf8)!)
    }
    exit(0)
}
guard args.first == "run", args.count >= 2 else {
    FileHandle.standardError.write(Data("""
    usage: shred-replay run <corpus-dir> [--tuning file.json] [--report out.json] [--gates]
    """.utf8))
    exit(2)
}
args.removeFirst()
let corpus = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
var tuning = DetectionTuning()
var reportPath: String?
var enforceGates = false
while !args.isEmpty {
    switch args.removeFirst() {
    case "--tuning":
        let path = args.removeFirst()
        tuning = try DetectionTuning.load(from: Data(contentsOf: URL(fileURLWithPath: path)))
    case "--report":
        reportPath = args.removeFirst()
    case "--gates":
        enforceGates = true
    case let other:
        FileHandle.standardError.write(Data("unknown option \(other)\n".utf8))
        exit(2)
    }
}

do {
    let fixtures = try FixtureIO.list(corpus: corpus)
    guard !fixtures.isEmpty else {
        FileHandle.standardError.write(Data("no .shredfix bundles in \(corpus.path)\n".utf8))
        exit(1)
    }
    var scores = [Replay.FixtureScore]()
    for url in fixtures {
        let fixture = try FixtureIO.read(from: url)
        let result = Replay.run(fixture: fixture, tuning: tuning)
        let score = Replay.score(fixture: fixture, result: result)
        scores.append(score)
        let evts = result.events.map { "\($0.kind.rawValue)@\(Int($0.tStart))s" }
            .joined(separator: " ")
        print("• \(fixture.meta.name): \(result.events.count) events  [\(evts)]")
    }
    let report = Replay.aggregate(scores)
    print("")
    print(Replay.renderTable(report))
    if let path = reportPath {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(report).write(to: URL(fileURLWithPath: path))
        print("report → \(path)")
    }
    if enforceGates {
        let failures = Replay.checkSyntheticGates(report)
        if !failures.isEmpty {
            print("\nGATES FAILED:")
            for f in failures { print("  ✗ \(f)") }
            exit(1)
        }
        print("\nAll synthetic gates passed ✓")
    }
} catch {
    FileHandle.standardError.write(Data("shred-replay failed: \(error)\n".utf8))
    exit(1)
}
