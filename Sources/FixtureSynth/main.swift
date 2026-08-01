import Foundation
import SynthKit

// fixture-synth — writes the synthetic corpus (docs/spec/08 §2).
// Usage: fixture-synth <output-dir>
let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: fixture-synth <output-dir>\n".utf8))
    exit(2)
}
let root = URL(fileURLWithPath: args[1], isDirectory: true)
do {
    let names = try ScenarioCatalog.writeAll(to: root)
    print("wrote \(names.count) fixtures to \(root.path):")
    for n in names { print("  \(n).shredfix") }
} catch {
    FileHandle.standardError.write(Data("fixture-synth failed: \(error)\n".utf8))
    exit(1)
}
