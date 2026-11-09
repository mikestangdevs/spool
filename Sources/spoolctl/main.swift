import Foundation
import SpoolCore

// spoolctl focus east  →  open -g "spool://focus?arg=east"
// The app does the work; this only checks the words and hands them over.

let words = Array(CommandLine.arguments.dropFirst())

guard let url = Command.url(for: words) else {
    let help = words.isEmpty || words == ["help"] || words == ["--help"] || words == ["-h"]
    let text = "usage: spoolctl <command>\n\n\(Command.usage)\n"
    if help {
        print(text, terminator: "")
        exit(0)
    }
    FileHandle.standardError.write("spoolctl: unknown command '\(words.joined(separator: " "))'\n\n\(text)".data(using: .utf8)!)
    exit(64)
}

let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = ["-g", url.absoluteString]   // -g: do not bring Spool to the front
do {
    try open.run()
    open.waitUntilExit()
    exit(open.terminationStatus)
} catch {
    FileHandle.standardError.write("spoolctl: could not reach Spool: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
