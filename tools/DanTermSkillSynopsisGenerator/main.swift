// Checks or updates the generated command synopsis region in DanTerm's agent skill.
import DanTermProtocol
import Foundation

/// Reports one command-line failure and terminates without emitting stdout.
private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("DanTermSkillSynopsisGenerator: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3,
      ["--check", "--update"].contains(CommandLine.arguments[1])
else {
    fail("usage: DanTermSkillSynopsisGenerator <--check|--update> <skill-path>")
}

let mode = CommandLine.arguments[1]
let path = CommandLine.arguments[2]
let url = URL(fileURLWithPath: path)

do {
    let document = try String(contentsOf: url, encoding: .utf8)
    if mode == "--check" {
        try CLISkillSynopsisRegion.check(document)
        print("DanTermSkillSynopsisGenerator: generated command synopsis is current")
    } else {
        let updated = try CLISkillSynopsisRegion.update(document)
        if updated != document {
            try Data(updated.utf8).write(to: url, options: .atomic)
        }
        print("DanTermSkillSynopsisGenerator: updated generated command synopsis")
    }
} catch {
    fail("\(path): \(error). Run `just update-danterm-skill` after catalog changes; restore one ordered marker pair if the region is malformed")
}
